import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import '../screens/task_file_preview_screen.dart';
import '../services/intent_service.dart';
import '../services/workspace.dart';
import '../widgets/bubbles/bubble_utils.dart';

/// Opens a Markdown link with sandboxed routing shared by chat bubbles and
/// task report previews: http(s) in the external browser, `file://` and bare
/// local paths via the sandboxed file flow. Anything else is ignored, with a
/// toast only when the user tapped something that looked openable.
Future<void> openMarkdownLink(BuildContext context, String url) async {
  final trimmed = url.trim();
  final lower = trimmed.toLowerCase();
  final messenger = ScaffoldMessenger.of(context);
  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    try {
      await IntentService().launchAction('open_url', data: trimmed);
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not open link')),
      );
    }
    return;
  }
  final roots = [
    Workspace.instance.documentsDir.path,
    Workspace.instance.scratchDir.path,
  ];
  // Bare relative paths (e.g. `[x](hello.txt)`) resolve against the roots.
  final candidates = <String>[trimmed];
  if (!trimmed.startsWith('file:') && !trimmed.startsWith('/')) {
    for (final root in roots) {
      candidates.add('file://${path.join(root, trimmed)}');
    }
  }
  String? filePath;
  for (final candidate in candidates) {
    filePath = resolveChatFileLink(candidate, roots);
    if (filePath != null) break;
  }
  if (filePath == null) {
    if (lower.startsWith('file:')) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Cannot open this file link')),
      );
    }
    return;
  }
  try {
    final ext = path.extension(filePath).toLowerCase();
    if (ext == '.md' || ext == '.html' || ext == '.htm') {
      await TaskFilePreviewScreen.show(context, filePath: filePath);
    } else {
      await IntentService().launchAction('open_file', data: filePath);
    }
  } catch (_) {
    messenger.showSnackBar(
      const SnackBar(content: Text('Could not open file')),
    );
  }
}
