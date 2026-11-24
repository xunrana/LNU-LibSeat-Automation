import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lnu_libseat_mobile/core/libseat_client.dart';
import 'package:lnu_libseat_mobile/logic/orchestrator.dart';
import 'package:lnu_libseat_mobile/main.dart';
import 'package:lnu_libseat_mobile/services/config_store.dart';
import 'package:lnu_libseat_mobile/services/rush_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('LNU LibSeat 辽大特色四频道主界面渲染冒烟测试', (WidgetTester tester) async {
    final store = MobileConfigStore();
    final controller = MobileRushController(config: store);

    await tester.pumpWidget(LnuLibSeatMobileApp(controller: controller));
    expect(find.text('LNU LibSeat'), findsOneWidget);
    expect(find.text('晨约'), findsOneWidget);
    expect(find.text('寻座'), findsOneWidget);
    expect(find.text('入馆'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);

    // 点击已选中的「定时 06:30」打开 24 小时制双滚轮时间选择器（无 AM/PM 钟盘）
    store.scheduledMode = true;
    await tester.pump();
    final schedChip = find.text('定时 06:30');
    await tester.ensureVisible(schedChip);
    await tester.tap(schedChip);
    await tester.pumpAndSettle();

    expect(find.text('选择定时时间 (24小时制)'), findsOneWidget);
    expect(find.text('AM'), findsNothing);
    expect(find.text('PM'), findsNothing);
    expect(find.text('确定'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('选择定时时间 (24小时制)'), findsNothing);

    // 确保无未处理异常
    expect(tester.takeException(), isNull);
  });

  testWidgets('双账号模式下速改弹窗可分别调整主号与副号时段', (WidgetTester tester) async {
    final store = MobileConfigStore()
      ..useAccount2 = true
      ..start1 = '20:00'
      ..end1 = '21:00'
      ..start2 = '21:00'
      ..end2 = '22:00';
    final controller = MobileRushController(config: store);

    await tester.pumpWidget(LnuLibSeatMobileApp(controller: controller));
    await tester.pump();

    final quickEdit = find.text('速改');
    await tester.ensureVisible(quickEdit);
    await tester.tap(quickEdit);
    await tester.pumpAndSettle();

    expect(find.text('主号 20:00–21:00'), findsOneWidget);
    expect(find.text('副号 21:00–22:00'), findsOneWidget);

    await tester.tap(find.text('副号 21:00–22:00'));
    await tester.pumpAndSettle();
    expect(find.text('常用自习时段（当前修改：副账号）'), findsOneWidget);

    final slotChip = find.text('午晚连堂 (15:00–21:00)');
    await tester.ensureVisible(slotChip);
    await tester.tap(slotChip);
    await tester.pumpAndSettle();

    final saveBtn = find.text('保  存  调  整');
    await tester.ensureVisible(saveBtn);
    await tester.tap(saveBtn);
    await tester.pumpAndSettle();

    expect(store.start1, equals('20:00'));
    expect(store.end1, equals('21:00'));
    expect(store.start2, equals('15:00'));
    expect(store.end2, equals('21:00'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('首页预约成功条与入馆双账号自习书简均支持直接取消预约', (WidgetTester tester) async {
    final store = MobileConfigStore()
      ..account1 = '20250000001'
      ..account2 = '20250000002'
      ..useAccount2 = true;
    final controller = MobileRushController(config: store);
    controller.recentSuccessEvents.addAll(const <BookingSuccessEvent>[
      BookingSuccessEvent(
        account: '20250000001',
        roomName: '三楼智慧研修空间',
        seatNo: '15',
        startTime: '20:00',
        endTime: '21:00',
        reservationId: '9000001',
        receipt: '0001-321',
      ),
      BookingSuccessEvent(
        account: '20250000002',
        roomName: '三楼智慧研修空间',
        seatNo: '15',
        startTime: '21:00',
        endTime: '22:00',
        reservationId: '9000002',
        receipt: '0002-322',
      ),
    ]);
    controller.historyRecords = const <HistoryRecord>[
      HistoryRecord(
        id: '9000001',
        date: '2026-11-21',
        begin: '20:00',
        end: '21:00',
        location: '崇山校区图书馆3层三楼智慧研修空间15号',
        stat: 'RESERVE',
        account: '20250000001',
      ),
      HistoryRecord(
        id: '9000002',
        date: '2026-11-21',
        begin: '21:00',
        end: '22:00',
        location: '崇山校区图书馆3层三楼智慧研修空间15号',
        stat: 'RESERVE',
        account: '20250000002',
      ),
    ];

    await tester.pumpWidget(LnuLibSeatMobileApp(controller: controller));
    await tester.pump();

    // 首页双号预约成功条各自带「取消预约」按钮
    expect(find.text('取消预约'), findsNWidgets(2));

    // 切到「入馆」页，验证双账号切换条与辽大自习书简双号合辑
    await tester.tap(find.text('入馆'));
    await tester.pumpAndSettle();

    expect(find.text('全部合并'), findsOneWidget);
    expect(find.text('主号 · 0001'), findsOneWidget);
    expect(find.text('副号 · 0002'), findsOneWidget);

    // 向下滚动露出底部的「辽大自习书简」卡片
    await tester.scrollUntilVisible(
      find.text('双号合辑'),
      250,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('双号合辑'), findsOneWidget);

    // 点开「辽大自习书简」查看历史明细，确认 RESERVE 条目自带取消预约按钮
    final studyLetter = find.text('查看足迹 ›');
    await tester.ensureVisible(studyLetter);
    await tester.tap(studyLetter);
    await tester.pumpAndSettle();

    expect(find.text('历史预约明细（2 条）'), findsOneWidget);
    expect(find.text('取消预约'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('入馆座签展示真实签到提醒时刻并支持点击开关', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final store = MobileConfigStore()..autoCheckinReminder = true;
    final controller = MobileRushController(config: store);
    final tomorrow = DateTime.now().toUtc().add(const Duration(days: 1, hours: 8));
    String pad2(int n) => n.toString().padLeft(2, '0');
    final dateStr =
        '${tomorrow.year}-${pad2(tomorrow.month)}-${pad2(tomorrow.day)}';

    controller.activeReservations = <ReservationRecord>[
      ReservationRecord(
        reservationId: '9000001',
        receipt: '0001-321',
        onDate: dateStr,
        seatId: '17293',
        status: 'RESERVE',
        location: '崇山校区图书馆3层三楼智慧研修空间，座位号15',
        begin: '14:00',
        end: '20:00',
        account: '20250000001',
      ),
    ];

    await tester.pumpWidget(LnuLibSeatMobileApp(controller: controller));
    await tester.tap(find.text('入馆'));
    await tester.pumpAndSettle();

    expect(find.text('提醒 13:45 / 14:20'), findsOneWidget);
    await tester.tap(find.text('提醒 13:45 / 14:20'));
    await tester.pumpAndSettle();

    expect(store.autoCheckinReminder, isFalse);
    expect(find.text('签到提醒已关 · 点此开启'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('首选座位按点击先后展示角标顺位与顶部顺位条并支持点击移除重排 (Issue #9)', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final store = MobileConfigStore();
    final controller = MobileRushController(config: store);

    await tester.pumpWidget(LnuLibSeatMobileApp(controller: controller));
    await tester.pump();

    final quickEdit = find.text('速改');
    await tester.ensureVisible(quickEdit);
    await tester.tap(quickEdit);
    await tester.pumpAndSettle();

    // 未选时显示点击顺序提示文案
    expect(
      find.text('按点击先后顺序依次尝试（1 → 2 → 3…），留空则抢全室实时空座'),
      findsOneWidget,
    );

    // 逆序点选 4 -> 2 -> 1，验证角标严格按点击顺位显示 1 / 2 / 3
    for (final seatNo in const <String>['4', '2', '1']) {
      final cell = find.byKey(ValueKey<String>('prefer_seat_cell_$seatNo'));
      await tester.ensureVisible(cell);
      await tester.tap(cell);
      await tester.pumpAndSettle();
    }

    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('prefer_seat_rank_4')),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('prefer_seat_rank_2')),
        matching: find.text('2'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('prefer_seat_rank_1')),
        matching: find.text('3'),
      ),
      findsOneWidget,
    );

    // 从顶部顺位条移除第 2 顺位「2号」，第 3 顺位「1号」自动递补为第 2 顺位
    await tester.tap(find.byKey(const ValueKey<String>('prefer_order_chip_2')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('prefer_seat_rank_2')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('prefer_seat_rank_1')),
        matching: find.text('2'),
      ),
      findsOneWidget,
    );

    final saveBtn = find.text('保  存  调  整');
    await tester.ensureVisible(saveBtn);
    await tester.tap(saveBtn);
    await tester.pumpAndSettle();

    expect(store.preferSeats, equals(<String>['4', '1']));
    expect(find.textContaining('首选 4 → 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
