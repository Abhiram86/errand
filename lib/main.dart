import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/chat_screen.dart';
import 'services/app_settings.dart';
import 'services/task_scheduler_service.dart';
import 'theme/app_colors.dart';

export 'agent/system_prompt.dart' show systemPromptFor, kSystemPrompt;
export 'screens/chat_screen.dart' show ChatScreen;

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

class ErrandApp extends StatelessWidget {
  const ErrandApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
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
