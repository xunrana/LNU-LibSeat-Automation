/// 移动端运行日志落盘与全量脱敏 ZIP 导出工具（零第三方压缩依赖）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class LogInventory {
  final int sessionCount;
  final int fileCount;
  final int totalBytes;
  final List<Directory> sessionDirs;

  const LogInventory({
    this.sessionCount = 0,
    this.fileCount = 0,
    this.totalBytes = 0,
    this.sessionDirs = const <Directory>[],
  });

  String get formattedSize {
    if (totalBytes < 1024) {
      return '$totalBytes B';
    }
    if (totalBytes < 1024 * 1024) {
      return '${(totalBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(totalBytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }
}

class MobileLogExporter {
  MobileLogExporter._();

  static const int _maxRunLogBytes = 2 * 1024 * 1024;
  static const int _keepRunLogBytes = 1024 * 1024;

  /// 追加一行终端运行日志到 `<logBaseDir>/run_log.txt`（超 2MB 自动滚动截断）。
  static void appendPersistentRunLog(
    Directory? logBaseDir,
    String account,
    String message, {
    DateTime? beijingTime,
  }) {
    if (logBaseDir == null) {
      return;
    }
    try {
      final file = File('${logBaseDir.path}/run_log.txt');
      if (file.existsSync()) {
        final len = file.lengthSync();
        if (len > _maxRunLogBytes) {
          final bytes = file.readAsBytesSync();
          final tail = bytes.sublist(bytes.length - _keepRunLogBytes);
          // 对齐到下一个换行符，避免半行乱码
          final nl = tail.indexOf(10);
          file.writeAsBytesSync(
            nl >= 0 ? tail.sublist(nl + 1) : tail,
            flush: true,
          );
        }
      }
      final ts = _formatBeijingTime(beijingTime ?? _currentBeijingTime());
      final tag = '[$account]';
      final line = message.contains(tag) ? '[$ts] $message\n' : '[$ts] $tag $message\n';
      file.writeAsStringSync(line, mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  /// 扫描日志目录，返回会话数量、文件数与磁盘占用统计（按最新会话倒序）。
  static LogInventory scanInventory(Directory? logBaseDir) {
    if (logBaseDir == null || !logBaseDir.existsSync()) {
      return const LogInventory();
    }
    final sessionsRoot = Directory('${logBaseDir.path}/sessions');
    final sessionDirs = <Directory>[];
    var fileCount = 0;
    var totalBytes = 0;

    final runLog = File('${logBaseDir.path}/run_log.txt');
    if (runLog.existsSync()) {
      fileCount += 1;
      totalBytes += runLog.lengthSync();
    }

    if (sessionsRoot.existsSync()) {
      for (final entity in sessionsRoot.listSync()) {
        if (entity is Directory) {
          sessionDirs.add(entity);
          for (final sub in entity.listSync(recursive: true)) {
            if (sub is File) {
              fileCount += 1;
              totalBytes += sub.lengthSync();
            }
          }
        }
      }
      sessionDirs.sort((a, b) => _baseName(b.path).compareTo(_baseName(a.path)));
    }

    return LogInventory(
      sessionCount: sessionDirs.length,
      fileCount: fileCount,
      totalBytes: totalBytes,
      sessionDirs: sessionDirs,
    );
  }

  /// 收集最近一轮抢座的全部日志（若主副双账号在 90 秒内并发启动，一并打包导出）。
  static List<File> collectLatestRushFiles(Directory? logBaseDir) {
    final inv = scanInventory(logBaseDir);
    if (logBaseDir == null) {
      return const <File>[];
    }

    final files = <File>[];
    final runLog = File('${logBaseDir.path}/run_log.txt');
    if (runLog.existsSync() && runLog.lengthSync() > 0) {
      files.add(runLog);
    }

    if (inv.sessionDirs.isNotEmpty) {
      final latestTime = _parseSessionTimestamp(_baseName(inv.sessionDirs.first.path));
      final batchDirs = <Directory>[];
      for (final dir in inv.sessionDirs) {
        if (batchDirs.isEmpty) {
          batchDirs.add(dir);
          continue;
        }
        final ts = _parseSessionTimestamp(_baseName(dir.path));
        if (latestTime != null &&
            ts != null &&
            latestTime.difference(ts).abs().inSeconds <= 90) {
          batchDirs.add(dir);
        } else {
          break;
        }
      }

      for (final dir in batchDirs) {
        for (final name in const <String>['http_trace.jsonl', 'session.log', '抢座顺序.txt']) {
          final f = File('${dir.path}/$name');
          if (f.existsSync() && f.lengthSync() > 0) {
            files.add(f);
          }
        }
      }
    }
    return files;
  }

  /// 将全部历史抢座会话（`run_log.txt` + `sessions/**` 含流水、运行日志与验证码回放图）打包为标准 `.zip`。
  static File? exportAllLogsToZip(
    Directory? logBaseDir, {
    bool includeImages = true,
  }) {
    if (logBaseDir == null || !logBaseDir.existsSync()) {
      return null;
    }

    final entries = <String, Uint8List>{};
    final runLog = File('${logBaseDir.path}/run_log.txt');
    if (runLog.existsSync()) {
      entries['run_log.txt'] = runLog.readAsBytesSync();
    }

    final sessionsRoot = Directory('${logBaseDir.path}/sessions');
    if (sessionsRoot.existsSync()) {
      final dirs = sessionsRoot.listSync().whereType<Directory>().toList()
        ..sort((a, b) => _baseName(a.path).compareTo(_baseName(b.path)));
      for (final dir in dirs) {
        final dirName = _baseName(dir.path);
        final subFiles = dir.listSync().whereType<File>().toList()
          ..sort((a, b) => _baseName(a.path).compareTo(_baseName(b.path)));
        for (final f in subFiles) {
          final fname = _baseName(f.path);
          if (!includeImages &&
              (fname.toLowerCase().endsWith('.png') ||
                  fname.toLowerCase().endsWith('.jpg'))) {
            continue;
          }
          entries['sessions/$dirName/$fname'] = f.readAsBytesSync();
        }
      }
    }

    if (entries.isEmpty) {
      return null;
    }

    final exportsDir = Directory('${logBaseDir.path}/exports');
    exportsDir.createSync(recursive: true);
    // 清理旧导出包，避免反复打包占空间
    for (final old in exportsDir.listSync().whereType<File>()) {
      if (old.path.endsWith('.zip')) {
        try {
          old.deleteSync();
        } catch (_) {}
      }
    }

    final bj = _currentBeijingTime();
    String pad2(int n) => n.toString().padLeft(2, '0');
    final stamp =
        '${bj.year}${pad2(bj.month)}${pad2(bj.day)}_${pad2(bj.hour)}${pad2(bj.minute)}${pad2(bj.second)}';
    final outFile = File('${exportsDir.path}/LNU-LibSeat-logs-$stamp.zip');
    final zipBytes = buildZipBytes(entries);
    outFile.writeAsBytesSync(zipBytes, flush: true);
    return outFile;
  }

  /// 纯 Dart 标准 ZIP 打包（UTF-8 文件名标记 0x0800 + 文本 DEFLATE / 图片 STORE）。
  static Uint8List buildZipBytes(Map<String, Uint8List> files) {
    final out = BytesBuilder(copy: false);
    final centralDir = BytesBuilder(copy: false);
    var offset = 0;
    var entryCount = 0;

    final sortedKeys = files.keys.toList()..sort();
    for (final name in sortedKeys) {
      final raw = files[name]!;
      final nameBytes = utf8.encode(name);
      final crc = _crc32(raw);

      final lower = name.toLowerCase();
      final skipDeflate = lower.endsWith('.png') ||
          lower.endsWith('.jpg') ||
          lower.endsWith('.jpeg') ||
          lower.endsWith('.zip') ||
          raw.length < 64;

      var method = 0;
      Uint8List payload = raw;
      if (!skipDeflate) {
        final compressed = Uint8List.fromList(ZLibCodec(raw: true).encode(raw));
        if (compressed.length < raw.length) {
          method = 8;
          payload = compressed;
        }
      }

      // Local File Header (30 bytes + name + payload)
      final lfh = ByteData(30);
      lfh.setUint32(0, 0x04034b50, Endian.little); // signature
      lfh.setUint16(4, 20, Endian.little); // version needed (2.0)
      lfh.setUint16(6, 0x0800, Endian.little); // UTF-8 filename flag
      lfh.setUint16(8, method, Endian.little); // compression method
      lfh.setUint16(10, 0, Endian.little); // mod time
      lfh.setUint16(12, 0x5821, Endian.little); // mod date (2024-01-01)
      lfh.setUint32(14, crc, Endian.little);
      lfh.setUint32(18, payload.length, Endian.little);
      lfh.setUint32(22, raw.length, Endian.little);
      lfh.setUint16(26, nameBytes.length, Endian.little);
      lfh.setUint16(28, 0, Endian.little); // extra len

      out.add(lfh.buffer.asUint8List());
      out.add(nameBytes);
      out.add(payload);

      // Central Directory Header (46 bytes + name)
      final cdh = ByteData(46);
      cdh.setUint32(0, 0x02014b50, Endian.little); // signature
      cdh.setUint16(4, 20, Endian.little); // version made by
      cdh.setUint16(6, 20, Endian.little); // version needed
      cdh.setUint16(8, 0x0800, Endian.little); // UTF-8 filename flag
      cdh.setUint16(10, method, Endian.little);
      cdh.setUint16(12, 0, Endian.little);
      cdh.setUint16(14, 0x5821, Endian.little);
      cdh.setUint32(16, crc, Endian.little);
      cdh.setUint32(20, payload.length, Endian.little);
      cdh.setUint32(24, raw.length, Endian.little);
      cdh.setUint16(28, nameBytes.length, Endian.little);
      cdh.setUint16(30, 0, Endian.little); // extra len
      cdh.setUint16(32, 0, Endian.little); // comment len
      cdh.setUint16(34, 0, Endian.little); // disk start
      cdh.setUint16(36, 0, Endian.little); // internal attrs
      cdh.setUint32(38, 0, Endian.little); // external attrs
      cdh.setUint32(42, offset, Endian.little); // local header offset

      centralDir.add(cdh.buffer.asUint8List());
      centralDir.add(nameBytes);

      offset += 30 + nameBytes.length + payload.length;
      entryCount += 1;
    }

    final cdBytes = centralDir.takeBytes();
    out.add(cdBytes);

    // End of Central Directory Record (22 bytes)
    final eocd = ByteData(22);
    eocd.setUint32(0, 0x06054b50, Endian.little);
    eocd.setUint16(4, 0, Endian.little);
    eocd.setUint16(6, 0, Endian.little);
    eocd.setUint16(8, entryCount, Endian.little);
    eocd.setUint16(10, entryCount, Endian.little);
    eocd.setUint32(12, cdBytes.length, Endian.little);
    eocd.setUint32(16, offset, Endian.little);
    eocd.setUint16(20, 0, Endian.little);
    out.add(eocd.buffer.asUint8List());

    return out.takeBytes();
  }

  static final Uint32List _crcTable = _buildCrcTable();

  static Uint32List _buildCrcTable() {
    final table = Uint32List(256);
    for (var i = 0; i < 256; i++) {
      var c = i;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
      }
      table[i] = c;
    }
    return table;
  }

  static int _crc32(Uint8List data) {
    var crc = 0xFFFFFFFF;
    for (var i = 0; i < data.length; i++) {
      crc = _crcTable[(crc ^ data[i]) & 0xFF] ^ (crc >>> 8);
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  static DateTime _currentBeijingTime() =>
      DateTime.now().toUtc().add(const Duration(hours: 8));

  static String _formatBeijingTime(DateTime dt) {
    String pad2(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${pad2(dt.month)}-${pad2(dt.day)} '
        '${pad2(dt.hour)}:${pad2(dt.minute)}:${pad2(dt.second)}';
  }

  static String _baseName(String path) {
    final normalized = path.replaceAll('\\', '/');
    final idx = normalized.lastIndexOf('/');
    return idx >= 0 ? normalized.substring(idx + 1) : normalized;
  }

  static DateTime? _parseSessionTimestamp(String dirName) {
    final m = RegExp(r'^(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})_')
        .firstMatch(dirName);
    if (m == null) {
      return null;
    }
    return DateTime.utc(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
      int.parse(m.group(4)!),
      int.parse(m.group(5)!),
      int.parse(m.group(6)!),
    );
  }
}
