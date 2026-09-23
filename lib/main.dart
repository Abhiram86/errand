import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/chat_screen.dart';
import 'screens/manage_tasks_screen.dart';
import 'services/app_settings.dart';
import 'services/task_scheduler_service.dart';
import 'services/task_toast_service.dart';
import 'theme/app_colors.dart';
import 'utils/p10_profile.dart';
import 'widgets/unread_task_banner.dart';

export 'agent/system_prompt.dart' show systemPromptFor, kSystemPrompt;
export 'screens/chat_screen.dart' show ChatScreen;

final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();
final GlobalKey<ScaffoldMessengerState> rootScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

Future<void> main() async {
  P10Profile.start();
  P10Profile.mark('main_entry');
  WidgetsFlutterBinding.ensureInitialized();
  final platformInitialRoute =
      WidgetsBinding.instance.platformDispatcher.defaultRouteName;
  final initialRoute = platformInitialRoute.isEmpty
      ? '/'
      : platformInitialRoute;
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );
  TaskSchedulerService.instance.initialize();
  runApp(ErrandApp(initialRoute: initialRoute));
  WidgetsBinding.instance.addPostFrameCallback((_) {
    P10Profile.mark('first_frame');
    // Settings loading is also requested by ChatScreen during initialization.
    // The service deduplicates that request with this deferred bootstrap call.
    unawaited(_finishDeferredStartup());
  });
}

/// Runs startup work after Flutter has had a chance to paint the first frame.
/// Notification navigation and the initial screen therefore do not wait for
/// secrets or provider metadata. Alarm restoration is owned by the native
/// boot/package-update receiver instead of running on every app launch.
Future<void> _finishDeferredStartup() async {
  try {
    await AppSettingsService.instance.ensureLoaded();
  } catch (error, stackTrace) {
    debugPrint('[Startup] Settings load failed: $error\n$stackTrace');
  }
}

/// Dedicated headless background entrypoint for Android AlarmManager triggers.
///
/// Executes in an isolated background FlutterEngine without constructing UI widgets.
@pragma('vm:entry-point')
void backgroundTaskMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppSettingsService.instance.ensureLoaded();
  TaskSchedulerService.instance.initialize();
  try {
    await const MethodChannel('task_scheduler').invokeMethod('onEngineReady');
  } catch (_) {}
}

class ErrandApp extends StatefulWidget {
  final String initialRoute;

  const ErrandApp({super.key, required this.initialRoute});

  @override
  State<ErrandApp> createState() => _ErrandAppState();
}

class _ErrandAppState extends State<ErrandApp> {
  StreamSubscription? _notifSub;
  StreamSubscription? _toastSub;
  late bool _initialUnreadRouteActive;
  late final bool _openedOnUnreadRoute;
  int? _initialNotificationTaskId;
  bool _notificationRouteOpened = false;
  int _startupUnreadCount = 0;
  bool _showStartupUnreadBanner = false;

  @override
  void initState() {
    super.initState();
    _openedOnUnreadRoute =
        _routeName(widget.initialRoute) == _manageTasksUnreadRoute;
    _initialUnreadRouteActive = _openedOnUnreadRoute;
    _initialNotificationTaskId = _taskIdFromRoute(widget.initialRoute);
    _handleNotificationRouting();
    _handleTaskToasts();
    _scheduleUnreadTaskBanner();
  }

  void _scheduleUnreadTaskBanner() {
    // Let the first screen paint before touching the database or banner.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 900), () async {
          if (!mounted || _openedOnUnreadRoute || _notificationRouteOpened) {
            return;
          }

          try {
            final count = await TaskSchedulerService.instance
                .unreadNotificationCount();
            if (!mounted || count == 0) return;
            setState(() {
              _startupUnreadCount = count;
              _showStartupUnreadBanner = true;
            });
          } catch (_) {
            // Startup reminders are best-effort and must never delay app use.
          }
        }),
      );
    });
  }

  void _handleNotificationRouting() {
    // 1. Check cold launch pending notification click
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      P10Profile.mark('cold_pending_lookup_start');
      final pending = await TaskSchedulerService.instance
          .getPendingNotificationClick();
      P10Profile.mark('cold_pending_lookup_done found=${pending != null}');
      if (_initialUnreadRouteActive) {
        _initialUnreadRouteActive = false;
        return;
      }
      if (pending != null && mounted) {
        _navigateToUnreadTasks();
      }
    });

    // 2. Listen to live notification click events while app is running
    _notifSub = TaskSchedulerService.instance.notificationClicks.listen((args) {
      if (mounted) {
        final taskId = (args['taskId'] as num?)?.toInt();
        if (_initialUnreadRouteActive) {
          if (_initialNotificationTaskId == null ||
              taskId == _initialNotificationTaskId) {
            return;
          }
          _initialUnreadRouteActive = false;
        }
        P10Profile.mark('live_tap_received');
        _navigateToUnreadTasks();
      }
    });
  }

  void _handleTaskToasts() {
    _toastSub = TaskToastService.instance.stream.listen((event) {
      if (!mounted) return;
      final messenger = rootScaffoldMessengerKey.currentState;
      if (messenger == null) return;

      IconData icon;
      Color bgColor = kBubbleUser;
      switch (event.type) {
        case TaskToastType.create:
          icon = Icons.schedule_rounded;
          break;
        case TaskToastType.edit:
          icon = Icons.tune_rounded;
          break;
        case TaskToastType.delete:
          icon = Icons.delete_outline_rounded;
          bgColor = const Color(0xFF333333);
          break;
      }

      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(icon, size: 18, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    event.message,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
            backgroundColor: bgColor,
            duration: const Duration(seconds: 4),
            behavior: SnackBarBehavior.floating,
            action: event.type != TaskToastType.delete
                ? SnackBarAction(
                    label: 'View',
                    textColor: Colors.white,
                    onPressed: () {
                      appNavigatorKey.currentState?.push(
                        MaterialPageRoute(
                          builder: (_) => const ManageTasksScreen(),
                        ),
                      );
                    },
                  )
                : null,
          ),
        );
    });
  }

  void _navigateToUnreadTasks() {
    _notificationRouteOpened = true;
    if (mounted) {
      setState(() => _showStartupUnreadBanner = false);
    }
    rootScaffoldMessengerKey.currentState?.hideCurrentSnackBar();
    P10Profile.mark('unread_route_push');
    appNavigatorKey.currentState?.push(
      PageRouteBuilder(
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, _, _) => const ManageTasksScreen(initialTabIndex: 1),
      ),
    );
  }

  static const _manageTasksUnreadRoute = '/manage_tasks_unread';

  String _routeName(String route) => route.split('?').first;

  int? _taskIdFromRoute(String route) {
    final uri = Uri.tryParse(route);
    if (uri == null || _routeName(route) != _manageTasksUnreadRoute) {
      return null;
    }
    return int.tryParse(uri.queryParameters['taskId'] ?? '');
  }

  @override
  void dispose() {
    _notifSub?.cancel();
    _toastSub?.cancel();
    super.dispose();
  }

  void _dismissStartupUnreadBanner() {
    if (!mounted) return;
    setState(() => _showStartupUnreadBanner = false);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: rootScaffoldMessengerKey,
      title: 'Errand',
      debugShowCheckedModeBanner: false,
      builder: (context, child) => Stack(
        fit: StackFit.expand,
        children: [
          child ?? const SizedBox.shrink(),
          if (_showStartupUnreadBanner)
            UnreadTaskBanner(
              count: _startupUnreadCount,
              onView: _navigateToUnreadTasks,
              onDismiss: _dismissStartupUnreadBanner,
            ),
        ],
      ),
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kDarkBg,
        colorScheme: const ColorScheme.dark(
          primary: kBubbleUser,
          surface: kDarkBg,
        ),
        useMaterial3: true,
      ),
      initialRoute: widget.initialRoute,
      onGenerateRoute: (settings) {
        if (_routeName(settings.name ?? '/') == _manageTasksUnreadRoute) {
          return MaterialPageRoute(
            settings: settings,
            builder: (_) => const ManageTasksScreen(initialTabIndex: 1),
          );
        }
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => const ChatScreen(),
        );
      },
    );
  }
}
