import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:path/path.dart' as path;

import '../services/installed_apps_service.dart';
import '../theme/app_colors.dart';
import '../tools/intent_tool.dart';
import '../types/message.dart';

const kMaxToolHeaderChars = 96;
const kMaxToolOutputChars = 4000;

String _truncateForDisplay(String value, int maxChars) {
  if (value.length <= maxChars) return value;
  return '${value.substring(0, maxChars - 1)}…';
}

String _formatToolArgs(Map<String, dynamic> args) {
  try {
    return jsonEncode(args);
  } catch (_) {
    return args.toString();
  }
}

String _formatToolCallDebugCopy(ToolMessage message) {
  String formattedArgs;
  try {
    const encoder = JsonEncoder.withIndent('  ');
    formattedArgs = encoder.convert(message.tool.args);
  } catch (_) {
    formattedArgs = message.tool.args.toString();
  }
  return 'Tool: ${message.tool.name}\nArguments: $formattedArgs\nOutput:\n${message.result}';
}

/// One-tap copy for assistant text and tool output. Free-form selection
/// still comes from the SelectionArea wrapping the message list.
class _CopyButton extends StatelessWidget {
  final String text;
  final String tooltip;

  const _CopyButton({required this.text, this.tooltip = 'Copy'});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: () async {
        await Clipboard.setData(ClipboardData(text: text));
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Copied'),
            duration: Duration(seconds: 1),
            behavior: SnackBarBehavior.floating,
          ),
        );
      },
      tooltip: tooltip,
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
      constraints: const BoxConstraints.tightFor(width: 24, height: 24),
      padding: EdgeInsets.zero,
      iconSize: 14,
      color: kMuted,
      icon: const Icon(Icons.copy_rounded),
    );
  }
}

/// Smooth, subtle entry transition for new messages and tool calls.
/// Glides up by ~4% and fades in over 260ms without causing layout reflow.
class SubtleFadeIn extends StatefulWidget {
  final Widget child;
  final bool animate;
  final Duration duration;

  const SubtleFadeIn({
    super.key,
    required this.child,
    this.animate = true,
    this.duration = const Duration(milliseconds: 260),
  });

  @override
  State<SubtleFadeIn> createState() => _SubtleFadeInState();
}

class _SubtleFadeInState extends State<SubtleFadeIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fadeAnimation;
  late final Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
    final curve = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );
    _fadeAnimation = curve;
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.04),
      end: Offset.zero,
    ).animate(curve);

    if (widget.animate) {
      _controller.forward();
    } else {
      _controller.value = 1.0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.animate) return widget.child;

    return FadeTransition(
      opacity: _fadeAnimation,
      child: SlideTransition(position: _slideAnimation, child: widget.child),
    );
  }
}

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
    final args = _formatToolArgs(message.tool.args);
    final outputWasTruncated = message.result.length > kMaxToolOutputChars;
    final output = _truncateForDisplay(message.result, kMaxToolOutputChars);

    final isDebug = (ToolMessageBubble.debugShowToolArgsOverride ?? kDebugMode);
    final showRawArgs = isDebug || _isExpanded;

    final headerText = showRawArgs
        ? '${_truncateForDisplay(message.tool.name, 32)} '
              '${_truncateForDisplay(args, kMaxToolHeaderChars)}'
        : ToolMessageBubble.friendlyToolSummary(
            message.tool.name,
            message.tool.args,
          );

    final copyText = isDebug
        ? _formatToolCallDebugCopy(message)
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
                if (isReopenable(message)) _ReopenButton(message: message),
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
                    _CopyButton(text: copyText, tooltip: copyTooltip),
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

/// Represents a grouped or single display item for the chat message list.
sealed class ChatDisplayItem {
  final String id;
  const ChatDisplayItem(this.id);
}

/// A standard non-tool chat message (User, Assistant, CompactedNotice, etc.).
class SingleMessageDisplayItem extends ChatDisplayItem {
  final Message message;
  final int originalIndex;
  SingleMessageDisplayItem(this.message, this.originalIndex)
      : super(message.id);
}

/// A group of one or more sequential [ToolMessage]s.
class ToolGroupDisplayItem extends ChatDisplayItem {
  final List<ToolMessage> tools;
  ToolGroupDisplayItem(this.tools) : super('group_${tools.first.id}');
}

/// Groups consecutive [ToolMessage]s in [messages] together for display.
List<ChatDisplayItem> groupMessagesForDisplay(List<Message> messages) {
  final items = <ChatDisplayItem>[];
  List<ToolMessage>? currentTools;

  for (var i = 0; i < messages.length; i++) {
    final message = messages[i];
    if (message is ToolMessage) {
      currentTools ??= [];
      currentTools.add(message);
    } else if (message is AssistantMessage && message.text.trim().isEmpty) {
      // Stray whitespace/empty assistant messages (e.g. from model newline deltas
      // preceding a tool call) must never break consecutive tool grouping.
      continue;
    } else {
      if (currentTools != null) {
        items.add(ToolGroupDisplayItem(currentTools));
        currentTools = null;
      }
      items.add(SingleMessageDisplayItem(message, i));
    }
  }
  if (currentTools != null) {
    items.add(ToolGroupDisplayItem(currentTools));
  }
  return items;
}

/// Renders a sequential group of [ToolMessage]s into a single expandable UI tile.
/// While running (not finished), it displays the active tool's friendly summary (e.g.
/// "Used web search", "Read file", "Executed command") with smooth transitions per call.
/// Once finished, it displays the overall step count ("Ran 1 step" or "Ran X steps").
/// When expanded, each tool call is rendered as its own inner collapsible tile without
/// distracting backgrounds or borders.
class ToolGroupBubble extends StatefulWidget {
  final List<ToolMessage> tools;
  final bool initiallyExpanded;
  final bool isFinished;

  const ToolGroupBubble({
    super.key,
    required this.tools,
    this.initiallyExpanded = false,
    this.isFinished = true,
  });

  @override
  State<ToolGroupBubble> createState() => _ToolGroupBubbleState();
}

class _ToolGroupBubbleState extends State<ToolGroupBubble> {
  bool _isExpanded = false;
  final _controller = ExpansibleController();

  void _collapse() {
    if (_controller.isExpanded) {
      _controller.collapse();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.tools.isEmpty) return const SizedBox.shrink();

    final latestTool = widget.tools.last;
    final isDebug = (ToolMessageBubble.debugShowToolArgsOverride ?? kDebugMode);
    final count = widget.tools.length;

    final String headerText;
    final IconData headerIcon;
    final Key activeKey;

    if (widget.isFinished) {
      headerText = count == 1 ? 'Ran 1 step' : 'Ran $count steps';
      headerIcon = count == 1
          ? ToolMessageBubble.toolIcon(
              latestTool.tool.name,
              latestTool.tool.args,
            )
          : Icons.auto_awesome_rounded;
      activeKey = ValueKey('finished_${widget.tools.length}_${latestTool.id}');
    } else {
      final latestArgs = _formatToolArgs(latestTool.tool.args);
      headerText = isDebug
          ? '${_truncateForDisplay(latestTool.tool.name, 32)} '
                '${_truncateForDisplay(latestArgs, kMaxToolHeaderChars)}'
          : ToolMessageBubble.friendlyToolSummary(
              latestTool.tool.name,
              latestTool.tool.args,
            );
      headerIcon = ToolMessageBubble.toolIcon(
        latestTool.tool.name,
        latestTool.tool.args,
      );
      activeKey = ValueKey('running_${latestTool.id}');
    }

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
            initiallyExpanded: widget.initiallyExpanded,
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
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    layoutBuilder: (currentChild, previousChildren) {
                      return Stack(
                        alignment: Alignment.centerLeft,
                        children: [
                          ...previousChildren,
                          ?currentChild,
                        ],
                      );
                    },
                    transitionBuilder: (child, animation) {
                      final isCurrent = child.key == activeKey;
                      final slide = Tween<Offset>(
                        begin: isCurrent
                            ? const Offset(0.0, 0.45)
                            : const Offset(0.0, -0.45),
                        end: Offset.zero,
                      ).animate(CurvedAnimation(
                        parent: animation,
                        curve: Curves.easeOutCubic,
                      ));
                      return ClipRect(
                        child: SlideTransition(
                          position: slide,
                          child: FadeTransition(
                            opacity: animation,
                            child: child,
                          ),
                        ),
                      );
                    },
                    child: Row(
                      key: activeKey,
                      children: [
                        Icon(
                          headerIcon,
                          size: 14,
                          color: kMuted.withValues(alpha: 0.7),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            headerText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: kMuted,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // For single tools with openable intent, show Open button in the header.
                if (widget.tools.length == 1 && isReopenable(latestTool))
                  _ReopenButton(message: latestTool),
              ],
            ),
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (int i = 0; i < widget.tools.length; i++)
                      _InnerToolTile(
                        key: ValueKey('inner_${widget.tools[i].id}'),
                        message: widget.tools[i],
                        isDebug: isDebug,
                        initiallyExpanded: widget.tools.length == 1,
                        isOnlyTool: widget.tools.length == 1,
                        onCollapseGroup: _collapse,
                      ),
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

/// Collapsible inner tool tile inside a [ToolGroupBubble].
class _InnerToolTile extends StatefulWidget {
  final ToolMessage message;
  final bool isDebug;
  final bool initiallyExpanded;
  final bool isOnlyTool;
  final VoidCallback onCollapseGroup;

  const _InnerToolTile({
    super.key,
    required this.message,
    required this.isDebug,
    this.initiallyExpanded = false,
    this.isOnlyTool = false,
    required this.onCollapseGroup,
  });

  @override
  State<_InnerToolTile> createState() => _InnerToolTileState();
}

class _InnerToolTileState extends State<_InnerToolTile> {
  late bool _isExpanded;

  @override
  void initState() {
    super.initState();
    _isExpanded = widget.initiallyExpanded;
  }

  @override
  void didUpdateWidget(covariant _InnerToolTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initiallyExpanded != widget.initiallyExpanded) {
      _isExpanded = widget.initiallyExpanded;
    }
  }

  void _collapseInner() {
    if (_isExpanded) {
      setState(() => _isExpanded = false);
    }
  }

  void _handleOutputTap() {
    _collapseInner();
    if (widget.isOnlyTool) {
      widget.onCollapseGroup();
    }
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final isDebug = widget.isDebug;
    final args = _formatToolArgs(message.tool.args);
    final outputWasTruncated = message.result.length > kMaxToolOutputChars;
    final output = _truncateForDisplay(message.result, kMaxToolOutputChars);

    final showRawArgs = isDebug;
    final headerText = showRawArgs
        ? '${_truncateForDisplay(message.tool.name, 32)} '
              '${_truncateForDisplay(args, kMaxToolHeaderChars)}'
        : ToolMessageBubble.friendlyToolSummary(
            message.tool.name,
            message.tool.args,
          );

    final copyText = isDebug
        ? _formatToolCallDebugCopy(message)
        : message.result;
    final copyTooltip = isDebug ? 'Copy tool call & output' : 'Copy output';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _isExpanded = !_isExpanded),
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2.5),
            child: Row(
              children: [
                Icon(
                  ToolMessageBubble.toolIcon(
                    message.tool.name,
                    message.tool.args,
                  ),
                  size: 13,
                  color: kMuted.withValues(alpha: 0.7),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    headerText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kMuted,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (isReopenable(message)) ...[
                  const SizedBox(width: 6),
                  _ReopenButton(message: message),
                ],
                const SizedBox(width: 4),
                _CopyButton(text: copyText, tooltip: copyTooltip),
                const SizedBox(width: 2),
                AnimatedRotation(
                  turns: _isExpanded ? 0.25 : 0.0,
                  duration: const Duration(milliseconds: 180),
                  child: Icon(
                    Icons.chevron_right_rounded,
                    size: 15,
                    color: kMuted.withValues(alpha: 0.45),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_isExpanded)
          Padding(
            padding: const EdgeInsets.only(left: 19, top: 2, bottom: 4),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _handleOutputTap,
              child: SelectableText(
                outputWasTruncated
                    ? '$output\n\n[output truncated for display]'
                    : output,
                onTap: _handleOutputTap,
                style: TextStyle(
                  color: kMuted.withValues(alpha: 0.85),
                  fontSize: 10.5,
                  height: 1.3,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _ReopenButton extends StatelessWidget {
  final ToolMessage message;

  const _ReopenButton({required this.message});

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () async {
        final messenger = ScaffoldMessenger.of(context);
        final outcome = await replayIntentAction(message.tool.args);
        if (outcome.startsWith('ERROR')) {
          messenger.showSnackBar(
            SnackBar(
              content: Text(outcome),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      },
      style: TextButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
        minimumSize: const Size(0, 24),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(Icons.open_in_new_rounded, size: 12),
          SizedBox(width: 3),
          Text(
            'Open',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class MessageBubble extends StatelessWidget {
  final Message message;

  /// User bubbles only: load the text into the composer for edit-resend.
  final VoidCallback? onEdit;

  /// Assistant bubbles only: drop the turns after the last user message
  /// and re-run. Only wired for the last message of a completed turn.
  final VoidCallback? onRegenerate;

  const MessageBubble({
    super.key,
    required this.message,
    this.onEdit,
    this.onRegenerate,
  });

  @override
  Widget build(BuildContext context) {
    final isUser = message is UserMessage;

    // Some models emit leading/trailing newlines or fully empty turns;
    // never render an empty bubble for them.
    final text = message.text.trim();
    if (text.isEmpty) return const SizedBox.shrink();

    final isPlaceholder =
        !isUser &&
        (text.startsWith('…working') ||
            text.startsWith('…thinking') ||
            text.startsWith('…compacting'));

    return LayoutBuilder(
      builder: (context, constraints) {
        // availableWidth is the width inside the message list excluding outer paddings/margins.
        final availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : (MediaQuery.of(context).size.width - 32);

        final bubble = Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          constraints: BoxConstraints(
            maxWidth: isUser ? availableWidth * 0.78 : availableWidth * 0.90,
          ),
          decoration: BoxDecoration(
            color: isUser ? kBubbleUser : kBubbleAssistant,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(18),
              topRight: const Radius.circular(18),
              bottomLeft: Radius.circular(isUser ? 18 : 4),
              bottomRight: Radius.circular(isUser ? 4 : 18),
            ),
          ),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOutCubic,
            alignment: isUser ? Alignment.topRight : Alignment.topLeft,
            clipBehavior: Clip.none,
            child: isUser
                ? Text(
                    text,
                    style: const TextStyle(
                      color: kText,
                      fontSize: 15,
                      height: 20 / 15,
                    ),
                  )
                // Assistant turns render as markdown (bold, tables, code,
                // LaTeX). Text selection comes from the SelectionArea that
                // wraps the message list.
                : _StreamingAssistantText(text: text),
          ),
        );

        // User bubbles carry an explicit pen affordance on their left — more
        // discoverable than tap-to-edit and immune to the SelectionArea
        // swallowing taps on desktop/pointer devices.
        if (isUser) {
          final attached = (message is UserMessage)
              ? (message as UserMessage).attachedUris
              : const <String>[];
          final userRow = Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (onEdit != null)
                Padding(
                  padding: const EdgeInsets.only(right: 4, bottom: 2),
                  child: IconButton(
                    onPressed: onEdit,
                    tooltip: 'Edit',
                    style: IconButton.styleFrom(
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                    constraints: const BoxConstraints.tightFor(
                      width: 24,
                      height: 24,
                    ),
                    padding: EdgeInsets.zero,
                    iconSize: 14,
                    color: kMuted.withValues(alpha: 0.8),
                    icon: const Icon(Icons.edit_rounded),
                  ),
                ),
              Flexible(child: bubble),
            ],
          );
          final card = Container(
            margin: const EdgeInsets.only(top: 6),
            constraints: BoxConstraints(maxWidth: availableWidth * 0.78),
            decoration: BoxDecoration(
              color: kInputBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: kBorder),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < attached.length; i++)
                  Padding(
                    padding: EdgeInsets.only(
                      bottom: i == attached.length - 1 ? 0 : 6,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.attach_file_rounded,
                          size: 14,
                          color: kMuted,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            '${i + 1}. ${path.basename(attached[i])}',
                            style: const TextStyle(
                              color: kText,
                              fontSize: 12,
                              height: 1.2,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          );
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Align(
              alignment: Alignment.centerRight,
              child: attached.isEmpty
                  ? userRow
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [userRow, card],
                    ),
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                bubble,
                if (!isPlaceholder)
                  Padding(
                    padding: const EdgeInsets.only(top: 2, left: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        _CopyButton(text: text),

                        if (onRegenerate != null) ...[
                          const SizedBox(width: 8),
                          IconButton(
                            onPressed: onRegenerate,
                            tooltip: 'Regenerate',
                            style: IconButton.styleFrom(
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              visualDensity: VisualDensity.compact,
                            ),
                            constraints: const BoxConstraints.tightFor(
                              width: 24,
                              height: 24,
                            ),
                            padding: EdgeInsets.zero,
                            iconSize: 14,
                            color: kMuted,
                            icon: const Icon(Icons.refresh_rounded),
                          ),
                        ],

                        if (message is AssistantMessage &&
                            (message as AssistantMessage).model != null) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2.5,
                            ),
                            decoration: BoxDecoration(
                              color: kInputBg,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: kBorder.withValues(alpha: 0.6),
                              ),
                            ),
                            child: Text(
                              (message as AssistantMessage).model!,
                              style: const TextStyle(
                                color: kMuted,
                                fontSize: 10,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _StreamingAssistantText extends StatelessWidget {
  final String text;

  const _StreamingAssistantText({required this.text});

  @override
  Widget build(BuildContext context) {
    final isPlaceholder =
        text.startsWith('…working') ||
        text.startsWith('…thinking') ||
        text.startsWith('…compacting');

    if (isPlaceholder) {
      return Text(
        text,
        style: TextStyle(
          color: kMuted.withValues(alpha: 0.85),
          fontSize: 14,
          fontStyle: FontStyle.italic,
          height: 1.3,
        ),
      );
    }

    return GptMarkdown(
      text,
      style: const TextStyle(color: kText, fontSize: 15),
    );
  }
}

class CompactedDividerBubble extends StatefulWidget {
  final CompactedNoticeMessage message;

  const CompactedDividerBubble({super.key, required this.message});

  @override
  State<CompactedDividerBubble> createState() => _CompactedDividerBubbleState();
}

class _CompactedDividerBubbleState extends State<CompactedDividerBubble> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final summary = widget.message.summary.trim();
    final hasSummary = summary.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Expanded(
                child: Divider(color: kBorder, height: 1, thickness: 0.5),
              ),
              InkWell(
                onTap: hasSummary
                    ? () => setState(() => _expanded = !_expanded)
                    : null,
                splashColor: Colors.transparent,
                highlightColor: Colors.transparent,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'compacted',
                        style: TextStyle(
                          color: kMuted.withValues(alpha: 0.65),
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.4,
                        ),
                      ),
                      if (hasSummary) ...[
                        const SizedBox(width: 3),
                        Icon(
                          _expanded
                              ? Icons.keyboard_arrow_up_rounded
                              : Icons.keyboard_arrow_down_rounded,
                          size: 13,
                          color: kMuted.withValues(alpha: 0.5),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const Expanded(
                child: Divider(color: kBorder, height: 1, thickness: 0.5),
              ),
            ],
          ),
          if (_expanded && hasSummary)
            Container(
              margin: const EdgeInsets.only(top: 10),
              padding: const EdgeInsets.all(12),
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.9,
              ),
              decoration: BoxDecoration(
                color: kInputBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: kBorder),
              ),
              child: GptMarkdown(
                summary,
                style: const TextStyle(color: kText, fontSize: 13),
              ),
            ),
        ],
      ),
    );
  }
}
