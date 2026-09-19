import 'dart:async';
import 'package:flutter/material.dart';
import 'brand_assets.dart';
import 'screens/garage_screen.dart';
import 'screens/estimates_screen.dart';
import 'screens/estibot_screen.dart';
import 'screens/repairs_screen.dart';
import 'screens/find_help_screen.dart';
import 'navigation/route_observer.dart';
import 'screens/settings_screen.dart';
import 'state/plus_controller.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'widgets/customer_navigation.dart';
import 'widgets/pending_capture_notice.dart';

class EstimotoPlusApp extends StatelessWidget {
  const EstimotoPlusApp({
    super.key,
    required this.controller,
    this.onExit,
    this.onAccountDeleted,
  });
  final PlusController controller;
  final VoidCallback? onExit;
  final VoidCallback? onAccountDeleted;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Estimoto +',
    debugShowCheckedModeBanner: false,
    theme: plusTheme(),
    navigatorObservers: [plusRouteObserver],
    home: _HomeShell(
      controller: controller,
      onExit: onExit,
      onAccountDeleted: onAccountDeleted,
    ),
  );
}

class _HomeShell extends StatefulWidget {
  const _HomeShell({
    required this.controller,
    this.onExit,
    this.onAccountDeleted,
  });
  final PlusController controller;
  final VoidCallback? onExit;
  final VoidCallback? onAccountDeleted;
  @override
  State<_HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<_HomeShell> with WidgetsBindingObserver {
  Timer? _updates;
  bool _foreground = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _updates = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _refreshStatus(),
    );
    if (widget.controller.snapshot == null) widget.controller.refresh();
  }

  void _refreshStatus() {
    if (_foreground &&
        !widget.controller.isDemo &&
        !widget.controller.loading) {
      widget.controller.refresh(quiet: true);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) _refreshStatus();
  }

  @override
  void dispose() {
    _updates?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      return Scaffold(
        extendBody: true,
        appBar: AppBar(
          toolbarHeight: 62,
          titleSpacing: 20,
          title: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.asset(
                  plusIconAsset,
                  width: 32,
                  height: 32,
                  excludeFromSemantics: true,
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Estimoto +',
                    style: TextStyle(
                      fontSize: 22,
                      letterSpacing: -.65,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Refresh',
              onPressed: c.loading ? null : c.refresh,
              icon: const Icon(Icons.refresh, size: 22),
            ),
            PopupMenuButton<String>(
              tooltip: 'Account options',
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'settings', child: Text('Settings')),
                if (widget.onExit != null)
                  PopupMenuItem(
                    value: 'exit',
                    child: Text(c.isDemo ? 'Leave demo' : 'Sign out'),
                  ),
              ],
              onSelected: (value) => value == 'settings'
                  ? SettingsScreen.open(
                      context,
                      c,
                      onExit: widget.onExit,
                      onAccountDeleted: widget.onAccountDeleted,
                    )
                  : widget.onExit?.call(),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              if (c.isDemo)
                Container(
                  width: double.infinity,
                  color: const Color(0xFFE5F0F7),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 7,
                  ),
                  child: const Text(
                    'Demo · sample data, no real requests',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: PlusColors.navy,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              if (c.loading && c.snapshot != null)
                const LinearProgressIndicator(minHeight: 2),
              if (c.snapshot != null)
                PendingCaptureNotice(
                  key: ValueKey(c.snapshot!.profile.id),
                  controller: c,
                ),
              if (c.error != null && c.snapshot != null)
                MaterialBanner(
                  content: Text(c.error!),
                  actions: [
                    TextButton(
                      onPressed: c.loading ? null : c.refresh,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              Expanded(
                child: c.snapshot == null
                    ? Center(
                        child: c.loading
                            ? const CircularProgressIndicator()
                            : Padding(
                                padding: const EdgeInsets.all(24),
                                child: EmptyState(
                                  icon: Icons.cloud_off_outlined,
                                  title: 'Let’s reconnect',
                                  message:
                                      c.error ??
                                      'Your account is not available yet.',
                                  action: 'Try again',
                                  onAction: c.refresh,
                                ),
                              ),
                      )
                    : IndexedStack(
                        index: c.tab,
                        children: [
                          GarageScreen(
                            controller: c,
                            onExit: widget.onExit,
                            onAccountDeleted: widget.onAccountDeleted,
                          ),
                          EstimatesScreen(controller: c),
                          EstibotScreen(controller: c),
                          RepairsScreen(controller: c),
                          FindHelpScreen(controller: c),
                        ],
                      ),
              ),
            ],
          ),
        ),
        floatingActionButtonLocation: const InsetEstibotLocation(),
        floatingActionButton: MediaQuery.viewInsetsOf(context).bottom > 0
            ? null
            : EstibotNavigationButton(
                selected: c.tab == 2,
                onPressed: () => c.selectTab(2),
              ),
        bottomNavigationBar: CustomerNavigation(controller: c),
      );
    },
  );
}
