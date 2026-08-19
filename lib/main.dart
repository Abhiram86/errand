import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import 'agent/agent_loop.dart';
import 'agent/tool_registry.dart';
import 'llm/llm_client.dart';
import 'models/model_option.dart';
import 'services/model_catalog.dart';
import 'services/workspace.dart';
import 'tools/file_tools.dart';
import 'theme/app_colors.dart';
import 'types/conversation.dart';
import 'types/message.dart';
import 'widgets/chat_composer.dart';
import 'widgets/chat_sidebar.dart';
import 'widgets/message_bubbles.dart';
import 'widgets/model_picker.dart';

const kApiKey = String.fromEnvironment('OPENROUTER_API_KEY');
const kBaseUrl = String.fromEnvironment('HANDY_BASE_URL');
const kSystemPrompt =
    'You are Handy, a general-purpose agent running on an Android phone. '
    'You can navigate, inspect, and read files inside the user\'s granted '
    'workspace. Prefer list before reading whole files. Never guess '
    'file paths that have not been confirmed to exist. '
    'Try different methods when appropriate and do not stop after one failure. '
    'Use cd to change directories, then use relative paths from the new location.';

String _systemPromptFor(Directory currentDir) =>
    '$kSystemPrompt\nCurrent working directory: ${currentDir.path}';

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
  final _modelCatalog = ModelCatalogService();
  final _uuid = const Uuid();
  late LlmClient _llm;
  String _selectedModel = kConfiguredModel;
  List<ModelOption> _models = kFallbackModels;
  List<Message> _messages = _welcomeMessages();
  late Conversation _activeConversation;
  final List<Conversation> _conversations = [];
  bool _busy = false;
  String? _workingMessageId;
  final _workingText = StringBuffer();
  Timer? _workingFlushTimer;
  bool _scrollPending = false;
  bool _permissionDialogOpen = false;
  bool _sidebarOpen = false;
  final WorkingDirectory _workingDirectory = WorkingDirectory(
    Workspace.instance.root,
  );

  @override
  void initState() {
    super.initState();
    _activeConversation = _newDraftConversation();
    _llm = _createLlmClient(_selectedModel);
    unawaited(_loadModelCatalog());
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkStoragePermission(promptIfMissing: true);
    });
  }

  LlmClient _createLlmClient(String model) {
    return LlmClient(
      config: LlmConfig(
        // baseUrl: kBaseUrl.isEmpty ? 'https://openrouter.ai/api/v1' : kBaseUrl,
        baseUrl: kBaseUrl.isEmpty
            ? 'https://g9hnto0u7lvbu837.us-east-2.aws.endpoints.huggingface.cloud/v1'
            : kBaseUrl,
        apiKey: kApiKey,
        model: model,
      ),
    );
  }

  void _selectModel(String model) {
    if (_busy || model == _selectedModel) return;
    _llm.close();
    _llm = _createLlmClient(model);
    setState(() {
      _selectedModel = model;
      _activeConversation.model = model;
      _activeConversation.provider = _providerForModel(model);
      _touchConversation();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _workingFlushTimer?.cancel();
    _modelCatalog.close();
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

  Future<void> _loadModelCatalog() async {
    if (kApiKey.isEmpty) return;

    try {
      final models = await _modelCatalog.load(
        baseUrl: kBaseUrl.isEmpty ? 'https://openrouter.ai/api/v1' : kBaseUrl,
        apiKey: kApiKey,
      );
      if (!mounted) return;

      setState(() {
        _models = [
          ...models,
          if (!models.any((model) => model.id == _selectedModel))
            ModelOption(
              id: _selectedModel,
              name: _selectedModel,
              provider: 'Configured model',
            ),
        ];
      });
    } catch (_) {
      // The fallback catalog keeps the picker usable when offline or when
      // the configured endpoint does not expose a models route.
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

  static List<Message> _welcomeMessages() => [
    const AssistantMessage(
      id: 'init',
      text: 'Hi! Ask me to read or list files in shared storage.',
    ),
  ];

  Conversation _newDraftConversation() {
    return Conversation(
      messages: _messages,
      currentDir: _workingDirectory.current,
      model: _selectedModel,
      provider: _providerForModel(_selectedModel),
    );
  }

  String? _providerForModel(String model) {
    for (final option in _models) {
      if (option.id == model) return option.provider;
    }
    return null;
  }

  void _touchConversation() {
    if (_activeConversation.id != null) {
      _activeConversation.updatedAt = DateTime.now();
    }
  }

  void _startConversation(String firstMessage) {
    if (_activeConversation.id != null) {
      _touchConversation();
      return;
    }

    _activeConversation
      ..id = _uuid.v4()
      ..title = _conversationTitle(firstMessage)
      ..model = _selectedModel
      ..provider = _providerForModel(_selectedModel);
    _touchConversation();
    _conversations.add(_activeConversation);
  }

  String _conversationTitle(String message) {
    final singleLine = message.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (singleLine.length <= 42) return singleLine;
    return '${singleLine.substring(0, 39)}...';
  }

  List<Conversation> get _sortedConversations {
    final sorted = [..._conversations];
    sorted.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return sorted;
  }

  void _startNewChat() {
    if (_busy) return;
    _workingFlushTimer?.cancel();
    _workingFlushTimer = null;
    _controller.clear();
    setState(() {
      _messages = _welcomeMessages();
      _activeConversation = _newDraftConversation();
      _workingMessageId = null;
      _workingText.clear();
    });
    _closeSidebar();
    _scrollToBottom(animated: false);
  }

  void _selectConversation(Conversation conversation) {
    if (_busy || conversation.id == _activeConversation.id) {
      _closeSidebar();
      return;
    }
    setState(() {
      _activeConversation = conversation;
      _messages = conversation.messages;
      _selectedModel = conversation.model ?? kConfiguredModel;
      _llm.close();
      _llm = _createLlmClient(_selectedModel);
      _workingMessageId = null;
      _workingText.clear();
    });
    _closeSidebar();
    _scrollToBottom(animated: false);
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
    _startConversation(text);
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
        id: _activeConversation.id,
        localSystemPrompt: _systemPromptFor(_workingDirectory.current),
        messages: _messages
            .where((message) => message.id != _workingMessageId)
            .toList(growable: false),
        currentDir: _workingDirectory.current,
        attachedFileUris: _activeConversation.attachedFileUris,
        title: _activeConversation.title,
        provider: _activeConversation.provider,
        model: _activeConversation.model,
        isPinned: _activeConversation.isPinned,
        createdAt: _activeConversation.createdAt,
        updatedAt: _activeConversation.updatedAt,
      );

      final loop = AgentLoop(
        llm: _llm,
        registry: ToolRegistry.defaults(
          currentDir: _workingDirectory.root,
          workingDirectory: _workingDirectory,
        ),
        systemPromptBuilder: () => _systemPromptFor(_workingDirectory.current),
        onEvent: _handleEvent,
        onTextDelta: _handleTextDelta,
        onReasoningDelta: _handleReasoningDelta,
      );
      final answer = await loop.run(conversation);
      _replaceWorking(answer);
    } catch (e) {
      _replaceWorking('Error: $e');
    }
  }

  void _handleEvent(AgentEvent event) {
    switch (event) {
      case AgentToolCall(
        call: final call,
        result: final result,
        reasoning: final reasoning,
        reasoningDetails: final reasoningDetails,
      ):
        final text =
            '${call.name} → ${result.ok ? result.output.split('\n').take(3).join('\n') : result.errorMessage}';

        _appendToolMessage(
          ToolMessage(
            id: call.id,
            text: text,
            tool: ToolInvocation(name: call.name, args: call.arguments),
            result: result.toText(),
            reasoning: reasoning,
            reasoningDetails: reasoningDetails,
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
        _touchConversation();
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
      _touchConversation();
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

  void _handleReasoningDelta() {
    if (!mounted || _workingMessageId == null || _workingText.isNotEmpty) {
      return;
    }
    final index = _messages.indexWhere(
      (message) => message.id == _workingMessageId,
    );
    if (index == -1 || _messages[index].text == '…thinking') return;
    setState(() {
      _messages[index] = AssistantMessage(
        id: _workingMessageId!,
        text: '…thinking',
      );
      _touchConversation();
    });
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
      _touchConversation();
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
      _touchConversation();
      _busy = false;
      _workingMessageId = null;
    });
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kDarkBg,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final sidebarWidth = _sidebarWidth(constraints.maxWidth);

          return Stack(
            fit: StackFit.expand,
            children: [
              SafeArea(
                child: Column(
                  children: [
                    _buildHeader(),
                    Expanded(child: _buildMessageList()),
                    _buildComposer(),
                  ],
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: !_sidebarOpen,
                  child: AnimatedOpacity(
                    opacity: _sidebarOpen ? 1 : 0,
                    duration: const Duration(milliseconds: 220),
                    child: GestureDetector(
                      onTap: _closeSidebar,
                      child: ColoredBox(
                        color: Colors.black.withValues(alpha: 0.52),
                      ),
                    ),
                  ),
                ),
              ),
              AnimatedPositioned(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
                top: 0,
                bottom: 0,
                left: _sidebarOpen ? 0 : -sidebarWidth,
                width: sidebarWidth,
                child: ChatSidebar(
                  conversations: _sortedConversations,
                  activeConversationId: _activeConversation.id,
                  onClose: _closeSidebar,
                  onSelectConversation: _selectConversation,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  double _sidebarWidth(double screenWidth) {
    if (screenWidth <= 0) return 0;
    return math.min(
      screenWidth,
      math.max(248, math.min(420, screenWidth * 0.8)),
    );
  }

  void _openSidebar() {
    if (!mounted) return;
    setState(() => _sidebarOpen = true);
  }

  void _closeSidebar() {
    if (!mounted) return;
    setState(() => _sidebarOpen = false);
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 16, 6),
      child: Row(
        children: [
          IconButton(
            onPressed: _openSidebar,
            tooltip: 'Open sidebar',
            icon: const Icon(Icons.menu_rounded),
            color: kText,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: ModelPicker(
              selectedModel: _selectedModel,
              models: _models,
              enabled: !_busy,
              expand: true,
              onChanged: _selectModel,
            ),
          ),
          const SizedBox(width: 4),
          TextButton.icon(
            onPressed: _busy ? null : _startNewChat,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('New'),
            style: TextButton.styleFrom(
              foregroundColor: kText,
              disabledForegroundColor: kMuted,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 40),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
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
          return ToolMessageBubble(key: ValueKey(message.id), message: message);
        }
        return MessageBubble(key: ValueKey(message.id), message: message);
      },
    );
  }

  Widget _buildComposer() {
    return ChatComposer(
      controller: _controller,
      busy: _busy,
      onMoreActions: _showMoreActions,
      onSend: _send,
    );
  }
}
