import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/chat_screen.dart';
import 'services/app_settings.dart';
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
  runApp(const ErrandApp());
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
