/// 频道 ②：寻座（崇山银杏馆 & 蒲河溯源馆 · 楼层剖面余座态势 + 宝藏座网格 + 满员蹲空座）。
library;

import 'package:flutter/material.dart';

import '../../core/libseat_client.dart';
import '../../logic/seat_strategy.dart';
import '../../services/config_store.dart';
import '../../services/rush_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/lnu_chrome.dart';

class SeatRadarScreen extends StatefulWidget {
  final MobileRushController controller;
  final VoidCallback onJumpToHomeRush;

  const SeatRadarScreen({
    super.key,
    required this.controller,
    required this.onJumpToHomeRush,
  });

  @override
  State<SeatRadarScreen> createState() => _SeatRadarScreenState();
}

class _SeatRadarScreenState extends State<SeatRadarScreen> {
  late String _selectedCampus;

  @override
  void initState() {
    super.initState();
    _selectedCampus = widget.controller.config.campus;
  }

  bool get _isChongshan => _selectedCampus.contains('崇山');

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        widget.controller,
        widget.controller.config,
      ]),
      builder: (context, _) {
        final ctrl = widget.controller;
        final campuses = ctrl.config.catalog.campuses.keys.toList();
        final stats = ctrl.radarStats;

        final totalFree = stats.fold<int>(0, (s, r) => s + r.freeSeats);
        final totalSeats = stats.fold<int>(0, (s, r) => s + r.totalSeats);
        final freePct = totalSeats > 0
            ? ((totalFree * 100.0) / totalSeats).round()
            : 0;
        RoomStats? roomiest;
        for (final r in stats) {
          if (roomiest == null || r.freeSeats > roomiest.freeSeats) {
            roomiest = r;
          }
        }

        // 按楼层从高到低分组（建筑剖面视觉）
        final floorsMap = <int, List<RoomStats>>{};
        for (final st in stats) {
          floorsMap.putIfAbsent(st.floor, () => <RoomStats>[]).add(st);
        }
        final sortedFloors = floorsMap.keys.toList()
          ..sort((a, b) => b.compareTo(a));
        for (final list in floorsMap.values) {
          list.sort((a, b) => b.freeSeats.compareTo(a.freeSeats));
        }

        return Column(
          children: <Widget>[
            LnuPaperHeader(
              title: '寻 座',
              subtitle: _isChongshan ? '崇山馆 · 百年银杏路畔' : '蒲河馆 · 溯源湖畔',
              trailing: GestureDetector(
                onTap: ctrl.radarLoading
                    ? null
                    : () => ctrl.refreshRoomRadar(campusName: _selectedCampus),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: LnuColors.card,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: LnuColors.borderDark),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (ctrl.radarLoading)
                        const SizedBox(
                          width: 13,
                          height: 13,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.8,
                            color: LnuColors.ink,
                          ),
                        )
                      else
                        const Icon(
                          Icons.refresh_rounded,
                          size: 15,
                          color: LnuColors.ink,
                        ),
                      const SizedBox(width: 5),
                      const Text(
                        '刷新余座',
                        style: TextStyle(
                          color: LnuColors.ink,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                children: <Widget>[
                  // 1. 宣纸风双校区切换器
                  _buildCampusSwitcher(campuses, ctrl),
                  const SizedBox(height: 12),

                  // 2. 满员蹲空座进行中横幅
                  if (ctrl.watchingRoomName != null)
                    _buildWatchingBanner(ctrl),

                  // 3. 崇山银杏 / 蒲河溯源 文化态势总览卡
                  _buildCampusOverviewCard(
                    context,
                    totalFree: totalFree,
                    totalSeats: totalSeats,
                    freePct: freePct,
                    roomiest: roomiest,
                    hasData: stats.isNotEmpty,
                  ),

                  if (ctrl.radarError.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(top: 10),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: LnuColors.errLight,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        ctrl.radarError,
                        style: const TextStyle(
                          color: LnuColors.err,
                          fontSize: 12.5,
                        ),
                      ),
                    ),

                  const SizedBox(height: 14),

                  // 4. 建筑楼层剖面分组列表（无数据时展示该校区离线自习室快捷入口）
                  if (stats.isEmpty && !ctrl.radarLoading)
                    _buildOfflineRoomPreview(context, ctrl)
                  else
                    for (final floor in sortedFloors) ...<Widget>[
                      _buildFloorDivider(floor),
                      Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        child: Column(
                          children: <Widget>[
                            for (var i = 0;
                                i < floorsMap[floor]!.length;
                                i++) ...<Widget>[
                              if (i > 0)
                                const Divider(
                                  height: 1,
                                  indent: 14,
                                  endIndent: 14,
                                ),
                              _buildRoomRow(context, floorsMap[floor]![i], ctrl),
                            ],
                          ],
                        ),
                      ),
                    ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildCampusSwitcher(
    List<String> campuses,
    MobileRushController ctrl,
  ) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: LnuColors.cardSunk,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: LnuColors.border),
      ),
      child: Row(
        children: campuses.map((c) {
          final selected = c == _selectedCampus;
          final shortLabel = c.replaceAll('图书馆', '');
          return Expanded(
            child: GestureDetector(
              onTap: () {
                if (!selected) {
                  setState(() => _selectedCampus = c);
                  ctrl.refreshRoomRadar(campusName: c);
                }
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(vertical: 9),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected ? LnuColors.card : Colors.transparent,
                  borderRadius: BorderRadius.circular(9),
                  border: selected
                      ? Border.all(color: LnuColors.border)
                      : null,
                ),
                child: Text(
                  shortLabel,
                  style: TextStyle(
                    color: selected ? LnuColors.ink : LnuColors.textMuted,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    fontSize: 13.5,
                    letterSpacing: 1.4,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildWatchingBanner(MobileRushController ctrl) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: LnuColors.amberGlow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: LnuColors.amberHot.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: <Widget>[
          const Icon(
            Icons.hourglass_top_rounded,
            size: 16,
            color: LnuColors.amberDeep,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '正在低频蹲守「${ctrl.watchingRoomName}」空座释出（每分钟轻查 · 第 ${ctrl.watchCheckCount} 次）',
              style: const TextStyle(
                color: LnuColors.amberDeep,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          GestureDetector(
            onTap: ctrl.stopRoomWatch,
            child: const Text(
              '停止',
              style: TextStyle(
                color: LnuColors.err,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCampusOverviewCard(
    BuildContext context, {
    required int totalFree,
    required int totalSeats,
    required int freePct,
    required RoomStats? roomiest,
    required bool hasData,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: LnuColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: LnuColors.borderDark, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: CustomPaint(
        painter: LnuCampusMotifPainter(
          isChongshan: _isChongshan,
          color: (_isChongshan ? LnuColors.amber : LnuColors.inkLight)
              .withValues(alpha: 0.28),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Text(
                    _isChongshan ? '崇山馆 · 银杏路畔' : '蒲河馆 · 溯源湖畔',
                    style: const TextStyle(
                      color: LnuColors.amberDeep,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const Spacer(),
                  if (hasData)
                    Text(
                      '空座率 $freePct%',
                      style: LnuTheme.mono(
                        12,
                        color: LnuColors.textMuted,
                        weight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: <Widget>[
                  Text(
                    hasData ? '$totalFree' : '—',
                    style: LnuTheme.serif(
                      38,
                      weight: FontWeight.w800,
                      color: LnuColors.ink,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    hasData ? '个实时空座（共 $totalSeats 座）' : '点击右上角「刷新余座」查看全馆实时态势',
                    style: const TextStyle(
                      color: LnuColors.textMuted,
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ),
              if (roomiest != null && roomiest.freeSeats > 0) ...<Widget>[
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 10),
                  child: Divider(height: 1),
                ),
                GestureDetector(
                  onTap: () => _openRoomSeatGridSheet(context, roomiest.roomName),
                  child: Row(
                    children: <Widget>[
                      const Text(
                        '此刻最宽裕：',
                        style: TextStyle(
                          color: LnuColors.textMuted,
                          fontSize: 12.5,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          '${roomiest.roomName}（余 ${roomiest.freeSeats} 座）',
                          style: const TextStyle(
                            color: LnuColors.ink,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const Icon(
                        Icons.arrow_forward_rounded,
                        size: 16,
                        color: LnuColors.amberHot,
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFloorDivider(int floor) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
      child: Row(
        children: <Widget>[
          Text(
            floor > 0 ? '${floor}F' : '馆区',
            style: LnuTheme.mono(
              12.5,
              weight: FontWeight.w700,
              color: LnuColors.amberDeep,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(width: 8),
          const Expanded(
            child: Divider(height: 1, color: LnuColors.borderDark),
          ),
        ],
      ),
    );
  }

  Widget _buildRoomRow(
    BuildContext context,
    RoomStats st,
    MobileRushController ctrl,
  ) {
    final total = st.totalSeats > 0 ? st.totalSeats : 1;
    final ratio = (st.freeSeats / total).clamp(0.0, 1.0);
    final filledBlocks = (ratio * 10).ceil().clamp(0, 10);
    final isFull = st.freeSeats <= 0;
    final isTight = !isFull && ratio < 0.2;
    final statusColor = isFull
        ? LnuColors.textDim
        : (isTight ? LnuColors.warn : LnuColors.ok);
    final isWatchingThis = ctrl.watchingRoomName == st.roomName;

    return InkWell(
      onTap: () => _openRoomSeatGridSheet(context, st.roomName),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        st.roomName,
                        style: TextStyle(
                          color: isFull ? LnuColors.textMuted : LnuColors.ink,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        RoomCatalog.roomFacilityHint(st.roomName),
                        style: const TextStyle(
                          color: LnuColors.textDim,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ),
                ),
                if (isFull)
                  GestureDetector(
                    onTap: () {
                      if (isWatchingThis) {
                        ctrl.stopRoomWatch();
                      } else {
                        ctrl.startRoomWatch(_selectedCampus, st.roomName);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('已开启「${st.roomName}」低频蹲空座，有空位将立即提醒'),
                          ),
                        );
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: isWatchingThis
                            ? LnuColors.amberHot
                            : LnuColors.cardSunk,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(
                        isWatchingThis ? '蹲守中' : '蹲空座',
                        style: TextStyle(
                          color: isWatchingThis
                              ? Colors.white
                              : LnuColors.textMuted,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  )
                else
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '余 ${st.freeSeats}',
                      style: TextStyle(
                        color: statusColor,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                // 10 格微型色块余座刻度
                for (var b = 0; b < 10; b++)
                  Container(
                    width: 12,
                    height: 5,
                    margin: const EdgeInsets.only(right: 3),
                    decoration: BoxDecoration(
                      color: b < filledBlocks
                          ? statusColor
                          : LnuColors.cardSunk,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                const SizedBox(width: 8),
                Text(
                  '${st.freeSeats} / ${st.totalSeats}',
                  style: LnuTheme.mono(11, color: LnuColors.textMuted),
                ),
                const Spacer(),
                const Text(
                  '选座 ›',
                  style: TextStyle(
                    color: LnuColors.amberDeep,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOfflineRoomPreview(
    BuildContext context,
    MobileRushController ctrl,
  ) {
    final rooms = ctrl.config.catalog.roomsForCampus(_selectedCampus);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text(
                  '馆内自习室一览',
                  style: LnuTheme.serif(15, weight: FontWeight.w700),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () => ctrl.refreshRoomRadar(campusName: _selectedCampus),
                  child: const Text(
                    '拉取实时余座 →',
                    style: TextStyle(
                      color: LnuColors.amberDeep,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: rooms.map((r) {
                return ActionChip(
                  backgroundColor: LnuColors.bgPaper,
                  side: const BorderSide(color: LnuColors.border),
                  label: Text(r, style: const TextStyle(fontSize: 12.5)),
                  onPressed: () => _openRoomSeatGridSheet(context, r),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openRoomSeatGridSheet(
    BuildContext context,
    String roomName,
  ) async {
    final ctrl = widget.controller;
    ctrl.loadRoomSeatMap(_selectedCampus, roomName);

    var filterMode = 0; // 0=全部, 1=只看空座, 2=宝藏座
    var searchQuery = '';
    SeatCandidate? pickedSeat;
    List<SeatAvailableWindow> probedWindows = const <SeatAvailableWindow>[];
    var probeError = '';
    var probingTimes = false;
    var selectedWindowIndex = 0;
    var selectedStart = 'now';
    var selectedEnd = '22:00';

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: LnuColors.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.85,
              maxChildSize: 0.95,
              minChildSize: 0.55,
              builder: (_, scrollController) {
                return ListenableBuilder(
                  listenable: Listenable.merge(<Listenable>[ctrl, ctrl.config]),
                  builder: (_, __) {
                    final allSeats = ctrl.selectedRoomSeats;
                    final freeCount = allSeats
                        .where((s) => s.status == SeatStatus.free)
                        .length;

                    final filtered = allSeats.where((s) {
                      if (searchQuery.isNotEmpty &&
                          !s.seatNo.toLowerCase().contains(searchQuery.toLowerCase())) {
                        return false;
                      }
                      if (filterMode == 1 && s.status != SeatStatus.free) {
                        return false;
                      }
                      if (filterMode == 2 &&
                          ctrl.config.tagsForSeat(roomName, s.seatNo).isEmpty) {
                        return false;
                      }
                      return true;
                    }).toList();

                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(
                                      roomName,
                                      style: LnuTheme.serif(
                                        17.5,
                                        weight: FontWeight.w700,
                                      ),
                                    ),
                                    Text(
                                      '空 $freeCount / 共 ${allSeats.length} 座 · 长按座号可标记电源/靠窗',
                                      style: const TextStyle(
                                        color: LnuColors.textMuted,
                                        fontSize: 11.5,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                onPressed: () => Navigator.of(sheetCtx).pop(),
                                icon: const Icon(Icons.close_rounded),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          // 过滤胶囊 + 搜座号
                          Row(
                            children: <Widget>[
                              _gridFilterChip('全部', filterMode == 0, () {
                                setSheetState(() => filterMode = 0);
                              }),
                              const SizedBox(width: 6),
                              _gridFilterChip('只看空座', filterMode == 1, () {
                                setSheetState(() => filterMode = 1);
                              }),
                              const SizedBox(width: 6),
                              _gridFilterChip('宝藏座', filterMode == 2, () {
                                setSheetState(() => filterMode = 2);
                              }),
                              const Spacer(),
                              SizedBox(
                                width: 92,
                                height: 32,
                                child: TextField(
                                  onChanged: (v) =>
                                      setSheetState(() => searchQuery = v.trim()),
                                  style: const TextStyle(fontSize: 12),
                                  decoration: const InputDecoration(
                                    hintText: '搜座号',
                                    contentPadding: EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 4,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Expanded(
                            child: ctrl.radarLoading
                                ? const Center(
                                    child: CircularProgressIndicator(
                                      color: LnuColors.ink,
                                    ),
                                  )
                                : GridView.builder(
                                    controller: scrollController,
                                    gridDelegate:
                                        const SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: 6,
                                      mainAxisSpacing: 8,
                                      crossAxisSpacing: 8,
                                      childAspectRatio: 1.18,
                                    ),
                                    itemCount: filtered.length,
                                    itemBuilder: (_, idx) {
                                      final seat = filtered[idx];
                                      final isFree =
                                          seat.status == SeatStatus.free;
                                      final isPicked =
                                          pickedSeat?.seatId == seat.seatId;
                                      final tags = ctrl.config
                                          .tagsForSeat(roomName, seat.seatNo);

                                      final Color bg;
                                      final Color border;
                                      final Color fg;
                                      if (isPicked) {
                                        bg = LnuColors.ink;
                                        border = LnuColors.ink;
                                        fg = Colors.white;
                                      } else if (isFree) {
                                        bg = LnuColors.card;
                                        border = LnuColors.ok;
                                        fg = LnuColors.ok;
                                      } else {
                                        bg = LnuColors.cardSunk;
                                        border = LnuColors.border;
                                        fg = LnuColors.textDim;
                                      }

                                      return GestureDetector(
                                        onLongPress: () => _openSeatTagDialog(
                                          ctx,
                                          roomName,
                                          seat.seatNo,
                                        ),
                                        onTap: () async {
                                          if (seat.status ==
                                              SeatStatus.unavailable) {
                                            ScaffoldMessenger.of(ctx)
                                                .showSnackBar(
                                              SnackBar(
                                                content: Text(
                                                  '${seat.seatNo} 号当前不可用，长按可标记笔记',
                                                ),
                                              ),
                                            );
                                            return;
                                          }
                                          setSheetState(() {
                                            pickedSeat = seat;
                                            probingTimes = true;
                                            probedWindows =
                                                const <SeatAvailableWindow>[];
                                            probeError = '';
                                            selectedWindowIndex = 0;
                                          });
                                          final res = await ctrl
                                              .probeSeatAvailableWindows(
                                            seat.seatId,
                                          );
                                          if (ctx.mounted &&
                                              pickedSeat?.seatId ==
                                                  seat.seatId) {
                                            setSheetState(() {
                                              probingTimes = false;
                                              probedWindows = res.windows;
                                              probeError = res.error;
                                              if (res.windows.isNotEmpty) {
                                                selectedWindowIndex = 0;
                                                selectedStart =
                                                    res.windows.first.startParam;
                                                selectedEnd =
                                                    res.windows.first.endParam;
                                              }
                                            });
                                          }
                                        },
                                        child: Stack(
                                          children: <Widget>[
                                            Container(
                                              alignment: Alignment.center,
                                              decoration: BoxDecoration(
                                                color: bg,
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                                border: Border.all(
                                                  color: border,
                                                  width: isFree || isPicked
                                                      ? 1.3
                                                      : 0.8,
                                                ),
                                              ),
                                              child: Text(
                                                seat.seatNo,
                                                style: TextStyle(
                                                  color: fg,
                                                  fontWeight: FontWeight.w700,
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ),
                                            if (tags.isNotEmpty)
                                              Positioned(
                                                right: 3,
                                                top: 3,
                                                child: Container(
                                                  width: 6,
                                                  height: 6,
                                                  decoration: BoxDecoration(
                                                    color: tags.contains('避雷')
                                                        ? LnuColors.err
                                                        : LnuColors.amberHot,
                                                    shape: BoxShape.circle,
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                          ),

                          // 底部双意图操作栏（选中任意可用座位时展开，列出今日全部可约时段）
                          if (pickedSeat != null) ...<Widget>[
                            const Divider(height: 16),
                            Row(
                              children: <Widget>[
                                Text(
                                  '已选 ${pickedSeat!.seatNo} 号座',
                                  style: LnuTheme.serif(
                                    14.5,
                                    weight: FontWeight.w700,
                                  ),
                                ),
                                if (pickedSeat!.status != SeatStatus.free) ...<Widget>[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: LnuColors.cardSunk,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: LnuColors.border,
                                      ),
                                    ),
                                    child: const Text(
                                      '当前已占',
                                      style: TextStyle(
                                        color: LnuColors.textMuted,
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                                const SizedBox(width: 8),
                                Expanded(
                                  child: probingTimes
                                      ? const Row(
                                          children: <Widget>[
                                            SizedBox(
                                              width: 11,
                                              height: 11,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 1.6,
                                                color: LnuColors.amberDeep,
                                              ),
                                            ),
                                            SizedBox(width: 6),
                                            Flexible(
                                              child: Text(
                                                '正在探测今日全部可约时段...',
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: LnuColors.textMuted,
                                                  fontSize: 11.5,
                                                ),
                                              ),
                                            ),
                                          ],
                                        )
                                      : Text(
                                          probeError.isNotEmpty
                                              ? '探测失败，默认：$selectedStart — $selectedEnd'
                                              : (probedWindows.isEmpty
                                                  ? '今日已约满（可存入明日首选）'
                                                  : '今日可约 ${probedWindows.length} 段${probedWindows.length > 1 ? ' · 点选切换' : ''}'),
                                          overflow: TextOverflow.ellipsis,
                                          style: LnuTheme.mono(
                                            11.5,
                                            color: probedWindows.isEmpty &&
                                                    probeError.isEmpty
                                                ? LnuColors.textMuted
                                                : LnuColors.amberDeep,
                                          ),
                                        ),
                                ),
                              ],
                            ),
                            if (!probingTimes &&
                                probedWindows.isNotEmpty) ...<Widget>[
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 6,
                                children: <Widget>[
                                  for (var i = 0; i < probedWindows.length; i++)
                                    GestureDetector(
                                      onTap: () {
                                        setSheetState(() {
                                          selectedWindowIndex = i;
                                          selectedStart =
                                              probedWindows[i].startParam;
                                          selectedEnd =
                                              probedWindows[i].endParam;
                                        });
                                      },
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 5,
                                        ),
                                        decoration: BoxDecoration(
                                          color: i == selectedWindowIndex
                                              ? LnuColors.amberDeep
                                              : LnuColors.card,
                                          borderRadius:
                                              BorderRadius.circular(14),
                                          border: Border.all(
                                            color: i == selectedWindowIndex
                                                ? LnuColors.amberDeep
                                                : LnuColors.amber,
                                            width: 1.1,
                                          ),
                                        ),
                                        child: Text(
                                          probedWindows[i].label,
                                          style: LnuTheme.mono(
                                            11.5,
                                            weight: FontWeight.w700,
                                            color: i == selectedWindowIndex
                                                ? Colors.white
                                                : LnuColors.amberDeep,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                            const SizedBox(height: 10),
                            Row(
                              children: <Widget>[
                                LnuOutlineButton(
                                  label: '存入首选',
                                  onPressed: () {
                                    ctrl.config.addPreferSeat(
                                      _selectedCampus,
                                      roomName,
                                      pickedSeat!.seatNo,
                                    );
                                    final normNo =
                                        normalizeSeatNo(pickedSeat!.seatNo);
                                    final rank =
                                        ctrl.config.preferSeats.indexOf(normNo) +
                                            1;
                                    ScaffoldMessenger.of(ctx).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          rank > 0
                                              ? '已将 $roomName ${pickedSeat!.seatNo} 号设为明日首选第 $rank 顺位'
                                              : '已将 $roomName ${pickedSeat!.seatNo} 号加入明日首选座',
                                        ),
                                      ),
                                    );
                                  },
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: LnuAmberButton(
                                    label: probingTimes
                                        ? '探测中...'
                                        : (probedWindows.isEmpty &&
                                                probeError.isEmpty)
                                            ? '今日已约满'
                                            : '约 下 ${pickedSeat!.seatNo} 号  →',
                                    onPressed: probingTimes ||
                                            (probedWindows.isEmpty &&
                                                probeError.isEmpty)
                                        ? null
                                        : () {
                                            final chosenNo = pickedSeat!.seatNo;
                                            Navigator.of(sheetCtx).pop();
                                            widget.onJumpToHomeRush();
                                            ctrl.quickBookSingleSeat(
                                              campusName: _selectedCampus,
                                              roomName: roomName,
                                              seatNo: chosenNo,
                                              overrideStart: selectedStart,
                                              overrideEnd: selectedEnd,
                                            );
                                          },
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _gridFilterChip(String text, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? LnuColors.ink : LnuColors.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? LnuColors.ink : LnuColors.border,
          ),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: selected ? Colors.white : LnuColors.textMuted,
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Future<void> _openSeatTagDialog(
    BuildContext context,
    String roomName,
    String seatNo,
  ) async {
    final cfg = widget.controller.config;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (_, setDlg) {
          final current = cfg.tagsForSeat(roomName, seatNo);
          return AlertDialog(
            backgroundColor: LnuColors.card,
            title: Text(
              '$roomName · $seatNo 号座笔记',
              style: LnuTheme.serif(16),
            ),
            content: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: MobileConfigStore.availableSeatTags.map((tag) {
                final has = current.contains(tag);
                return FilterChip(
                  label: Text(tag),
                  selected: has,
                  selectedColor: LnuColors.amberGlow,
                  onSelected: (_) async {
                    await cfg.toggleSeatTag(roomName, seatNo, tag);
                    setDlg(() {});
                  },
                );
              }).toList(),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('完成'),
              ),
            ],
          );
        },
      ),
    );
  }
}
