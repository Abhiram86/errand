/// Message bubbles library for the Errand chat view.
///
/// Modularized into focused subcomponents under `lib/widgets/bubbles/`:
/// - [bubble_utils.dart]: shared formatting, truncation, CopyButton, SubtleFadeIn
/// - [chat_display_item.dart]: ChatDisplayItem, grouping consecutive tool runs
/// - [clamped_table_view.dart]: ClampedTableView and markdown table builder
/// - [compacted_divider_bubble.dart]: CompactedDividerBubble
/// - [reopen_button.dart]: ReopenButton for replaying intent actions
/// - [tool_message_bubble.dart]: ToolMessageBubble for single tool items
/// - [tool_group_bubble.dart]: ToolGroupBubble for multi-step tool runs
/// - [message_bubble.dart]: User & Assistant MessageBubble with streaming text
library;

export 'bubbles/bubble_utils.dart';
export 'bubbles/chat_display_item.dart';
export 'bubbles/clamped_table_view.dart';
export 'bubbles/compacted_divider_bubble.dart';
export 'bubbles/message_bubble.dart';
export 'bubbles/reopen_button.dart';
export 'bubbles/tool_group_bubble.dart';
export 'bubbles/tool_message_bubble.dart';
