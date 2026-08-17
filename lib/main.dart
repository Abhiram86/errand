import 'dart:async';
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

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  late final LlmClient _llm;
  final List<Message> _messages = [
    const AssistantMessage(
      id: 'init',
      text: 'Hi! Ask me to read or list files in shared storage.',
    ),
  ];
  bool _busy = false;
  String? _workingMessageId;
  final _workingText = StringBuffer();
  Timer? _workingFlushTimer;
  bool _scrollPending = false;
  bool _permissionDialogOpen = false;
  final Directory _currentDir = Workspace.instance.root;

  @override
  void initState() {
    super.initState();
    _llm = LlmClient(
      config: LlmConfig(
        baseUrl: kBaseUrl.isEmpty ? 'https://openrouter.ai/api/v1' : kBaseUrl,
        apiKey: kApiKey,
        model: kModel,
      ),
    );
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkStoragePermission(promptIfMissing: true);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _workingFlushTimer?.cancel();
    _llm.close();
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkStoragePermission(promptIfMissing: true);
    }
  }

  Future<void> _checkStoragePermission({required bool promptIfMissing}) async {
    final permitted = await Workspace.instance.hasPermission();
    if (!mounted) return;
    if (!permitted && promptIfMissing) {
      await _showStoragePermissionDialog();
    }
  }

  Future<void> _showStoragePermissionDialog() async {
    if (!mounted || _permissionDialogOpen) return;
    _permissionDialogOpen = true;
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Storage access needed'),
          content: const Text(
            'Handy needs access to shared storage so it can read and list '
            'files. Android will open Settings where you can grant access.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.of(dialogContext).pop();
                await Workspace.instance.requestPermission();
              },
              child: const Text('Open settings'),
            ),
          ],
        ),
      );
    } finally {
      _permissionDialogOpen = false;
    }
  }

  void _showMoreActions() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('More actions are coming soon.')),
    );
  }

  void _scrollToBottom({bool animated = true}) {
    if (_scrollPending) return;
    _scrollPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollPending = false;
      if (!_scroll.hasClients) return;
      final distance =
          _scroll.position.maxScrollExtent - _scroll.position.pixels;
      if (!animated && distance > 160) return;
      if (animated) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      } else {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _busy) return;
    _controller.clear();
    final workingId = 'working-${DateTime.now().microsecondsSinceEpoch}';
    _workingMessageId = workingId;
    _workingText.clear();
    setState(() {
      _messages.add(
        UserMessage(
          id: 'user-${DateTime.now().millisecondsSinceEpoch}',
          text: text,
        ),
      );
      _messages.add(AssistantMessage(id: workingId, text: '…working'));
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
        localSystemPrompt: kSystemPrompt,
        messages: _messages
            .where((message) => message.id != _workingMessageId)
            .toList(growable: false),
        currentDir: _currentDir,
      );

      final loop = AgentLoop(
        llm: _llm,
        registry: ToolRegistry.defaults(currentDir: conversation.currentDir),
        onEvent: _handleEvent,
        onTextDelta: _handleTextDelta,
      );
      final answer = await loop.run(conversation);
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

        _appendToolMessage(
          ToolMessage(
            id: call.id,
            text: text,
            tool: ToolInvocation(name: call.name, args: call.arguments),
            result: result.toText(),
          ),
        );
    }
  }

  void _appendToolMessage(ToolMessage message) {
    if (!mounted) return;
    _workingFlushTimer?.cancel();
    _workingFlushTimer = null;

    setState(() {
      final workingId = _workingMessageId;
      final workingIndex = workingId == null
          ? -1
          : _messages.indexWhere((current) => current.id == workingId);

      if (workingIndex == -1) {
        _messages.add(message);
        return;
      }

      final currentText = _workingText.toString();
      _workingText.clear();

      // Finalize any streamed assistant text before inserting the tool that
      // followed it. Then create a fresh working bubble for the next agent
      // turn, preserving sequences such as tool1 → msg1 → tool2 → msg2.
      _messages.removeAt(workingIndex);
      var nextWorkingIndex = workingIndex;
      if (currentText.isNotEmpty) {
        _messages.insert(
          nextWorkingIndex,
          AssistantMessage(id: workingId!, text: currentText),
        );
        nextWorkingIndex++;
      }
      _messages.insert(nextWorkingIndex, message);
      nextWorkingIndex++;

      final nextWorkingId = 'working-${DateTime.now().microsecondsSinceEpoch}';
      _workingMessageId = nextWorkingId;
      _messages.insert(
        nextWorkingIndex,
        AssistantMessage(id: nextWorkingId, text: '…working'),
      );
    });
    _scrollToBottom();
  }

  void _handleTextDelta(String delta) {
    if (!mounted || _workingMessageId == null) return;
    _workingText.write(delta);
    if (_workingFlushTimer?.isActive ?? false) return;
    _workingFlushTimer = Timer(
      const Duration(milliseconds: 40),
      _flushWorkingText,
    );
  }

  void _flushWorkingText() {
    _workingFlushTimer = null;
    if (!mounted || _workingMessageId == null || _workingText.length == 0) {
      return;
    }
    final index = _messages.indexWhere(
      (message) => message.id == _workingMessageId,
    );
    if (index == -1) return;
    setState(() {
      _messages[index] = AssistantMessage(
        id: _workingMessageId!,
        text: _workingText.toString(),
      );
    });
    _scrollToBottom(animated: false);
  }

  void _replaceWorking(String text) {
    _workingFlushTimer?.cancel();
    _workingFlushTimer = null;
    final id = _workingMessageId;
    _workingText.clear();
    if (!mounted) return;
    setState(() {
      final index = id == null
          ? -1
          : _messages.indexWhere((message) => message.id == id);
      final message = AssistantMessage(
        id: id ?? 'agent-${DateTime.now().millisecondsSinceEpoch}',
        text: text,
      );
      if (index == -1) {
        _messages.add(message);
      } else {
        _messages[index] = message;
      }
      _busy = false;
      _workingMessageId = null;
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
            Expanded(child: _buildMessageList()),
            _buildComposer(),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageList() {
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
        return _MessageBubble(key: ValueKey(message.id), message: message);
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
        padding: const EdgeInsets.only(left: 8, right: 6),
        decoration: BoxDecoration(
          color: kInputBg,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: kBorder),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 32,
              height: 32,
              child: Transform.translate(
                offset: const Offset(0, -1),
                child: IconButton(
                  onPressed: _busy ? null : _showMoreActions,
                  tooltip: 'More actions',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                  icon: Icon(
                    Icons.add,
                    color: _busy ? kMuted : kText,
                    size: 22,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: TextField(
                controller: _controller,
                enabled: !_busy,
                minLines: 1,
                maxLines: 4,
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
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _controller,
              builder: (context, value, child) => _SendButton(
                canSend: !_busy && value.text.trim().isNotEmpty,
                onPressed: _send,
              ),
            ),
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

  const _MessageBubble({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final isUser = message is UserMessage;

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
          style: const TextStyle(color: kText, fontSize: 15, height: 20 / 15),
        ),
      ),
    );
  }
}
