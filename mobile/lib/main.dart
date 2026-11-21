/// LNU LibSeat 手机端主入口。
///
/// 辽大书院金石美学 · 晨约 · 寻座 · 入馆 · 我的。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'services/config_store.dart';
import 'services/notification_service.dart';
import 'services/rush_controller.dart';
import 'ui/screens/home_rush_screen.dart';
import 'ui/screens/my_ticket_screen.dart';
import 'ui/screens/seat_radar_screen.dart';
import 'ui/screens/settings_screen.dart';
import 'ui/theme/app_theme.dart';
import 'ui/widgets/lnu_chrome.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: LnuColors.bg,
      statusBarIconBrightness: Brightness.dark,
      systemNavigationBarColor: LnuColors.bgPaper,
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );

  await NotificationService.instance.init();

  final configStore = MobileConfigStore();
  await configStore.init();

  final rushController = MobileRushController(config: configStore);
  unawaited(rushController.warmupModels());
  unawaited(rushController.checkAndResumePendingAlarmRush());

  runApp(LnuLibSeatMobileApp(controller: rushController));
}

class LnuLibSeatMobileApp extends StatelessWidget {
  final MobileRushController controller;

  const LnuLibSeatMobileApp({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LNU LibSeat',
      debugShowCheckedModeBanner: false,
      theme: LnuTheme.buildLightTheme(),
      home: LnuMainShell(controller: controller),
    );
  }
}

class LnuMainShell extends StatefulWidget {
  final MobileRushController controller;

  const LnuMainShell({super.key, required this.controller});

  @override
  State<LnuMainShell> createState() => _LnuMainShellState();
}

class _LnuMainShellState extends State<LnuMainShell> {
  int _currentIndex = 0;

  static const List<LnuBottomNavItem> _navItems = <LnuBottomNavItem>[
    LnuBottomNavItem(
      label: '晨约',
      icon: Icons.wb_twilight_outlined,
      activeIcon: Icons.wb_twilight_rounded,
    ),
    LnuBottomNavItem(
      label: '寻座',
      icon: Icons.explore_outlined,
      activeIcon: Icons.explore_rounded,
    ),
    LnuBottomNavItem(
      label: '入馆',
      icon: Icons.menu_book_outlined,
      activeIcon: Icons.menu_book_rounded,
    ),
    LnuBottomNavItem(
      label: '我的',
      icon: Icons.person_outline_rounded,
      activeIcon: Icons.person_rounded,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final screens = <Widget>[
      HomeRushScreen(
        controller: widget.controller,
        onJumpToPass: () => setState(() => _currentIndex = 2),
      ),
      SeatRadarScreen(
        controller: widget.controller,
        onJumpToHomeRush: () => setState(() => _currentIndex = 0),
      ),
      MyTicketScreen(
        controller: widget.controller,
        onJumpToFindSeat: () => setState(() => _currentIndex = 1),
      ),
      SettingsScreen(controller: widget.controller),
    ];

    return Scaffold(
      backgroundColor: LnuColors.bg,
      body: SafeArea(
        bottom: false,
        child: IndexedStack(
          index: _currentIndex,
          children: screens,
        ),
      ),
      bottomNavigationBar: LnuBottomNav(
        currentIndex: _currentIndex,
        items: _navItems,
        onTap: (idx) {
          setState(() => _currentIndex = idx);
          if (idx == 2 && widget.controller.activeReservations.isEmpty) {
            widget.controller.refreshLibraryPassData();
          }
        },
      ),
    );
  }
}
