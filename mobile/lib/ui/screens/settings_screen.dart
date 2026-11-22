/// 频道 ④：我的（双号接力可视化时间轴 + 清晰宣纸分组列表 + 密码/诊断全收纳至二级页）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../logic/seat_strategy.dart';
import '../../services/background_scheduler.dart';
import '../../services/config_store.dart';
import '../../services/log_exporter.dart';
import '../../services/notification_service.dart';
import '../../services/rush_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/lnu_chrome.dart';
import '../widgets/lnu_ticket_and_relay.dart';
import 'nightstand_screen.dart';

class SettingsScreen extends StatelessWidget {
  final MobileRushController controller;

  const SettingsScreen({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[controller, controller.config]),
      builder: (context, _) {
        final cfg = controller.config;
        final taggedCount = cfg.seatTags.length;

        return Column(
          children: <Widget>[
            const LnuPaperHeader(
              title: '我 的',
              subtitle: '明德精学 · 笃行致强',
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 36),
                children: <Widget>[
                  // 1. 双账号全天接力可视化时间轴卡片
                  Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Text(
                                '双账号全天接力排班',
                                style: LnuTheme.serif(15, weight: FontWeight.w700),
                              ),
                              const Spacer(),
                              GestureDetector(
                                onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) =>
                                        _AccountManagePage(config: cfg),
                                  ),
                                ),
                                child: const Text(
                                  '管理账号 ›',
                                  style: TextStyle(
                                    color: LnuColors.amberDeep,
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          LnuRelayTimeline(
                            account1: cfg.account1,
                            start1: cfg.start1,
                            end1: cfg.end1,
                            useAccount2: cfg.useAccount2,
                            account2: cfg.account2,
                            start2: cfg.start2,
                            end2: cfg.end2,
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 18),
                  _sectionTitle('策 略 与 偏 好'),
                  Card(
                    margin: EdgeInsets.zero,
                    child: Column(
                      children: <Widget>[
                        _groupRow(
                          icon: Icons.badge_outlined,
                          title: '校园卡账号',
                          trailingText: cfg.account1.isEmpty
                              ? '未配置'
                              : (cfg.useAccount2 ? '已配双号' : cfg.account1),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => _AccountManagePage(config: cfg),
                            ),
                          ),
                        ),
                        const Divider(height: 1, indent: 48),
                        _groupRow(
                          icon: Icons.bookmarks_outlined,
                          title: '自习方案管理',
                          trailingText: '${cfg.presets.length} 套方案',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => _PresetManagePage(config: cfg),
                            ),
                          ),
                        ),
                        const Divider(height: 1, indent: 48),
                        _groupRow(
                          icon: Icons.layers_outlined,
                          title: '备选自习室顺延',
                          trailingText: cfg.fallbackRooms.isEmpty
                              ? '未设置'
                              : '${cfg.fallbackRooms.length} 间',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => _FallbackRoomsPage(config: cfg),
                            ),
                          ),
                        ),
                        const Divider(height: 1, indent: 48),
                        _groupRow(
                          icon: Icons.star_border_rounded,
                          title: '宝藏座笔记',
                          trailingText: taggedCount == 0 ? '未标记' : '$taggedCount 处',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => _SeatNotesPage(config: cfg),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 18),
                  _sectionTitle('提 醒 · 保 活 · 诊 断'),
                  Card(
                    margin: EdgeInsets.zero,
                    child: Column(
                      children: <Widget>[
                        _groupRow(
                          icon: Icons.notifications_none_rounded,
                          title: '邮件与推送通知',
                          trailingText: _notificationStatusText(cfg),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => _NotificationPage(
                                config: cfg,
                                controller: controller,
                              ),
                            ),
                          ),
                        ),
                        const Divider(height: 1, indent: 48),
                        _groupRow(
                          icon: Icons.nights_stay_outlined,
                          title: '晨约守夜与后台保活',
                          trailingText: '配置向导',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  _KeepAliveGuidePage(controller: controller),
                            ),
                          ),
                        ),
                        const Divider(height: 1, indent: 48),
                        _groupRow(
                          icon: Icons.troubleshoot_outlined,
                          title: '运行记录与识图回放',
                          trailingText: '日志与诊断',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  _DiagnosticsPage(controller: controller),
                            ),
                          ),
                        ),
                        const Divider(height: 1, indent: 48),
                        _groupRow(
                          icon: Icons.tune_rounded,
                          title: '高级设置',
                          trailingText: '${cfg.apiFireOffsetMs}ms',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => _AdvancedSettingsPage(config: cfg),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 28),
                  Center(
                    child: Column(
                      children: <Widget>[
                        Text(
                          '明德精学 · 笃行致强',
                          style: LnuTheme.serif(
                            12.5,
                            weight: FontWeight.w600,
                            color: LnuColors.amberDeep,
                            letterSpacing: 3.0,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          '·  EST. 1948  ·  辽宁大学图书馆  ·',
                          style: TextStyle(
                            color: LnuColors.textDim,
                            fontSize: 10.5,
                            letterSpacing: 1.8,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  String _notificationStatusText(MobileConfigStore cfg) {
    final hasEmail = cfg.receiverEmail.trim().isNotEmpty;
    final hasHook = cfg.webhookUrl.trim().isNotEmpty;
    if (hasEmail && hasHook) {
      return '邮件 + 推送';
    }
    if (hasEmail) {
      return cfg.receiverEmail.trim();
    }
    if (hasHook) {
      return 'Webhook 已配';
    }
    return '未填邮箱';
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        text,
        style: const TextStyle(
          color: LnuColors.textMuted,
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 2.2,
        ),
      ),
    );
  }

  Widget _groupRow({
    required IconData icon,
    required String title,
    required String trailingText,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(icon, size: 20, color: LnuColors.ink),
      title: Text(
        title,
        style: const TextStyle(
          color: LnuColors.text,
          fontSize: 14.5,
          fontWeight: FontWeight.w500,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            trailingText,
            style: const TextStyle(color: LnuColors.textMuted, fontSize: 12.5),
          ),
          const SizedBox(width: 4),
          const Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: LnuColors.textDim,
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}

// ── 二级页 1：校园卡账号管理（密码安全收纳，不在主 Tab 裸奔） ──
class _AccountManagePage extends StatefulWidget {
  final MobileConfigStore config;
  const _AccountManagePage({required this.config});

  @override
  State<_AccountManagePage> createState() => _AccountManagePageState();
}

class _AccountManagePageState extends State<_AccountManagePage> {
  late TextEditingController _acc1;
  late TextEditingController _pwd1;
  late TextEditingController _start1;
  late TextEditingController _end1;
  late TextEditingController _acc2;
  late TextEditingController _pwd2;
  late TextEditingController _start2;
  late TextEditingController _end2;
  late TextEditingController _emailCtrl;
  bool _use2 = false;
  bool _hide1 = true;
  bool _hide2 = true;

  @override
  void initState() {
    super.initState();
    final c = widget.config;
    _acc1 = TextEditingController(text: c.account1);
    _pwd1 = TextEditingController(text: c.password1);
    _start1 = TextEditingController(text: c.start1);
    _end1 = TextEditingController(text: c.end1);
    _use2 = c.useAccount2;
    _acc2 = TextEditingController(text: c.account2);
    _pwd2 = TextEditingController(text: c.password2);
    _start2 = TextEditingController(text: c.start2);
    _end2 = TextEditingController(text: c.end2);
    _emailCtrl = TextEditingController(text: c.receiverEmail);
  }

  @override
  void dispose() {
    _acc1.dispose();
    _pwd1.dispose();
    _start1.dispose();
    _end1.dispose();
    _acc2.dispose();
    _pwd2.dispose();
    _start2.dispose();
    _end2.dispose();
    _emailCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final c = widget.config;
    c.account1 = _acc1.text.trim();
    c.password1 = _pwd1.text;
    c.start1 = _start1.text.trim();
    c.end1 = _end1.text.trim();
    c.useAccount2 = _use2;
    c.account2 = _acc2.text.trim();
    c.password2 = _pwd2.text;
    c.start2 = _start2.text.trim();
    c.end2 = _end2.text.trim();
    c.receiverEmail = _emailCtrl.text.trim();
    await c.saveToDisk();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('账号信息已加密存入系统安全库')),
      );
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('校园卡账号管理', style: LnuTheme.serif(17, weight: FontWeight.w700)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('主账号', style: LnuTheme.serif(15, weight: FontWeight.w700)),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _acc1,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '校园卡学号'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _pwd1,
                    obscureText: _hide1,
                    decoration: InputDecoration(
                      labelText: '密码（初始密码 000000）',
                      suffixIcon: IconButton(
                        icon: Icon(
                          _hide1
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                        ),
                        onPressed: () => setState(() => _hide1 = !_hide1),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: TextField(
                          controller: _start1,
                          decoration: const InputDecoration(labelText: '开始时段'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _end1,
                          decoration: const InputDecoration(labelText: '结束时段'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      '启用副账号（全天无缝接力）',
                      style: LnuTheme.serif(15, weight: FontWeight.w700),
                    ),
                    subtitle: const Text(
                      '例如主号 08:00–14:00 + 副号 14:00–20:00 无缝占同一心仪座',
                      style: TextStyle(fontSize: 12),
                    ),
                    value: _use2,
                    onChanged: (v) => setState(() => _use2 = v),
                  ),
                  if (_use2) ...<Widget>[
                    const SizedBox(height: 8),
                    TextField(
                      controller: _acc2,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '副账号学号'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _pwd2,
                      obscureText: _hide2,
                      decoration: InputDecoration(
                        labelText: '副账号密码',
                        suffixIcon: IconButton(
                          icon: Icon(
                            _hide2
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                          ),
                          onPressed: () => setState(() => _hide2 = !_hide2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: TextField(
                            controller: _start2,
                            decoration: const InputDecoration(labelText: '开始时段'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: _end2,
                            decoration: const InputDecoration(labelText: '结束时段'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('通知邮箱（选填）', style: LnuTheme.serif(15, weight: FontWeight.w700)),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: '接收预约成功战报的邮箱',
                      hintText: 'example@qq.com',
                      prefixIcon: Icon(Icons.mail_outline_rounded, size: 19),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          LnuAmberButton(label: '保  存  账  号', onPressed: _save),
        ],
      ),
    );
  }
}

// ── 二级页 2：自习方案管理 ──
class _PresetManagePage extends StatelessWidget {
  final MobileConfigStore config;
  const _PresetManagePage({required this.config});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('自习方案管理', style: LnuTheme.serif(17, weight: FontWeight.w700)),
      ),
      body: ListenableBuilder(
        listenable: config,
        builder: (context, _) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              for (final p in config.presets)
                Card(
                  child: ListTile(
                    title: Text(
                      p.name,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      '${p.campus.replaceAll("图书馆", "")} · ${p.room} · ${p.start1}–${p.end1}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        if (p.id == config.activePresetId)
                          const Padding(
                            padding: EdgeInsets.only(right: 8),
                            child: Text(
                              '当前使用',
                              style: TextStyle(
                                color: LnuColors.ok,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          )
                        else
                          TextButton(
                            onPressed: () => config.applyPreset(p),
                            child: const Text('启用'),
                          ),
                        if (config.presets.length > 1)
                          IconButton(
                            icon: const Icon(
                              Icons.delete_outline_rounded,
                              size: 19,
                              color: LnuColors.err,
                            ),
                            onPressed: () => config.deletePreset(p.id),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

// ── 二级页 3：备选自习室顺延 ──
class _FallbackRoomsPage extends StatelessWidget {
  final MobileConfigStore config;
  const _FallbackRoomsPage({required this.config});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('备选自习室顺延', style: LnuTheme.serif(17, weight: FontWeight.w700)),
        actions: <Widget>[
          TextButton(
            onPressed: () => _addRoomDialog(context),
            child: const Text('添加', style: TextStyle(color: LnuColors.amberDeep)),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: config,
        builder: (context, _) {
          if (config.fallbackRooms.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Text(
                    '主自习室无可用空座时，按此顺延列表自动切换',
                    style: TextStyle(color: LnuColors.textMuted, fontSize: 13),
                  ),
                  const SizedBox(height: 14),
                  LnuOutlineButton(
                    label: '添加备选自习室',
                    onPressed: () => _addRoomDialog(context),
                  ),
                ],
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: config.fallbackRooms.length,
            itemBuilder: (_, idx) {
              final target = config.fallbackRooms[idx];
              return Card(
                child: ListTile(
                  leading: CircleAvatar(
                    radius: 14,
                    backgroundColor: LnuColors.inkTint,
                    child: Text(
                      '${idx + 1}',
                      style: const TextStyle(
                        color: LnuColors.ink,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  title: Text(target.room),
                  subtitle: Text(
                    target.campus,
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () {
                      config.fallbackRooms.removeAt(idx);
                      config.saveToDisk();
                    },
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _addRoomDialog(BuildContext context) async {
    var pickCampus = config.campus;
    var pickRoom = config.catalog.roomsForCampus(pickCampus).first;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (_, setDlg) {
          final rooms = config.catalog.roomsForCampus(pickCampus);
          if (!rooms.contains(pickRoom) && rooms.isNotEmpty) {
            pickRoom = rooms.first;
          }
          return AlertDialog(
            backgroundColor: LnuColors.card,
            title: Text('添加备选自习室', style: LnuTheme.serif(16)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                DropdownButtonFormField<String>(
                  initialValue: pickCampus,
                  decoration: const InputDecoration(labelText: '校区'),
                  items: config.catalog.campuses.keys
                      .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) {
                      setDlg(() {
                        pickCampus = v;
                        pickRoom = config.catalog.roomsForCampus(v).first;
                      });
                    }
                  },
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: pickRoom,
                  decoration: const InputDecoration(labelText: '自习室'),
                  items: rooms
                      .map((r) => DropdownMenuItem(value: r, child: Text(r)))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) {
                      setDlg(() => pickRoom = v);
                    }
                  },
                ),
              ],
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  final t = RoomTarget(pickCampus, pickRoom);
                  if (!config.fallbackRooms.contains(t)) {
                    config.fallbackRooms.add(t);
                    config.saveToDisk();
                  }
                  Navigator.of(ctx).pop();
                },
                child: const Text('添加'),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ── 二级页 4：宝藏座笔记管理 ──
class _SeatNotesPage extends StatelessWidget {
  final MobileConfigStore config;
  const _SeatNotesPage({required this.config});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('宝藏座笔记', style: LnuTheme.serif(17, weight: FontWeight.w700)),
      ),
      body: ListenableBuilder(
        listenable: config,
        builder: (_, __) {
          if (config.seatTags.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  '在「寻座」页的座位网格中长按任意座号，即可标记电源、靠窗、宝藏座或风口避雷笔记。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: LnuColors.textMuted, height: 1.6),
                ),
              ),
            );
          }
          final entries = config.seatTags.entries.toList();
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: entries.length,
            itemBuilder: (_, idx) {
              final parts = entries[idx].key.split('::');
              final room = parts.first;
              final seatNo = parts.length > 1 ? parts[1] : '';
              final tags = entries[idx].value;
              return Card(
                child: ListTile(
                  title: Text('$room · $seatNo 号座'),
                  subtitle: Text(tags.join(' / ')),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline_rounded, size: 19),
                    onPressed: () {
                      config.seatTags.remove(entries[idx].key);
                      config.saveToDisk();
                    },
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// ── 二级页 5：邮件与 Webhook 推送 ──
class _NotificationPage extends StatefulWidget {
  final MobileConfigStore config;
  final MobileRushController controller;
  const _NotificationPage({
    required this.config,
    required this.controller,
  });

  @override
  State<_NotificationPage> createState() => _NotificationPageState();
}

class _NotificationPageState extends State<_NotificationPage> {
  late TextEditingController _emailCtrl;
  late TextEditingController _webhookCtrl;
  bool _sendingEmail = false;
  bool _sendingHook = false;

  @override
  void initState() {
    super.initState();
    _emailCtrl = TextEditingController(text: widget.config.receiverEmail);
    _webhookCtrl = TextEditingController(text: widget.config.webhookUrl);
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _webhookCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('邮件与推送通知', style: LnuTheme.serif(17, weight: FontWeight.w700)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Card(
            child: SwitchListTile(
              title: const Text('预约成功后自动开启签到提醒'),
              subtitle: const Text(
                '开始前 15 分钟与签到截止前 10 分钟由系统闹钟弹窗提醒（杀后台也生效）',
              ),
              value: widget.config.autoCheckinReminder,
              onChanged: (v) async {
                setState(() => widget.config.autoCheckinReminder = v);
                final scheduled =
                    await widget.controller.setAutoCheckinReminder(v);
                if (!context.mounted) {
                  return;
                }
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      v
                          ? (scheduled > 0
                              ? '已开启签到提醒，已为当前预约注册 $scheduled 个系统闹钟'
                              : '已开启签到提醒，后续预约将自动注册系统闹钟')
                          : '已关闭签到提醒，并撤回所有待触发闹钟',
                    ),
                  ),
                );
              },
            ),
          ),
          // 邮件战报通知（与桌面端一致，内置发件箱，填收件邮箱即可）
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '邮件通知（内置发件箱 · 免配 SMTP）',
                    style: LnuTheme.serif(15, weight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '填写你的常用邮箱（QQ / 163 / 126 / 校园邮箱均可），约座成功后立刻发送座位凭证邮件。',
                    style: TextStyle(color: LnuColors.textMuted, fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: '接收通知邮箱',
                      hintText: 'example@qq.com',
                      prefixIcon: Icon(Icons.mail_outline_rounded, size: 19),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: LnuOutlineButton(
                      label: _sendingEmail ? '发送中...' : '发送测试邮件',
                      onPressed: _sendingEmail
                          ? null
                          : () async {
                              final addr = _emailCtrl.text.trim();
                              if (addr.isNotEmpty && !addr.contains('@')) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('请填写有效的收件邮箱，或留空使用默认邮箱'),
                                  ),
                                );
                                return;
                              }
                              final targetAddr =
                                  NotificationService.resolveReceiverEmail(
                                addr,
                              );
                              setState(() => _sendingEmail = true);
                              widget.config.receiverEmail = addr;
                              await widget.config.saveToDisk();
                              final ok = await NotificationService.instance
                                  .sendEmail(
                                receiverEmail: targetAddr,
                                title: 'LNU LibSeat 邮件通知测试',
                                content:
                                    '你好，这封测试邮件来自 LNU LibSeat 手机端。\n约座成功后，你的座位凭证与签到提醒将第一时间发送到此邮箱。',
                              );
                              if (mounted) {
                                setState(() => _sendingEmail = false);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      ok
                                          ? '测试邮件已发送至 $targetAddr，请查收！'
                                          : '邮件发送失败，请检查网络连接或邮箱地址',
                                    ),
                                  ),
                                );
                              }
                            },
                    ),
                  ),
                ],
              ),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '外部 Webhook 推送（可选）',
                    style: LnuTheme.serif(15, weight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '自动识别 Bark (iOS) / PushPlus / Server酱 / 企业微信 / 飞书 / 钉钉机器人',
                    style: TextStyle(color: LnuColors.textMuted, fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _webhookCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Webhook 地址',
                      hintText: 'https://api.day.app/<Key>/',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: LnuOutlineButton(
                      label: _sendingHook ? '发送中...' : '测试 Webhook',
                      onPressed: _sendingHook
                          ? null
                          : () async {
                              setState(() => _sendingHook = true);
                              widget.config.webhookUrl =
                                  _webhookCtrl.text.trim();
                              await widget.config.saveToDisk();
                              final ok = await NotificationService.instance
                                  .sendWebhook(
                                webhookUrl: widget.config.webhookUrl,
                                title: 'LNU LibSeat 测试通知',
                                content: '推送通道连接正常，约座成功后将第一时间送达。',
                              );
                              if (mounted) {
                                setState(() => _sendingHook = false);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      ok ? 'Webhook 测试推送已送达' : '发送失败，请检查地址是否正确',
                                    ),
                                  ),
                                );
                              }
                            },
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          LnuAmberButton(
            label: '保  存  通  知  设  置',
            onPressed: () async {
              widget.config.receiverEmail = _emailCtrl.text.trim();
              widget.config.webhookUrl = _webhookCtrl.text.trim();
              await widget.config.saveToDisk();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('通知邮箱与推送设置已保存')),
                );
                Navigator.of(context).pop();
              }
            },
          ),
        ],
      ),
    );
  }
}

// ── 二级页 6：晨约守夜与后台保活向导 ──
class _KeepAliveGuidePage extends StatefulWidget {
  final MobileRushController controller;
  const _KeepAliveGuidePage({required this.controller});

  @override
  State<_KeepAliveGuidePage> createState() => _KeepAliveGuidePageState();
}

class _KeepAliveGuidePageState extends State<_KeepAliveGuidePage>
    with WidgetsBindingObserver {
  AndroidKeepAliveStatus _status = const AndroidKeepAliveStatus();
  bool _loadingStatus = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshStatus();
    }
  }

  Future<void> _refreshStatus() async {
    if (!Platform.isAndroid) {
      return;
    }
    setState(() => _loadingStatus = true);
    final st =
        await BackgroundSchedulerService.instance.getAndroidKeepAliveStatus();
    if (mounted) {
      setState(() {
        _status = st;
        _loadingStatus = false;
      });
    }
  }

  Widget _statusChip(bool ok, String okText, String warnText) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: (ok ? LnuColors.ok : LnuColors.warn).withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        ok ? okText : warnText,
        style: TextStyle(
          color: ok ? LnuColors.ok : LnuColors.amberDeep,
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '晨约守夜与后台保活',
          style: LnuTheme.serif(17, weight: FontWeight.w700),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          if (Platform.isIOS)
            const Card(
              child: ListTile(
                leading: Icon(
                  Icons.bedtime_rounded,
                  color: LnuColors.amberHot,
                ),
                title: Text('iOS 锁屏后台静音保活（已内置自动开启）'),
                subtitle: Text(
                  '启动定时抢座后自动防系统冻结，按电源键锁屏或切后台均可准点 06:30 开抢；'
                  '请勿上滑强杀 App，过夜建议插电更稳妥。',
                ),
              ),
            ),
          if (Platform.isAndroid) ...<Widget>[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Icon(
                          _status.allReady
                              ? Icons.verified_user_outlined
                              : Icons.shield_outlined,
                          size: 18,
                          color: _status.allReady
                              ? LnuColors.ok
                              : LnuColors.amberHot,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _status.allReady
                              ? '隔夜防杀保活权限已全部就绪'
                              : '隔夜抢座保活体检（建议全部开启）',
                          style: LnuTheme.serif(14.5, weight: FontWeight.w700),
                        ),
                        const Spacer(),
                        if (_loadingStatus)
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 1.8),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      '内置 4 重隔夜防杀：系统 AlarmClock 闹钟级唤醒 + 动态 24h WakeLock + WifiLock 防息屏断网 + 夜间进程被杀自动拉起续抢 & 重启自恢复。',
                      style: TextStyle(
                        color: LnuColors.textMuted,
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Card(
              child: Column(
                children: <Widget>[
                  ListTile(
                    leading: const Icon(
                      Icons.battery_saver_rounded,
                      color: LnuColors.amberHot,
                    ),
                    title: const Text('电池优化白名单（无限制）'),
                    subtitle: const Text('小米/华为/vivo/OPPO 隔夜不杀后台必开'),
                    trailing: _statusChip(
                      _status.ignoringBatteryOptimizations,
                      '已开启',
                      '去开启',
                    ),
                    onTap: () => BackgroundSchedulerService.instance
                        .requestIgnoreBatteryOptimizations(),
                  ),
                  const Divider(height: 1, indent: 52),
                  ListTile(
                    leading: const Icon(
                      Icons.alarm_on_rounded,
                      color: LnuColors.ink,
                    ),
                    title: const Text('精确闹钟权限（AlarmClock）'),
                    subtitle: const Text('允许 06:29:25 穿透深度休眠唤醒与复活进程'),
                    trailing: _statusChip(
                      _status.canScheduleExactAlarms,
                      '已授权',
                      '去授权',
                    ),
                    onTap: () => BackgroundSchedulerService.instance
                        .requestExactAlarmPermission(),
                  ),
                  const Divider(height: 1, indent: 52),
                  ListTile(
                    leading: const Icon(
                      Icons.notifications_active_outlined,
                      color: LnuColors.inkLight,
                    ),
                    title: const Text('系统通知权限'),
                    subtitle: const Text('用于守夜常驻通知、准点唤醒与签到防违约提醒'),
                    trailing: _statusChip(
                      _status.notificationsEnabled,
                      '已开启',
                      '去开启',
                    ),
                    onTap: () => BackgroundSchedulerService.instance
                        .openAppNotificationSettings(),
                  ),
                  const Divider(height: 1, indent: 52),
                  ListTile(
                    leading: const Icon(
                      Icons.fullscreen_rounded,
                      color: LnuColors.ink,
                    ),
                    title: const Text('锁屏全屏唤醒权限（Android 14+）'),
                    subtitle: const Text('允许准点闹钟穿透锁屏直接拉起解冻抢座引擎'),
                    trailing: _statusChip(
                      _status.canUseFullScreenIntent,
                      '已开启',
                      '去开启',
                    ),
                    onTap: () => BackgroundSchedulerService.instance
                        .requestFullScreenIntentPermission(),
                  ),
                  const Divider(height: 1, indent: 52),
                  ListTile(
                    leading: const Icon(
                      Icons.tune_rounded,
                      color: LnuColors.amberDeep,
                    ),
                    title: const Text('vivo / 小米 / 华为 / OPPO 专属保活项'),
                    subtitle: const Text(
                      '必开：允许后台高耗电 + 自启动 + 后台弹出界面 + 锁屏显示（点此直达应用信息）',
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => BackgroundSchedulerService.instance
                        .openAppDetailsSettings(),
                  ),
                ],
              ),
            ),
          ],
          Card(
            child: ListTile(
              leading:
                  const Icon(Icons.nights_stay_outlined, color: LnuColors.ink),
              title: const Text('立即进入「银杏夜守」OLED 书桌时钟'),
              subtitle: const Text('纯黑微光防烧屏常亮，睡前插电 06:30 稳如磐石'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      NightstandScreen(controller: widget.controller),
                ),
              ),
            ),
          ),
          Card(
            child: ListTile(
              leading:
                  const Icon(Icons.link_rounded, color: LnuColors.inkLight),
              title: const Text('复制 iOS 快捷指令自动唤醒链接'),
              subtitle: const Text('lnulibseat://rush?mode=auto · 搭配 06:29 个人自动化'),
              trailing: const Icon(Icons.copy_rounded, size: 18),
              onTap: () {
                Clipboard.setData(
                  const ClipboardData(text: 'lnulibseat://rush?mode=auto'),
                );
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('已复制 lnulibseat://rush?mode=auto'),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ── 二级页 7：运行记录与识图回放（调试图优雅收纳在此，绝不污染首页！） ──
class _DiagnosticsPage extends StatefulWidget {
  final MobileRushController controller;
  const _DiagnosticsPage({required this.controller});

  @override
  State<_DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<_DiagnosticsPage> {
  bool _exporting = false;

  Rect? _shareOrigin(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) {
      return null;
    }
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('运行记录与识图回放', style: LnuTheme.serif(17, weight: FontWeight.w700)),
      ),
      body: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final diag = widget.controller.latestDiagnostic;
          final inv = MobileLogExporter.scanInventory(
            widget.controller.config.logBaseDir,
          );
          return ListView(
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '最近一次点选识图叠加回放',
                        style: LnuTheme.serif(15, weight: FontWeight.w700),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        diag == null
                            ? '本轮尚未触发点选验证码识别'
                            : '类型：${diag.kind} · 用时：${diag.elapsedMs.round()}ms · 结果：${diag.ok ? "命中" : "刷新重取"}',
                        style: const TextStyle(
                          color: LnuColors.textMuted,
                          fontSize: 12.5,
                        ),
                      ),
                      if (diag?.renderedPngBytes != null) ...<Widget>[
                        const SizedBox(height: 12),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.memory(
                            diag!.renderedPngBytes!,
                            fit: BoxFit.contain,
                            width: double.infinity,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              Card(
                child: Column(
                  children: <Widget>[
                    ListTile(
                      leading: const Icon(Icons.ios_share_rounded, color: LnuColors.ok),
                      title: const Text('导出最近一轮抢座日志（含双账号）'),
                      subtitle: const Text('含运行终端日志 + 主/副账号脱敏 HTTP 流水 + 抢座顺序'),
                      trailing: _exporting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.chevron_right_rounded),
                      onTap: _exporting ? null : () => _exportLatestBatch(context),
                    ),
                    const Divider(height: 1, indent: 52),
                    ListTile(
                      leading: const Icon(Icons.folder_zip_outlined, color: LnuColors.ink),
                      title: const Text('打包导出全部历史抢座日志 (.zip)'),
                      subtitle: Text(
                        inv.sessionCount == 0
                            ? '当前尚无历史会话记录（密码/Token 已自动脱敏）'
                            : '共 ${inv.sessionCount} 场会话 · ${inv.fileCount} 个文件 (${inv.formattedSize})，含识图回放图',
                      ),
                      trailing: _exporting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.chevron_right_rounded),
                      onTap: _exporting ? null : () => _exportAllZip(context),
                    ),
                  ],
                ),
              ),
              if (Platform.isIOS)
                const Card(
                  child: ListTile(
                    leading: Icon(Icons.folder_open_rounded, color: LnuColors.amberHot),
                    title: Text('iOS「文件」App 直接访问'),
                    subtitle: Text(
                      '也可打开系统自带「文件」App →「我的 iPhone」→「LNU-LibSeat」→「lnu_libseat_logs」随时浏览或隔空投送全部脱敏日志。',
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _exportLatestBatch(BuildContext context) async {
    final files = MobileLogExporter.collectLatestRushFiles(
      widget.controller.config.logBaseDir,
    );
    if (files.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('当前尚无运行会话日志')),
        );
      }
      return;
    }
    setState(() => _exporting = true);
    try {
      await Share.shareXFiles(
        files.map((f) => XFile(f.path)).toList(growable: false),
        text: 'LNU LibSeat 最近一轮抢座脱敏诊断日志（共 ${files.length} 个文件）',
        sharePositionOrigin: _shareOrigin(context),
      );
    } finally {
      if (mounted) {
        setState(() => _exporting = false);
      }
    }
  }

  Future<void> _exportAllZip(BuildContext context) async {
    setState(() => _exporting = true);
    try {
      final zipFile = MobileLogExporter.exportAllLogsToZip(
        widget.controller.config.logBaseDir,
      );
      if (zipFile == null || !zipFile.existsSync()) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('当前尚无历史抢座日志可打包')),
          );
        }
        return;
      }
      if (!context.mounted) {
        return;
      }
      await Share.shareXFiles(
        <XFile>[XFile(zipFile.path)],
        text: 'LNU LibSeat 全部历史抢座脱敏日志包',
        sharePositionOrigin: _shareOrigin(context),
      );
    } finally {
      if (mounted) {
        setState(() => _exporting = false);
      }
    }
  }
}

// ── 二级页 8：高级设置 ──
class _AdvancedSettingsPage extends StatefulWidget {
  final MobileConfigStore config;
  const _AdvancedSettingsPage({required this.config});

  @override
  State<_AdvancedSettingsPage> createState() => _AdvancedSettingsPageState();
}

class _AdvancedSettingsPageState extends State<_AdvancedSettingsPage> {
  late TextEditingController _offsetCtrl;
  late TextEditingController _baseUrlCtrl;

  @override
  void initState() {
    super.initState();
    _offsetCtrl =
        TextEditingController(text: widget.config.apiFireOffsetMs.toString());
    _baseUrlCtrl = TextEditingController(text: widget.config.apiBaseUrl);
  }

  @override
  void dispose() {
    _offsetCtrl.dispose();
    _baseUrlCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('高级设置', style: LnuTheme.serif(17, weight: FontWeight.w700)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: <Widget>[
                  TextField(
                    controller: _offsetCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '准点延迟（毫秒）',
                      helperText: '与馆端时钟校准后顺延触发，避免踩 06:30 切换边界（默认 200）',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _baseUrlCtrl,
                    decoration: const InputDecoration(
                      labelText: '预约系统地址',
                    ),
                  ),
                  const SizedBox(height: 16),
                  LnuAmberButton(
                    label: '保  存  参  数',
                    onPressed: () async {
                      widget.config.apiFireOffsetMs =
                          int.tryParse(_offsetCtrl.text.trim()) ?? 200;
                      widget.config.apiBaseUrl = _baseUrlCtrl.text.trim();
                      await widget.config.saveToDisk();
                      if (context.mounted) {
                        Navigator.of(context).pop();
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
