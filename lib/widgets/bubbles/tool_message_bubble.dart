import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../services/installed_apps_service.dart';
import '../../theme/app_colors.dart';
import '../../tools/intent_tool.dart';
import '../../types/message.dart';
import 'bubble_utils.dart';
import 'reopen_button.dart';

class ToolMessageBubble extends StatefulWidget {
  final ToolMessage message;

  /// Test-only hook to simulate release or debug mode behavior.
  /// If null, [kDebugMode] is used.
  @visibleForTesting
  static bool? debugShowToolArgsOverride;

  const ToolMessageBubble({super.key, required this.message});

  /// Maps tool names and arguments into concise, human-friendly summaries.
  static String friendlyToolSummary(
    String toolName,
    Map<String, dynamic> args,
  ) {
    switch (toolName) {
      case 'websearch':
        return 'Used web search';
      case 'webfetch':
        return 'Fetched web page';
      case 'read':
        return 'Read file';
      case 'memory':
      case 'memory.find':
      case 'memory_find':
      case 'memory.read':
      case 'memory_read':
      case 'memory.create':
      case 'memory_create':
      case 'memory.edit':
      case 'memory_edit':
        final rawAction = args['action']?.toString();
        final action = (rawAction != null && rawAction.isNotEmpty)
            ? rawAction
            : (toolName.contains('find')
                ? 'find'
                : (toolName.contains('read')
                    ? 'read'
                    : (toolName.contains('create')
                        ? 'create'
                        : (toolName.contains('edit') ? 'edit' : ''))));
        switch (action) {
          case 'find':
            return 'Searched memory';
          case 'read':
            return 'Read memory';
          case 'create':
            return 'Saved memory';
          case 'edit':
            return 'Updated memory';
          default:
            return 'Accessed memory';
        }
      case 'browser':
      case 'browser.open':
      case 'browser_open':
      case 'browser.close':
      case 'browser_close':
      case 'browser.reload':
      case 'browser_reload':
      case 'browser.snapshot':
      case 'browser_snapshot':
      case 'browser.extract_text':
      case 'browser_extract_text':
      case 'browser.execute_dom_js':
      case 'browser_execute_dom_js':
      case 'browser.act':
      case 'browser_act':
      case 'browser.screenshot':
      case 'browser_screenshot':
      case 'extract_text':
        final rawAction = args['action']?.toString();
        final action = (rawAction != null && rawAction.isNotEmpty)
            ? rawAction
            : (toolName.contains('open')
                ? 'open'
                : (toolName.contains('close')
                    ? 'close'
                    : (toolName.contains('reload')
                        ? 'reload'
                        : (toolName.contains('snapshot')
                            ? 'snapshot'
                            : (toolName.contains('extract') || toolName.contains('text')
                                ? 'extract_text'
                                : (toolName.contains('execute') || toolName.contains('js')
                                    ? 'execute_dom_js'
                                    : (toolName.contains('act') ||
                                            toolName.contains('click') ||
                                            toolName.contains('type') ||
                                            toolName.contains('scroll')
                                        ? 'act'
                                        : (toolName.contains('screenshot')
                                            ? 'screenshot'
                                            : ''))))))));
        switch (action) {
          case 'open':
            final url = args['url']?.toString();
            return url != null && url.isNotEmpty
                ? 'Opened $url'
                : 'Opened browser';
          case 'close':
            return 'Closed browser';
          case 'reload':
            return 'Reloaded page';
          case 'snapshot':
            final fullDump =
                args['full_dump'] == true || args['fullDump'] == true;
            return fullDump ? 'Dumped page DOM' : 'Inspected web page';
          case 'extract_text':
            return 'Extracted page text';
          case 'execute_dom_js':
            return 'Executed web script';
          case 'act':
            final actAction =
                (args['act_action'] ?? args['interaction'])?.toString();
            if (actAction == 'click' || args['click'] != null) {
              return 'Clicked page element';
            }
            if (actAction == 'type' || args['type'] != null) {
              return 'Typed into page';
            }
            if (actAction == 'select' || args['select'] != null) {
              return 'Selected page option';
            }
            if (actAction == 'get' || args['get'] != null) {
              return 'Inspected element';
            }
            if (actAction == 'scroll' || args['scroll'] != null) {
              return 'Scrolled page';
            }
            return 'Interacted with page';
          case 'screenshot':
            return 'Captured browser viewport';
          default:
            return 'Used browser';
        }
      case 'workspace':
        final action = args['action']?.toString();
        switch (action) {
          case 'find':
            return 'Searched files';
          case 'list':
            return 'Listed files';
          case 'cd':
            return 'Changed folder';
          case 'pwd':
            return 'Checked current folder';
          default:
            return 'Browsed files';
        }
      case 'screen':
        final action = args['action']?.toString();
        switch (action) {
          case 'screenshot':
            return 'Captured screenshot';
          case 'global':
            final name = args['name']?.toString();
            switch (name) {
              case 'back':
                return 'Pressed back';
              case 'home':
                return 'Pressed home';
              case 'recents':
                return 'Opened recents';
              case 'notifications':
                return 'Opened notifications';
              default:
                return 'Navigated system';
            }
          case 'read':
          default:
            return 'Inspected screen';
        }
      case 'screen_act':
      case 'act':
        final action = args['action']?.toString();
        switch (action) {
          case 'tap':
            return 'Tapped on screen';
          case 'type':
            return 'Typed text';
          case 'scroll':
            return 'Scrolled screen';
          case 'fill':
            return 'Filled input field';
          case 'tab':
            return 'Navigated next field';
          case 'long_press':
            return 'Long pressed on screen';
          case 'esc':
            return 'Pressed escape';
          default:
            return 'Interacted with screen';
        }
      case 'intent':
        final action = args['action']?.toString();
        switch (action) {
          case 'docs':
            final name = args['name']?.toString().trim();
            if (name != null && name.isNotEmpty) {
              return 'Checked $name intent docs';
            }
            return 'Checked intent docs';
          case 'open_app':
            final pkg = args['package']?.toString();
            if (pkg != null && pkg.isNotEmpty) {
              final label = InstalledAppsService.instance.getLabel(pkg);
              return 'Opened $label';
            }
            return 'Opened app';
          case 'open_url':
            return 'Opened web link';
          case 'open_file':
            return 'Opened file';
          case 'settings':
          case 'settings_panel':
            return 'Opened settings';
          case 'search':
            return 'Searched web';
          case 'dial':
            return 'Opened dialer';
          case 'open_maps':
            return 'Opened maps';
          case 'email':
            return 'Drafted email';
          case 'calendar_event':
            return 'Created calendar event';
          case 'media_play':
            return 'Played media';
          case 'share':
            return 'Shared content';
          case 'wallpaper':
            return 'Set wallpaper';
          case 'uninstall':
            return 'Triggered uninstall';
          case 'intent':
            return 'Sent intent';
          default:
            return 'Launched intent';
        }
      case 'attached_files':
        return 'Read attached files';
      case 'bash':
        final cmd = args['command']?.toString().trim();
        if (cmd == null || cmd.isEmpty) return 'Ran task';
        final lower = cmd.toLowerCase();
        final firstWord = lower.split(RegExp(r'\s+')).first;
        switch (firstWord) {
          case 'ls':
            return 'Listed files';
          case 'find':
            return 'Searched files';
          case 'grep':
            return 'Searched in files';
          case 'cat':
          case 'head':
          case 'tail':
          case 'more':
          case 'less':
            return 'Inspected file';
          case 'mkdir':
            return 'Created folder';
          case 'cp':
            return 'Copied files';
          case 'mv':
            return 'Moved files';
          case 'rm':
          case 'rmdir':
            return 'Deleted files';
          case 'df':
          case 'du':
            return 'Checked storage';
          case 'tar':
          case 'gzip':
          case 'gunzip':
          case 'zip':
          case 'unzip':
            return 'Processed archive';
          case 'cd':
            return 'Changed folder';
          case 'pwd':
            return 'Checked current folder';
          case 'touch':
            return 'Created file';
          case 'echo':
          case 'printf':
            if (cmd.contains('>') || cmd.contains('>>')) {
              return 'Wrote to file';
            }
            return 'Ran task';
          case 'ps':
            return 'Checked processes';
          default:
            return 'Ran task';
        }
      default:
        final formattedName = toolName
            .replaceAll('_', ' ')
            .replaceAll('-', ' ')
            .trim();
        if (formattedName.isEmpty) return 'Used tool';
        return 'Used $formattedName';
    }
  }

  /// Maps tool names and actions to appropriate visual icons.
  static IconData toolIcon(String toolName, Map<String, dynamic> args) {
    switch (toolName) {
      case 'bash':
        return Icons.terminal_rounded;
      case 'websearch':
        return Icons.search_rounded;
      case 'webfetch':
        return Icons.travel_explore_rounded;
      case 'read':
        return Icons.description_outlined;
      case 'workspace':
        return Icons.folder_open_outlined;
      case 'screen':
        final action = args['action']?.toString();
        if (action == 'screenshot') {
          return Icons.camera_alt_outlined;
        }
        return Icons.screenshot_monitor_rounded;
      case 'screen_act':
      case 'act':
        final action = args['action']?.toString();
        if (action == 'type' || action == 'fill') {
          return Icons.keyboard_outlined;
        }
        if (action == 'scroll') {
          return Icons.swipe_outlined;
        }
        return Icons.touch_app_outlined;
      case 'intent':
        final action = args['action']?.toString();
        if (action == 'docs') {
          return Icons.menu_book_outlined;
        }
        return Icons.open_in_new_rounded;
      case 'attached_files':
        return Icons.attach_file_rounded;
      default:
        return Icons.build_outlined;
    }
  }

  @override
  State<ToolMessageBubble> createState() => _ToolMessageBubbleState();
}

class _ToolMessageBubbleState extends State<ToolMessageBubble> {
  bool _isExpanded = false;
  final _controller = ExpansibleController();

  void _collapse() {
    if (_controller.isExpanded) {
      _controller.collapse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final args = formatToolArgs(message.tool.args);
    final outputWasTruncated = message.result.length > kMaxToolOutputChars;
    final output = truncateForDisplay(message.result, kMaxToolOutputChars);

    final isDebug = (ToolMessageBubble.debugShowToolArgsOverride ?? kDebugMode);
    final showRawArgs = isDebug || _isExpanded;

    final headerText = showRawArgs
        ? '${truncateForDisplay(message.tool.name, 32)} '
              '${truncateForDisplay(args, kMaxToolHeaderChars)}'
        : ToolMessageBubble.friendlyToolSummary(
            message.tool.name,
            message.tool.args,
          );

    final copyText = isDebug
        ? formatToolCallDebugCopy(message)
        : message.result;
    final copyTooltip = isDebug ? 'Copy tool call & output' : 'Copy output';

    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.86,
        ),
        child: Theme(
          data: Theme.of(context).copyWith(
            dividerColor: Colors.transparent,
            splashColor: Colors.transparent,
            highlightColor: Colors.transparent,
            iconTheme: Theme.of(context).iconTheme
                .copyWith(color: kMuted.withValues(alpha: 0.45), size: 16),
          ),
          child: ExpansionTile(
            controller: _controller,
            onExpansionChanged: (expanded) {
              if (_isExpanded != expanded) {
                setState(() => _isExpanded = expanded);
              }
            },
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            collapsedIconColor: kMuted.withValues(alpha: 0.45),
            iconColor: kMuted.withValues(alpha: 0.45),
            dense: true,
            visualDensity: VisualDensity.compact,
            minTileHeight: 24,
            title: Row(
              children: [
                Icon(
                  ToolMessageBubble.toolIcon(
                    message.tool.name,
                    message.tool.args,
                  ),
                  size: 14,
                  color: kMuted.withValues(alpha: 0.7),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    headerText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: kMuted, fontSize: 12),
                  ),
                ),
                // Reopen button for launch-style intent actions (open_url,
                // open_app, ...): re-fires the same persisted args.
                if (isReopenable(message)) ReopenButton(message: message),
              ],
            ),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _collapse,
                        child: SelectableText(
                          outputWasTruncated
                              ? '$output\n\n[output truncated for display]'
                              : output,
                          onTap: _collapse,
                          style: const TextStyle(
                            color: kMuted,
                            fontSize: 11,
                            height: 1.3,
                          ),
                        ),
                      ),
                    ),
                    // Copies the full result (or total tool call in debug mode).
                    CopyButton(text: copyText, tooltip: copyTooltip),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
