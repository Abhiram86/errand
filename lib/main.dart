import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:errand/services/database.dart';
import 'package:errand/services/a11y_service.dart';
import 'package:errand/services/intent_service.dart';
import 'package:uuid/uuid.dart';

import 'agent/agent_loop.dart';
import 'agent/context_budget.dart';
import 'agent/tool_registry.dart';
import 'llm/llm_client.dart';
import 'models/model_option.dart';
import 'services/model_catalog.dart';
import 'services/speech_service.dart';
import 'services/workspace.dart';
import 'tools/file_tools.dart';
import 'theme/app_colors.dart';
import 'types/conversation.dart';
import 'types/message.dart';
import 'widgets/chat_composer.dart';
import 'widgets/chat_sidebar.dart';
import 'widgets/message_bubbles.dart';
import 'widgets/model_picker.dart';
import 'widgets/paging.dart';

const kApiKey = String.fromEnvironment('OPENROUTER_API_KEY');
const kBaseUrl = String.fromEnvironment('ERRAND_BASE_URL');
const kSystemPrompt =
    'You are Errand, a general-purpose agent running on an Android phone. '
    'You can navigate, inspect, and read files inside the user\'s granted '
    'workspace. Prefer list before reading whole files. Never guess '
    'file paths that have not been confirmed to exist. '
    'Try different methods when appropriate and do not stop after one failure. '
    'Use cd to change directories, then use relative paths from the new location.';

String _systemPromptFor(Directory currentDir, {bool screenAccess = false}) {
  var prompt = '$kSystemPrompt\nCurrent working directory: ${currentDir.path}';
  if (screenAccess) {
    prompt +=
        '\nScreen access is ENABLED: you can use the "screen" tool to read '
        'what is currently on the phone\'s display (action:"read") and perform '
        'system navigation like back/home/recents (action:"global"). Use it to '
        'answer questions about the current screen or verify what an opened app '
        'is showing.';
  }
  return prompt;
}

final database = ErrandDatabase.instance;
// database.loadConversation(id)

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );
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

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  /// Sidebar pagination: page size for the live-watched first page and
  /// every subsequently loaded batch of recent conversations.
  static const _sidebarPageSize = 20;

  /// Message windowing: how many of the newest messages are loaded when a
  /// conversation is opened; earlier pages load on scroll-up.
  static const _messagePageSize = 50;

  final _controller = TextEditingController();
  final _scroll = ScrollController();
  final _modelCatalog = ModelCatalogService();
  final _uuid = const Uuid();
  late LlmClient _llm;
  String _selectedModel = kConfiguredModel;
  List<ModelOption> _models = kFallbackModels;
  List<Message> _messages = _welcomeMessages();
  late Conversation _activeConversation;
  List<Conversation> _conversations = [];
  List<Conversation> _pinnedConversations = [];

  // OPT-07 sidebar pagination: pages beyond the live-watched first page.
  final List<Conversation> _olderConversations = [];
  bool _loadingMoreConversations = false;

  // OPT-07 message windowing.
  bool _hasOlderMessages = false;
  bool _loadingOlderMessages = false;

  bool _busy = false;
  String? _workingMessageId;

  /// Set by the composer stop button; checked between SSE events and at
  /// agent-loop turn boundaries.
  final CancelToken _cancelToken = CancelToken();

  /// When set, the next send replaces this user message (and everything
  /// after it) instead of appending — the edit-resend flow.
  String? _editingMessageId;
  final _workingText = StringBuffer();
  Timer? _workingFlushTimer;

  /// Elapsed-seconds ticker for the …working placeholder (see
  /// [_startWorkingElapsedTimer]).
  Timer? _workingElapsedTimer;
  int _workingElapsedSeconds = 0;

  /// Platform-channel service used for the foreground work indicator that
  /// runs alongside every agent turn.
  final IntentService _intentService = IntentService();
  final A11yService _a11yService = A11yService();

  /// Cached accessibility-service state (refreshed on start/resume) feeding
  /// the conditional screen-access block of the system prompt.
  bool _a11yAvailable = false;

  bool _scrollPending = false;
  bool _permissionDialogOpen = false;
  bool _sidebarOpen = false;
  StreamSubscription<List<Conversation>>? _conversationsSub;
  StreamSubscription<List<Conversation>>? _pinnedConversationsSub;
  Timer? _persistTimer;
  final WorkingDirectory _workingDirectory = WorkingDirectory(
    Workspace.instance.root,
  );

  /// Loads sidebar pages past the live-watched first page. Cursor-anchored
  /// at the oldest currently visible conversation: unlike a count-based
  /// offset, this cannot skip or duplicate rows when the watched first page
  /// shifts mid-session (new chat created, conversation touched, …).
  late final PagedFetcher<Conversation> _conversationFetcher = PagedFetcher(
    pageSize: _sidebarPageSize,
    keyOf: (conversation) => conversation.id!,
    fetchPage: (_, limit) {
      final sorted = _sortedConversations;
      if (sorted.isEmpty) return Future.value(const []);
      final oldest = sorted.last;
      return database.loadOlderConversations(
        beforeUpdatedAt: oldest.updatedAt,
        beforeId: oldest.id!,
        limit: limit,
      );
    },
  );

  /// Loads message pages older than the currently loaded window, anchored
  /// at the oldest in-memory message.
  late final PagedFetcher<Message> _messageFetcher = PagedFetcher(
    pageSize: _messagePageSize,
    keyOf: (message) => message.id,
    fetchPage: (_, limit) => database.loadOlderMessages(
      _activeConversation.id!,
      beforeMessageId: _messages.first.id,
      limit: limit,
    ),
  );

  @override
  void initState() {
    super.initState();
    _activeConversation = _newDraftConversation();
    _llm = _createLlmClient(_selectedModel);
    unawaited(_loadModelCatalog());
    unawaited(_refreshA11yState());
    // One-time POST_NOTIFICATIONS grant so the foreground work indicator is
    // visible on API 33+ (the service itself runs regardless).
    unawaited(_intentService.requestNotificationPermission());
    WidgetsBinding.instance.addObserver(this);
    // Keep the sidebar in sync with everything that was persisted across
    // app restarts as well as any conversation we save while running.
    _conversationsSub = database.watchConversationSummaries(
      limit: _sidebarPageSize,
    ).listen((summaries) {
      if (!mounted) return;
      setState(() => _conversations = summaries);
    });
    _pinnedConversationsSub = database.watchPinnedConversations().listen((
      pinned,
    ) {
      if (!mounted) return;
      setState(() => _pinnedConversations = pinned);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkStoragePermission(promptIfMissing: true);
    });
  }

  LlmClient _createLlmClient(String model) {
    return LlmClient(
      config: LlmConfig(
        baseUrl: kBaseUrl.isEmpty ? 'https://openrouter.ai/api/v1' : kBaseUrl,
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
    _persistNow();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _workingFlushTimer?.cancel();
    _workingElapsedTimer?.cancel();
    unawaited(_intentService.stopWorkIndicator());
    _persistTimer?.cancel();
    _conversationsSub?.cancel();
    _pinnedConversationsSub?.cancel();
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
      // Re-check after the user may have toggled the service in Settings
      // while we were backgrounded.
      unawaited(_refreshA11yState());
    }
  }

  /// Cached screen-access availability for the system prompt. Refreshed on
  /// start and every resume — cheap channel call, avoids making
  /// _systemPromptFor async.
  Future<void> _refreshA11yState() async {
    try {
      final enabled = await _a11yService.isEnabled();
      if (!mounted || enabled == _a11yAvailable) return;
      setState(() => _a11yAvailable = enabled);
    } catch (_) {}
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
            'Errand needs access to shared storage so it can read and list '
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

  // -- Persistence --------------------------------------------------------

  /// Saves the active conversation (without the in-flight "…working" bubble)
  /// to the local database.
  Future<void> _persistConversation() async {
    final id = _activeConversation.id;
    if (id == null) return;

    final workingId = _workingMessageId;
    final messages = workingId == null
        ? _messages
        : _messages
              .where((message) => message.id != workingId)
              .toList(growable: false);

    await database.saveConversation(
      Conversation(
        id: id,
        localSystemPrompt: _activeConversation.localSystemPrompt,
        messages: messages,
        currentDir: _activeConversation.currentDir,
        attachedFileUris: _activeConversation.attachedFileUris,
        title: _activeConversation.title,
        provider: _activeConversation.provider,
        model: _activeConversation.model,
        isPinned: _activeConversation.isPinned,
        createdAt: _activeConversation.createdAt,
        updatedAt: _activeConversation.updatedAt,
      ),
    );
  }

  /// Debounces saves during streaming so we don't rewrite the whole
  /// conversation on every text delta.
  void _schedulePersist([Duration delay = const Duration(milliseconds: 600)]) {
    if (_activeConversation.id == null) return;
    _persistTimer?.cancel();
    _persistTimer = Timer(delay, () {
      _persistTimer = null;
      unawaited(_persistConversation());
    });
  }

  void _persistNow() {
    _persistTimer?.cancel();
    _persistTimer = null;
    unawaited(_persistConversation());
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
  }

  String _conversationTitle(String message) {
    final singleLine = message.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (singleLine.length <= 42) return singleLine;
    return '${singleLine.substring(0, 39)}...';
  }

  /// Watched first page + loaded older pages, deduped by id (the watched
  /// page wins) and re-sorted by recency.
  List<Conversation> get _sortedConversations {
    final seen = <String>{};
    final unique = <Conversation>[
      for (final conversation in [..._conversations, ..._olderConversations])
        if (conversation.id != null && seen.add(conversation.id!))
          conversation,
    ];
    unique.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return unique;
  }

  Future<void> _loadMoreConversations() async {
    final fetcher = _conversationFetcher;
    if (!fetcher.hasMore || fetcher.loading || _loadingMoreConversations) {
      return;
    }
    setState(() => _loadingMoreConversations = true);
    try {
      final fresh = await fetcher.loadMore({
        for (final conversation in _sortedConversations) conversation.id!,
      });
      if (!mounted) return;
      setState(() {
        _olderConversations.addAll(fresh);
        _loadingMoreConversations = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMoreConversations = false);
    }
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
      _editingMessageId = null;
      _hasOlderMessages = false;
    });
    _closeSidebar();
    _scrollToBottom(animated: false);
  }

  Future<void> _selectConversation(Conversation conversation) async {
    final id = conversation.id;
    if (_busy || id == null || id == _activeConversation.id) {
      _closeSidebar();
      return;
    }

    // Sidebar rows are summaries; fetch the full conversation with messages
    // before switching to it. OPT-07: only the newest window of messages is
    // loaded; older pages stream in on scroll-up.
    final loaded = await database.loadConversation(
      id,
      messageLimit: _messagePageSize,
    );
    if (!mounted) return;
    if (loaded == null) {
      _closeSidebar();
      return;
    }

    setState(() {
      _activeConversation = loaded;
      _messages = loaded.messages;
      _selectedModel = loaded.model ?? kConfiguredModel;
      _llm.close();
      _llm = _createLlmClient(_selectedModel);
      _workingMessageId = null;
      _workingText.clear();
      _editingMessageId = null;
      // A short page means the whole history fit in the first window.
      _hasOlderMessages = loaded.messages.length == _messagePageSize;
      _messageFetcher.hasMore = true;
    });
    _closeSidebar();
    _scrollToBottom(animated: false);
  }

  /// Prepends the previous page of messages, keeping the viewport anchored
  /// on the same content (no visual jump).
  Future<void> _loadOlderMessages() async {
    final conversationId = _activeConversation.id;
    if (conversationId == null ||
        !_hasOlderMessages ||
        _loadingOlderMessages ||
        _messageFetcher.loading) {
      return;
    }

    final hadClients = _scroll.hasClients;
    final oldMax = hadClients ? _scroll.position.maxScrollExtent : 0.0;
    final oldPixels = hadClients ? _scroll.position.pixels : 0.0;

    setState(() => _loadingOlderMessages = true);
    var older = const <Message>[];
    try {
      older = await _messageFetcher.loadMore({
        for (final message in _messages) message.id,
      });
    } catch (_) {
      // Keep the window as-is on failure; the user can retry by scrolling.
    }
    if (!mounted) return;
    setState(() {
      _loadingOlderMessages = false;
      _hasOlderMessages = _messageFetcher.hasMore && older.isNotEmpty;
      if (older.isNotEmpty) {
        _messages = [...older, ..._messages];
      }
    });
    if (older.isNotEmpty && hadClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        // Everything inserted above shifted the content down by exactly
        // the growth of maxScrollExtent; compensate to stay in place.
        final delta = _scroll.position.maxScrollExtent - oldMax;
        _scroll.jumpTo(
          (oldPixels + delta).clamp(0.0, _scroll.position.maxScrollExtent),
        );
      });
    }
  }

  Future<void> _deleteConversation(Conversation conversation) async {
    final id = conversation.id;
    if (_busy || id == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete conversation?'),
        content: Text(
          '"${conversation.title}" and its messages will be permanently removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await database.deleteConversation(id);
    if (!mounted) return;
    // The live watch only covers the first page — evict the deleted row
    // from any already-loaded older pages so it can't linger as a ghost.
    setState(() {
      _olderConversations.removeWhere((c) => c.id == id);
    });
    if (_activeConversation.id == id) {
      _startNewChat();
    }
    _closeSidebar();
  }

  /// Rename dialog → update the title in the DB. The sidebar refreshes via
  /// the existing watch stream; older loaded pages are refreshed here.
  Future<void> _renameConversation(Conversation conversation) async {
    final id = conversation.id;
    if (id == null) return;

    final controller = TextEditingController(text: conversation.title);
    final title = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename chat'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 100,
          onSubmitted: (value) =>
              Navigator.of(dialogContext).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    if (title == null || title.isEmpty || !mounted) return;

    await database.renameConversation(id, title);
    if (!mounted) return;
    setState(() {
      if (_activeConversation.id == id) {
        _activeConversation.title = title;
      }
      // Older pages hold summary snapshots; refresh the renamed row.
      final index = _olderConversations.indexWhere((c) => c.id == id);
      if (index != -1) _olderConversations[index].title = title;
    });
  }

  Future<void> _pinConversation(Conversation conversation) async {
    final id = conversation.id;
    if (_busy || id == null) return;

    await database.pinConversation(id);
    if (!mounted) return;
    // Older pages hold summary snapshots; refresh (or drop, if deleted)
    // the toggled row so the sidebar doesn't render stale pin state.
    final fresh = await database.loadConversationSummary(id);
    if (!mounted) return;
    setState(() {
      final index = _olderConversations.indexWhere((c) => c.id == id);
      if (index != -1) {
        if (fresh == null) {
          _olderConversations.removeAt(index);
        } else {
          _olderConversations[index] = fresh;
        }
      }
    });
    if (_activeConversation.id == id) {
      _touchConversation();
    }
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

    // A live dictation session would keep writing its next partials into
    // the (now empty) composer after the message is gone — end it.
    unawaited(SpeechService.instance.stop());

    // Editing an earlier message: the resend replaces it and everything
    // after it (later messages AND their tool runs).
    if (_editingMessageId != null) {
      await _truncateFrom(_editingMessageId!);
      _editingMessageId = null;
    }

    _startConversation(text);
    setState(() {
      _messages.add(
        UserMessage(
          id: 'user-${DateTime.now().millisecondsSinceEpoch}',
          text: text,
        ),
      );
    });
    await _runAgentTurn();
  }

  /// Regenerate: drops everything after [userMessageId] (same truncation
  /// semantics as edit-resend) and re-runs the loop for that turn.
  Future<void> _regenerate(String userMessageId) async {
    if (_busy) return;
    // A pending edit (banner + loaded composer text) is superseded by an
    // explicit regenerate — drop it instead of leaving stale state around.
    if (_editingMessageId != null) _cancelEditing();
    final index = _messages.indexWhere((m) => m.id == userMessageId);
    if (index == -1) return;

    // Nothing after it (e.g. the previous turn failed) → nothing to drop.
    if (index + 1 < _messages.length) {
      await _truncateFrom(_messages[index + 1].id);
    }
    await _runAgentTurn();
  }

  /// If [message] is the final assistant bubble of a user-turn response
  /// (the end-of-response step), returns the owning user message id so a
  /// regenerate can be anchored to that turn; otherwise null.
  String? _regenerateTargetFor(Message message) {
    if (message is! AssistantMessage) return null;
    final index = _messages.indexOf(message);
    // The response's last step: no other assistant bubble follows before
    // the next user message (tool bubbles in between are fine).
    for (var i = index + 1; i < _messages.length; i++) {
      final next = _messages[i];
      if (next is AssistantMessage) return null;
      if (next is UserMessage) break; // turn boundary — this IS the last step
    }
    // Walk back to the owning user message; no user message → nothing to
    // regenerate from (e.g. the welcome bubble).
    for (var i = index - 1; i >= 0; i--) {
      final previous = _messages[i];
      if (previous is UserMessage) return previous.id;
    }
    return null;
  }

  /// Tap on own bubble: load its text into the composer for editing.
  void _editUserMessage(UserMessage message) {
    if (_busy) return;
    setState(() {
      _editingMessageId = message.id;
      _controller.text = message.text;
    });
  }

  void _cancelEditing() {
    setState(() {
      _editingMessageId = null;
      _controller.clear();
    });
  }

  /// Removes [messageId] and every message after it from memory AND from
  /// the database. Shared by edit-resend and regenerate: merge-based saves
  /// keep rows outside the loaded window, so dropping them from memory
  /// alone would leave orphaned rows that resurrect on reload.
  Future<void> _truncateFrom(String messageId) async {
    final index = _messages.indexWhere((message) => message.id == messageId);
    if (index == -1) return;

    final removed = _messages.sublist(index);
    setState(() => _messages.removeRange(index, _messages.length));
    _touchConversation();

    final conversationId = _activeConversation.id;
    if (conversationId == null) return;
    for (final message in removed) {
      await database.deleteMessage(conversationId, message.id);
    }
  }

  /// Shared tail of send / edit-resend / regenerate: adds the …working
  /// bubble and runs the agent loop over the current history.
  Future<void> _runAgentTurn() async {
    final workingId = 'working-${DateTime.now().microsecondsSinceEpoch}';
    _workingMessageId = workingId;
    _workingText.clear();
    setState(() {
      _messages.add(AssistantMessage(id: workingId, text: '…working'));
      _busy = true;
    });
    // Foreground service: keeps the process non-cached (and its sockets
    // alive) even when an intent tool sends Errand to the background.
    unawaited(_intentService.startWorkIndicator());
    _startWorkingElapsedTimer();
    _persistNow();
    _scrollToBottom();

    try {
      if (kApiKey.isEmpty) {
        _failWorking(
          'OPENROUTER_API_KEY is missing. Start the app with '
          '`flutter run --dart-define-from-file=.env`.',
        );
        return;
      }

      final conversation = Conversation(
        id: _activeConversation.id,
        localSystemPrompt:
            _systemPromptFor(_workingDirectory.current, screenAccess: _a11yAvailable),
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
        systemPromptBuilder: () =>
            _systemPromptFor(_workingDirectory.current, screenAccess: _a11yAvailable),
        cancelToken: _cancelToken,
        onEvent: _handleEvent,
        onTextDelta: _handleTextDelta,
        onReasoningDelta: _handleReasoningDelta,
      );
      _cancelToken.reset();
      final answer = await loop.run(conversation);
      _replaceWorking(answer);
    } on LlmStoppedException {
      // Stop pressed: keep whatever streamed so far as the final answer.
      _finishStopped();
    } catch (e) {
      // Transport/API failures (connection aborts, timeouts, HTTP 429/5xx)
      // are not the agent's fault — show a transient toast instead of adding
      // an error message to the conversation context.
      _failWorking(e is LlmException ? e.message : 'Unexpected error: $e');
    }
  }

  /// Elapsed-seconds ticker for the …working placeholder: slow models spend
  /// 30–90s before the first token, and a static "…working" is
  /// indistinguishable from a hung request. Stops updating once real deltas
  /// arrive (the streamed text takes over the bubble).
  void _startWorkingElapsedTimer() {
    _workingElapsedTimer?.cancel();
    _workingElapsedSeconds = 0;
    _workingElapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _workingMessageId == null) return;
      if (_workingText.isNotEmpty) return; // streamed text owns the bubble now
      _workingElapsedSeconds++;
      final index =
          _messages.indexWhere((message) => message.id == _workingMessageId);
      if (index == -1) return;
      setState(() {
        _messages[index] = AssistantMessage(
          id: _workingMessageId!,
          text: '…working · ${_workingElapsedSeconds}s',
        );
      });
    });
  }

  /// Removes the working placeholder and surfaces [message] as a snackbar.
  /// Used for infra-level failures that must not enter model context.
  void _failWorking(String message) {
    _workingFlushTimer?.cancel();
    _workingFlushTimer = null;
    _workingElapsedTimer?.cancel();
    unawaited(_intentService.stopWorkIndicator());
    final id = _workingMessageId;
    _workingText.clear();
    if (!mounted) return;
    setState(() {
      final index = id == null
          ? -1
          : _messages.indexWhere((current) => current.id == id);
      if (index != -1) _messages.removeAt(index);
      _busy = false;
      _workingMessageId = null;
    });
    // OPT-07: saves merge by message id now, so a working bubble that was
    // already persisted mid-stream must be removed from the DB explicitly.
    final conversationId = _activeConversation.id;
    if (conversationId != null && id != null) {
      unawaited(database.deleteMessage(conversationId, id));
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 5),
      ),
    );
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
    // OPT-01: coalesce persists when multiple tool calls arrive in the
    // same agent turn (was _persistNow per tool -> N full rewrites).
    // A short debounce batches them; the final answer still does _persistNow.
    _schedulePersist(const Duration(milliseconds: 150));
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
    // Whitespace-only deltas (some models open with "\n") must not blank
    // out the …working placeholder.
    if (!mounted ||
        _workingMessageId == null ||
        _workingText.toString().trim().isEmpty) {
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
    _schedulePersist();
    _scrollToBottom(animated: false);
  }

  void _replaceWorking(String text) {
    _workingFlushTimer?.cancel();
    _workingFlushTimer = null;
    _workingElapsedTimer?.cancel();
    unawaited(_intentService.stopWorkIndicator());
    final id = _workingMessageId;
    _workingText.clear();
    if (!mounted) return;
    // Some models return an empty/whitespace final answer (content-only
    // tool turns, stray "\n"). Trim it; if nothing is left, drop the
    // bubble instead of rendering an empty one.
    final trimmed = text.trim();
    setState(() {
      final index = id == null
          ? -1
          : _messages.indexWhere((message) => message.id == id);
      if (trimmed.isEmpty) {
        if (index != -1) _messages.removeAt(index);
      } else {
        final message = AssistantMessage(
          id: id ?? 'agent-${DateTime.now().millisecondsSinceEpoch}',
          text: trimmed,
        );
        if (index == -1) {
          _messages.add(message);
        } else {
          _messages[index] = message;
        }
      }
      _touchConversation();
      _busy = false;
      _workingMessageId = null;
    });
    // Merge-based saves keep rows not in memory — a dropped bubble that
    // was persisted mid-stream must be removed explicitly.
    final conversationId = _activeConversation.id;
    if (trimmed.isEmpty && conversationId != null && id != null) {
      unawaited(database.deleteMessage(conversationId, id));
    }
    _persistNow();
    _scrollToBottom();
  }

  /// Stop button pressed: flag cancellation; the loop throws
  /// [LlmStoppedException] at the next safe boundary (between SSE events,
  /// or at the next turn boundary if a native tool call is in flight).
  void _stopGeneration() {
    if (!_busy) return;
    _cancelToken.cancel();
  }

  // -- Voice input ---------------------------------------------------------

  /// Mic button: start/stop a speech-recognition session. Recognized text
  /// lands in the composer (live partials); the user reviews and sends.
  Future<void> _toggleVoiceInput() async {
    final speech = SpeechService.instance;
    if (speech.listening.value) {
      await speech.stop();
      return; // listening notifier flips via onStatus
    }
    if (_busy) return;

    if (!await speech.hasMicPermission()) {
      final granted = await speech.requestMicPermission();
      if (!mounted) return;
      if (!granted) {
        _showToast('Microphone permission is needed for voice input.');
        return;
      }
    }

    if (!await speech.initialize()) {
      if (!mounted) return;
      _showToast(
        'Speech recognition is unavailable on this device. On emulators, '
        'enable the Google app and grant it microphone access.',
      );
      return;
    }

    var localeId = await speech.savedLocaleId();
    if (localeId == null) {
      localeId = await _pickVoiceLocale();
      if (!mounted) return;
      if (localeId == null) return; // user cancelled the picker
      await speech.saveLocaleId(localeId);
    }

    try {
      await speech.listen(
        localeId: localeId,
        onResult: (words, isFinal) {
          if (!mounted) return;
          // Cumulative partials replace the composer text; keep the cursor
          // at the end so typing can continue seamlessly.
          _controller.value = TextEditingValue(
            text: words,
            selection: TextSelection.collapsed(offset: words.length),
          );
          if (isFinal && mounted) setState(() {});
        },
      );
    } catch (e) {
      if (!mounted) return;
      _showToast('Could not start voice input: $e');
    }
  }

  /// First-use language picker over the device's installed speech locales.
  Future<String?> _pickVoiceLocale() async {
    final locales = await SpeechService.instance.locales();
    if (!mounted) return null;
    if (locales.isEmpty) {
      _showToast('No speech languages are installed on this device.');
      return null;
    }
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Voice input language'),
        children: [
          for (final locale in locales)
            SimpleDialogOption(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(locale.localeId),
              child: Text(
                locale.name,
                style: const TextStyle(color: kText, fontSize: 14),
              ),
            ),
        ],
      ),
    );
  }

  void _showToast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  /// Finalizes a stopped turn: partial streamed text becomes the final
  /// answer (marked "(stopped)"); nothing streamed → drop the bubble.
  void _finishStopped() {
    final partial = _workingText.toString().trim();
    _replaceWorking(partial.isEmpty ? '' : '$partial\n\n_(stopped)_');
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
                    if (kDebugMode) _buildContextFooter(),
                    if (_editingMessageId != null) _buildEditingBanner(),
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
                  pinnedConversations: _pinnedConversations,
                  conversations: _sortedConversations,
                  activeConversationId: _activeConversation.id,
                  onClose: _closeSidebar,
                  onSelectConversation: _selectConversation,
                  onDeleteConversation: _deleteConversation,
                  hasMoreConversations: _conversationFetcher.hasMore,
                  isLoadingMoreConversations: _loadingMoreConversations,
                  onLoadMoreConversations: _loadMoreConversations,
                  optionsBuilder: (conversation) => [
                    ChatOption(
                      title: 'Rename',
                      icon: Icons.edit,
                      onTap: () {
                        _renameConversation(conversation);
                      },
                    ),
                    ChatOption(
                      title: conversation.isPinned ? 'Unpin Conversation' : 'Pin Conversation',
                      icon: conversation.isPinned
                          ? Icons.push_pin
                          : Icons.push_pin_outlined,
                      onTap: () {
                        _pinConversation(conversation);
                      },
                    ),
                    ChatOption(
                      title: 'Delete conversation',
                      icon: Icons.delete_outline_rounded,
                      type: ChatOptionType.destructive,
                      onTap: () {
                        _deleteConversation(conversation);
                      },
                    ),
                  ],
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
          if (_activeConversation.id != null)
          TextButton(
            onPressed: _busy ? null : _startNewChat,
            style: TextButton.styleFrom(
              foregroundColor: kText,
              disabledForegroundColor: kMuted,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
              alignment: Alignment.center,
              backgroundColor: kBubbleAssistant,
              minimumSize: const Size(60, 35),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.add_rounded, size: 14),
                const SizedBox(width: 2),
                const Text('New', style: TextStyle(fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageList() {
    return SelectionArea(
      child: NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.depth == 0 &&
            !_busy &&
            shouldLoadMore(notification, PagingEdge.leading)) {
          _loadOlderMessages();
        }
        return false;
      },
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.all(16),
        itemCount: _messages.length + (_loadingOlderMessages ? 1 : 0),
        itemBuilder: (context, i) {
          if (_loadingOlderMessages && i == 0) {
            return const LoadMoreIndicator(label: 'Loading earlier messages');
          }
          final index = _loadingOlderMessages ? i - 1 : i;
          final message = _messages[index];
          if (message is ToolMessage) {
            return ToolMessageBubble(
              key: ValueKey(message.id),
              message: message,
            );
          }
          // Regenerate sits on the LAST assistant bubble of each user-turn
          // response (the end-of-response step), not just the literal last
          // message of the conversation. Regenerating an older turn also
          // drops every later turn — same semantics as edit-resend.
          final regenerateUserId = !_busy
              ? _regenerateTargetFor(message)
              : null;
          return MessageBubble(
            key: ValueKey(message.id),
            message: message,
            onEdit:
                message is UserMessage ? () => _editUserMessage(message) : null,
            onRegenerate: regenerateUserId == null
                ? null
                : () => _regenerate(regenerateUserId),
          );
        },
      ),
      ),
    );
  }

  /// Debug-only: estimated LLM context size for the loaded history
  /// (chars/4 ≈ tokens) against the truncation limits.
  Widget _buildContextFooter() {
    final chars = estimateHistoryChars(_messages);
    final truncated = chars > kContextSoftLimit;
    return Material(
      color: kInputBg,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'ctx ~${chars ~/ 1024}K / ${kContextSoftLimit ~/ 1024}K'
            '${truncated ? ' (will truncate to ≤${kContextTarget ~/ 1024}K)' : ''}'
            ' · ${_messages.length} msgs loaded',
            style: const TextStyle(color: kMuted, fontSize: 10),
          ),
        ),
      ),
    );
  }

  Widget _buildComposer() {
    return ChatComposer(
      controller: _controller,
      busy: _busy,
      onMoreActions: _showMoreActions,
      onSend: _send,
      onStop: _stopGeneration,
      onMic: _toggleVoiceInput,
      isListening: SpeechService.instance.listening,
    );
  }

  /// Shown while editing a user message; sending replaces it and
  /// everything after it.
  Widget _buildEditingBanner() {
    return Material(
      color: kInputBg,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 4, 0),
        child: Row(
          children: [
            const Icon(Icons.edit_rounded, size: 14, color: kMuted),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'Editing message — sending replaces it and everything after',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: kMuted, fontSize: 12),
              ),
            ),
            IconButton(
              onPressed: _cancelEditing,
              tooltip: 'Cancel edit',
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              color: kMuted,
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
      ),
    );
  }
}
