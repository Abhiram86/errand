import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/chat_screen.dart';
import 'screens/manage_tasks_screen.dart';
import 'services/app_settings.dart';
import 'services/task_scheduler_service.dart';
import 'services/task_toast_service.dart';
import 'theme/app_colors.dart';

export 'agent/system_prompt.dart' show systemPromptFor, kSystemPrompt;
export 'screens/chat_screen.dart' show ChatScreen;

final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();
final GlobalKey<ScaffoldMessengerState> rootScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );
  await AppSettingsService.instance.ensureLoaded();
  TaskSchedulerService.instance.initialize();
  TaskSchedulerService.instance.rescheduleAllActiveTasks();
  runApp(const ErrandApp());
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
  const ErrandApp({super.key});

  @override
  State<ErrandApp> createState() => _ErrandAppState();
}

class _ErrandAppState extends State<ErrandApp> {
  StreamSubscription? _notifSub;
  StreamSubscription? _toastSub;

  @override
  void initState() {
    super.initState();
    _handleNotificationRouting();
    _handleTaskToasts();
  }

  void _handleNotificationRouting() {
    // 1. Check cold launch pending notification click
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final pending = await TaskSchedulerService.instance.getPendingNotificationClick();
      if (pending != null && mounted) {
        _navigateToUnreadTasks();
      }
    });

    // 2. Listen to live notification click events while app is running
    _notifSub = TaskSchedulerService.instance.notificationClicks.listen((_) {
      if (mounted) {
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
    appNavigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) => const ManageTasksScreen(initialTabIndex: 1),
      ),
    );
  }

  @override
  void dispose() {
    _notifSub?.cancel();
    _toastSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: rootScaffoldMessengerKey,
      title: 'Errand',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kDarkBg,
        colorScheme: const ColorScheme.dark(
          primary: kBubbleUser,
          surface: kDarkBg,
        ),
        useMaterial3: true,
      ),
      home: const ChatScreen(),
    );
  }
}
