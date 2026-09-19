import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../tools/intent_tool.dart';
import '../../types/message.dart';
import 'bubble_utils.dart';
import 'reopen_button.dart';
import 'tool_message_bubble.dart';

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
    // ignore: invalid_use_of_visible_for_testing_member
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
      final latestArgs = formatToolArgs(latestTool.tool.args);
      headerText = isDebug
          ? '${truncateForDisplay(latestTool.tool.name, 32)} '
                '${truncateForDisplay(latestArgs, kMaxToolHeaderChars)}'
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
                  ReopenButton(message: latestTool),
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
    final args = formatToolArgs(message.tool.args);
    final outputWasTruncated = message.result.length > kMaxToolOutputChars;
    final output = truncateForDisplay(message.result, kMaxToolOutputChars);

    final showRawArgs = isDebug;
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
                  ReopenButton(message: message),
                ],
                const SizedBox(width: 4),
                CopyButton(text: copyText, tooltip: copyTooltip),
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
