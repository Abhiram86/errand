import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'agent/agent_loop.dart';
import 'agent/tool_registry.dart';
import 'llm/llm_client.dart';
import 'services/workspace.dart';
import 'types/conversation.dart';
import 'types/message.dart';

const kApiKey = String.fromEnvironment('OPENROUTER_API_KEY');
const kBaseUrl = String.fromEnvironment('HANDY_BASE_URL');
const kModel = String.fromEnvironment(
  'HANDY_MODEL',
  defaultValue: 'openai/gpt-4o-mini',
);

const kSystemPrompt =
    'You are Handy, a general-purpose agent running on an Android phone. '
    'You can read and list files inside the user\'s granted '
    'workspace. Prefer list before reading whole files. Never guess '
    'try to acheive users request by trying different methods dont leave after just one failure, be agentic'
    'file paths that have not been confirmed to exist.';

// Palette — mirrors the Expo chat screen.
const kDarkBg = Color(0xFF0B0E14);
const kBubbleUser = Color(0xFF1F6FEB);
const kBubbleAssistant = Color(0xFF1B2027);
const kText = Color(0xFFE6E9EF);
const kMuted = Color(0xFF8B93A1);
const kBorder = Color(0xFF242A33);
const kInputBg = Color(0xFF131820);
const kSendDisabled = Color(0xFF2B323C);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const HandyApp());
}

class HandyApp extends StatelessWidget {
  const HandyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Handy',
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

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  final List<Message> _messages = [
    const AssistantMessage(
      id: 'init',
      text:
          'Hi! Tap the folder icon and grant a folder, then ask me to read '
          'or list files.',
    ),
  ];
  bool _busy = false;
  String? _workspaceLabel;
  // This remains mutable so future directory navigation can update it.
  // ignore: prefer_final_fields
  Directory _currentDir = Workspace.instance.root;
  final _conversationCreatedAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    _restoreWorkspace();
  }

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _restoreWorkspace() async {
    final permitted = await Workspace.instance.hasPermission();
    if (!mounted || !permitted) return;
    setState(() => _workspaceLabel = _shorten(Workspace.instance.root.path));
  }

  Future<void> _grantFolder() async {
    if (!await Workspace.instance.hasPermission()) {
      await Workspace.instance.requestPermission();
    }

    final permitted = await Workspace.instance.hasPermission();
    if (!mounted) return;
    setState(() {
      _workspaceLabel = permitted
          ? _shorten(Workspace.instance.root.path)
          : null;
    });
  }

  String _shorten(String uri) {
    final idx = uri.lastIndexOf(':');
    return idx == -1 ? uri : uri.substring(0, idx.clamp(0, 40));
  }

  bool get _canSend => !_busy && _controller.text.trim().isNotEmpty;

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _busy) return;
    _controller.clear();
    setState(() {
      _messages.add(
        UserMessage(
          id: 'user-${DateTime.now().millisecondsSinceEpoch}',
          text: text,
        ),
      );
      _messages.add(
        AssistantMessage(
          id: 'working-${DateTime.now().millisecondsSinceEpoch}',
          text: '…working',
        ),
      );
      _busy = true;
    });
    _scrollToBottom();

    try {
      if (kApiKey.isEmpty) {
        _replaceWorking(
          'Error: OPENROUTER_API_KEY is missing. Start the app with '
          '`flutter run --dart-define-from-file=.env`.',
        );
        return;
      }

      final conversation = Conversation(
        id: 'main',
        localSystemPrompt: kSystemPrompt,
        messages: _messages
            .where(
              (message) =>
                  !(message is AssistantMessage && message.text == '…working'),
            )
            .toList(growable: false),
        tools: const [],
        currentDir: _currentDir,
        createdAt: _conversationCreatedAt,
        updatedAt: DateTime.now(),
      );

      final llm = LlmClient(
        config: LlmConfig(
          baseUrl: kBaseUrl.isEmpty ? 'https://openrouter.ai/api/v1' : kBaseUrl,
          apiKey: kApiKey,
          model: kModel,
        ),
      );
      final loop = AgentLoop(
        llm: llm,
        registry: ToolRegistry.defaults(currentDir: conversation.currentDir),
        onEvent: _handleEvent,
      );
      final answer = await loop.run(conversation);
      llm.close();
      _replaceWorking(answer);
    } catch (e) {
      _replaceWorking('Error: $e');
    }
  }

  void _handleEvent(AgentEvent event) {
    switch (event) {
      case AgentToolCall(call: final call, result: final result):
        final text =
            '${call.name} → ${result.ok ? result.output.split('\n').take(3).join('\n') : result.errorMessage}';

        _append(
          ToolMessage(
            id: call.id,
            text: text,
            tool: ToolInvocation(name: call.name, args: call.arguments),
            result: result.toText(),
          ),
        );
      case AgentTurn():
        break;
    }
  }

  void _append(Message message) {
    setState(() => _messages.add(message));
    _scrollToBottom();
  }

  void _replaceWorking(String text) {
    setState(() {
      _messages.removeWhere(
        (message) => message is AssistantMessage && message.text == '…working',
      );
      _messages.add(
        AssistantMessage(
          id: 'agent-${DateTime.now().millisecondsSinceEpoch}',
          text: text,
        ),
      );
      _busy = false;
    });
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kDarkBg,
      body: SafeArea(
        child: Column(
          children: [
            if (_workspaceLabel != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'workspace: $_workspaceLabel',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: kMuted, fontSize: 11),
                ),
              ),
            Expanded(child: _buildMessageList()),
            _buildComposer(),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageList() {
    if (_messages.isEmpty) {
      return Center(
        child: Text(
          'Ask Handy to read, find, or do something…',
          style: const TextStyle(color: kMuted, fontSize: 14),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.all(16),
      itemCount: _messages.length,
      itemBuilder: (context, i) {
        final message = _messages[i];
        if (message is ToolMessage) {
          return _ToolMessageBubble(
            key: ValueKey(message.id),
            message: message,
          );
        }
        return _MessageBubble(message: message);
      },
    );
  }

  Widget _buildComposer() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: const BoxDecoration(
        color: kDarkBg,
        border: Border(top: BorderSide(color: kBorder, width: 0.5)),
      ),
      child: Container(
        padding: const EdgeInsets.only(left: 4, right: 6),
        decoration: BoxDecoration(
          color: kInputBg,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: kBorder),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            IconButton(
              onPressed: _busy ? null : _grantFolder,
              tooltip: 'Grant workspace folder',
              icon: Icon(
                Icons.folder_open,
                color: _workspaceLabel != null ? kBubbleUser : kMuted,
                size: 22,
              ),
            ),
            Expanded(
              child: TextField(
                controller: _controller,
                enabled: !_busy,
                minLines: 1,
                maxLines: 4,
                onChanged: (_) => setState(() {}),
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                style: const TextStyle(color: kText, fontSize: 15),
                decoration: const InputDecoration(
                  hintText: 'Message Handy…',
                  hintStyle: TextStyle(color: kMuted),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
            const SizedBox(width: 4),
            _SendButton(canSend: _canSend, onPressed: _send),
          ],
        ),
      ),
    );
  }
}

/// Circular ↑ send button, blue like the user bubbles, dimmed when disabled —
/// matches the Expo composer exactly.
class _SendButton extends StatelessWidget {
  final bool canSend;
  final VoidCallback onPressed;

  const _SendButton({required this.canSend, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 38,
      height: 38,
      child: IconButton(
        onPressed: canSend ? onPressed : null,
        style: IconButton.styleFrom(
          backgroundColor: canSend ? kBubbleUser : kSendDisabled,
          shape: const CircleBorder(),
          padding: EdgeInsets.zero,
        ),
        icon: const Icon(Icons.arrow_upward, color: Colors.white, size: 20),
      ),
    );
  }
}

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

class _ToolMessageBubble extends StatelessWidget {
  final ToolMessage message;

  const _ToolMessageBubble({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final args = _formatToolArgs(message.tool.args);
    final outputWasTruncated = message.result.length > kMaxToolOutputChars;
    final output = _truncateForDisplay(message.result, kMaxToolOutputChars);

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
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            collapsedIconColor: kMuted.withValues(alpha: 0.45),
            iconColor: kMuted.withValues(alpha: 0.45),
            dense: true,
            visualDensity: VisualDensity.compact,
            minTileHeight: 24,
            title: Text(
              '${_truncateForDisplay(message.tool.name, 32)} '
              '${_truncateForDisplay(args, kMaxToolHeaderChars)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: kMuted, fontSize: 12),
            ),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: SelectableText(
                  outputWasTruncated
                      ? '$output\n\n[output truncated for display]'
                      : output,
                  style: const TextStyle(
                    color: kMuted,
                    fontSize: 11,
                    height: 1.3,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A chat bubble: user messages right + blue, everything else left + dark.
class _MessageBubble extends StatelessWidget {
  final Message message;

  const _MessageBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final isUser = message is UserMessage;
    final isTool = message is ToolMessage;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.82,
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
        child: SelectableText(
          message.text,
          style: TextStyle(
            color: kText,
            fontFamily: isTool ? 'monospace' : null,
            fontSize: isTool ? 12 : 15,
            height: 20 / 15,
          ),
        ),
      ),
    );
  }
}
