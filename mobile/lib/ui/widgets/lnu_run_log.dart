/// 1:1 复刻桌面端 `ui_qt/widgets/log_terminal.py` 的深海军蓝 `RUN LOG` 卷轴终端。
library;

import 'package:flutter/material.dart';

import '../../services/rush_controller.dart';
import '../theme/app_theme.dart';

class LnuRunLogTerminal extends StatefulWidget {
  final MobileRushController controller;
  final double height;
  final bool expandable;

  const LnuRunLogTerminal({
    super.key,
    required this.controller,
    this.height = 172,
    this.expandable = true,
  });

  @override
  State<LnuRunLogTerminal> createState() => _LnuRunLogTerminalState();
}

class _LnuRunLogTerminalState extends State<LnuRunLogTerminal> {
  int _selectedTab = 0; // 0=全部, 1=主账号, 2=副账号

  Color _lineColor(String text) {
    if (text.contains('成功') || text.contains('就绪')) {
      return const Color(0xFF86EFAC);
    }
    if (text.contains('⚠️') || text.contains('等待') || text.contains('重试')) {
      return LnuColors.amberLight;
    }
    if (text.contains('失败') || text.contains('异常') || text.contains('黑名单') || text.contains('中止')) {
      return const Color(0xFFFCA5A5);
    }
    return LnuColors.terminalText;
  }

  @override
  Widget build(BuildContext context) {
    final showAccount2 = widget.controller.config.useAccount2 &&
        widget.controller.config.account2.trim().isNotEmpty;
    if (!showAccount2 && _selectedTab == 2) {
      _selectedTab = 0;
    }
    final entries = widget.controller.logsForFilter(_selectedTab);

    return Container(
      decoration: BoxDecoration(
        color: LnuColors.inkDark,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: LnuColors.borderDark, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          // 桌面端同款 #003876 顶栏 + 红黄绿三点 + RUN LOG + tab 胶囊 + 清空
          Container(
            height: 40,
            color: LnuColors.ink,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: <Widget>[
                _dot(const Color(0xFFE85A51)),
                const SizedBox(width: 6),
                _dot(const Color(0xFFE7B94A)),
                const SizedBox(width: 6),
                _dot(const Color(0xFF5FB950)),
                const SizedBox(width: 10),
                const Text(
                  'RUN  LOG',
                  style: TextStyle(
                    color: LnuColors.amberGlow,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2.8,
                  ),
                ),
                const Spacer(),
                _filterChip('全部', 0),
                if (widget.controller.config.account1.trim().isNotEmpty) ...<Widget>[
                  const SizedBox(width: 4),
                  _filterChip('1', 1),
                ],
                if (showAccount2) ...<Widget>[
                  const SizedBox(width: 4),
                  _filterChip('2', 2),
                ],
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: widget.controller.clearLogs,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: LnuColors.amberHot.withValues(alpha: 0.7),
                      ),
                    ),
                    child: const Text(
                      '清空',
                      style: TextStyle(
                        color: LnuColors.amberLight,
                        fontSize: 10.5,
                        letterSpacing: 1.0,
                      ),
                    ),
                  ),
                ),
                if (widget.expandable) ...<Widget>[
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTap: () => _openFullscreen(context),
                    child: const Icon(
                      Icons.open_in_full_rounded,
                      size: 15,
                      color: LnuColors.amberLight,
                    ),
                  ),
                ],
              ],
            ),
          ),
          // 终端主体
          SizedBox(
            height: widget.height,
            child: entries.isEmpty
                ? const Center(
                    child: Text(
                      '待命中 · 准备就绪后点击上方按钮启动',
                      style: TextStyle(
                        color: Color(0xFF7A8FA8),
                        fontSize: 12,
                        letterSpacing: 0.8,
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    itemCount: entries.length,
                    itemBuilder: (_, idx) {
                      final e = entries[entries.length - 1 - idx];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2.2),
                        child: Text(
                          e.formatted,
                          style: LnuTheme.mono(
                            11.5,
                            weight: FontWeight.w400,
                            color: _lineColor(e.message),
                            letterSpacing: 0.2,
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _dot(Color c) => Container(
        width: 8.5,
        height: 8.5,
        decoration: BoxDecoration(color: c, shape: BoxShape.circle),
      );

  Widget _filterChip(String text, int tabIdx) {
    final active = _selectedTab == tabIdx;
    return GestureDetector(
      onTap: () => setState(() => _selectedTab = tabIdx),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
          color: active ? LnuColors.amber : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: active ? LnuColors.inkDark : LnuColors.amberLight,
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Future<void> _openFullscreen(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: LnuColors.inkDark,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.84,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: ListenableBuilder(
            listenable: widget.controller,
            builder: (ctx, __) => LnuRunLogTerminal(
              controller: widget.controller,
              height: MediaQuery.of(ctx).size.height * 0.72,
              expandable: false,
            ),
          ),
        ),
      ),
    );
  }
}
