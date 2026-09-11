import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:errand/services/database.dart';
import 'package:errand/services/a11y_service.dart';
import 'package:errand/services/app_settings.dart';
import 'package:errand/services/installed_apps_service.dart';
import 'package:errand/services/intent_service.dart';
import 'package:uuid/uuid.dart';

import 'agent/agent_loop.dart';
import 'agent/context_budget.dart';
import 'agent/tool_registry.dart';
import 'llm/llm_client.dart';
import 'models/llm_provider.dart';
import 'models/model_option.dart';
import 'services/model_catalog.dart';
import 'services/models_dev_service.dart';
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
import 'widgets/settings_sheet.dart';
const kSystemPrompt = '''
You are Errand, a friendly, capable, and practical personal AI assistant running on Android.
You communicate naturally, warmly, and clearly with the user.

Interaction Principles:
- For greetings ("hi", "hello"), casual conversation, or general knowledge questions, reply warmly and directly — do NOT invoke tools or search for files unless the user asks for action or inspection.
- Only invoke tools when the user's intent requires device interaction, workspace inspection, or external information.
- Keep answers concise, clear, and actionable. Avoid robotic phrasing or unprompted system dumps.

Tool Selection Guide:
- workspace: Browse folder structure (actions: "list", "find", "cd", "pwd"). Use this to locate files, navigate, or check directory contents. Supports optional "grep" to filter results with regex. NEVER use workspace to read file contents.
- read: Read contents of a specific file (text, PDF, DOCX, media). Requires "path". Supports optional "grep" (regex) to pull only matching lines with line numbers. NEVER call read on a directory.
- attached_files: When the user refers to an attached or uploaded file without specifying a path (e.g. "this file", "the document", "summarize this"), call attached_files to discover its URI, then use read. Never guess file paths.
- If a tool call fails, re-check arguments against the tool schema and adapt. Never repeat an identical failing call. Two identical failures mean the approach is wrong: change approach or ask the user.
''';

String _systemPromptFor(
  Directory currentDir, {
  bool screenAccess = false,
  bool screenRestricted = false,
  bool a11ySupported = true,
}) {
  var prompt = '$kSystemPrompt\nCurrent working directory: ${currentDir.path}';
  if (!a11ySupported) {
    return prompt;
  }
  if (screenAccess) {
    prompt += '''

Screen & Device Capabilities (ENABLED):
- screen:
  * action:"read" to get visible UI elements with interactive [ref] numbers. Supports optional "grep" (regex) to filter outline lines. Use settle_ms (~800–1500) after opening apps, navigation, or system theme changes so screens have time to render.
  * action:"global" for system navigation (name: "back" | "home" | "recents" | "notifications").
- act: Interact with UI elements seen on screen (action: "tap" | "fill" | "scroll" | "press").
  * Prefer passing then_read:true on act calls to automatically receive the updated screen outline in the same step (supports optional "grep" to filter the updated outline).
  * For form inputs, use action:"fill" (label/ref + text).
  * Toggles & system switches: System settings (like Dark theme, Wi-Fi, Bluetooth) animate and take time to settle (~1s). Do NOT immediately re-tap a toggle switch or radio option if it appears unchanged right away; allow it to settle to avoid toggling it back off.
  * Safety (DRAFT POLICY): Prepare everything up to the final commit (type messages, fill forms, navigate), but let the user perform final-commit taps (Send, Pay, Delete, Submit).
''';
  } else {
    prompt += '''

Screen & Device Capabilities (DISABLED):
- Errand's screen access (Accessibility Service) is currently OFF / PAUSED.
- Note: Errand pauses screen access when closed to keep other apps secure.
- You CANNOT inspect or interact with screens (both "screen" and "act" tools will fail while this is off).
- If the user asks you to interact with an app, inspect their screen, or automate UI tasks, explain that Screen Access is currently off (paused when closed to keep other apps secure), and ask them to enable it in Settings > Accessibility or via Errand Settings > Tools.
${screenRestricted ? '- IMPORTANT: this device blocks enabling ("Restricted setting" — sideloaded install). The user must FIRST do Settings > Apps > Errand > three-dot menu > Allow restricted settings, THEN enable Errand under Settings > Accessibility. Generic "turn it on" guidance will NOT work.' : ''}
''';
  }
  return prompt;
}

@visibleForTesting
String systemPromptFor(
  Directory currentDir, {
  bool screenAccess = false,
  bool screenRestricted = false,
  bool a11ySupported = true,
}) =>
    _systemPromptFor(
      currentDir,
      screenAccess: screenAccess,
      screenRestricted: screenRestricted,
      a11ySupported: a11ySupported,
    );

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
  String _selectedModel = kDefaultModelId;
  List<ModelOption> _models = kFallbackModels;
  List<Message> _messages = _welcomeMessages();
  late Conversation _activeConversation;
  List<Conversation> _conversations = [];
  List<Conversation> _pinnedConversations = [];

  /// Staged files from + → pending card; on send they become
  /// UserMessage.attachedUris and are also appended to the conversation's
  /// global inventory (_activeConversation.attachedFileUris) for the Local tab.
  final List<String> _pendingAttachments = [];

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

  /// Flipped true when reasoning deltas stream for the current turn —
  /// switches the placeholder label …working → …thinking. Single-writer
  /// rule: this flag + [_updateWorkingPlaceholder] own the placeholder
  /// text so writers can't fight each other (that used to flicker).
  bool _workingReasoning = false;
  bool _workingCompacting = false;

  /// Debug override: set to a positive number (e.g. 8000) during testing to force early compaction.
  /// Set to 0 to use native model context budgets.
  static const int _debugCompactionThreshold = 0;

  ContextBudget _getActiveBudget() {
    final modelContextSize = ModelCatalogService.getContextLength(
      _selectedModel,
      baseUrl: AppSettingsService.instance.effectiveBaseUrl,
    );
    return ContextBudget(
      contextSize: modelContextSize,
      overrideThreshold:
          _debugCompactionThreshold > 0 ? _debugCompactionThreshold : null,
    );
  }

  /// Platform-channel service used for the foreground work indicator that
  /// runs alongside every agent turn.
  final IntentService _intentService = IntentService();
  final A11yService _a11yService = A11yService();

  /// Cached accessibility-service state (refreshed on start/resume) feeding
  /// the conditional screen-access block of the system prompt.
  bool _a11ySupported = A11yService.isSupportedSync;
  bool _a11yAvailable = false;
  bool _a11yRestricted = false;
  bool _showA11yToast = false;
  Timer? _a11yToastTimer;

  /// True for one frame after opening a conversation, so the leading-edge
  /// pager doesn't cascade-load history while the viewport is still at the top.
  bool _loadOlderSuppressed = false;

  bool _scrollPending = false;
  bool _permissionDialogOpen = false;
  bool _sidebarOpen = false;
  bool _externalAppWorkDone = false;
  bool _externalIntentLaunched = false;
  StreamSubscription<List<Conversation>>? _conversationsSub;
  StreamSubscription<List<Conversation>>? _pinnedConversationsSub;
  Timer? _persistTimer;
  int _estimatedActiveTokens = 0;
  List<Conversation> _cachedSortedConversations = [];
  bool _sortedConversationsDirty = true;
  final Set<String> _animatedMessageIds = <String>{};

  void _updateEstimatedTokens() {
    final lastCompactedIdx =
        _messages.lastIndexWhere((m) => m is CompactedNoticeMessage);
    final activeMessages = lastCompactedIdx != -1
        ? _messages.sublist(lastCompactedIdx)
        : _messages;
    _estimatedActiveTokens = estimateHistoryTokens(activeMessages);
  }

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
    _animatedMessageIds.addAll(_messages.map((m) => m.id));
    _updateEstimatedTokens();
    ModelsDevService.preload();
    unawaited(_loadAppConfig());
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
      setState(() {
        _conversations = summaries;
        _sortedConversationsDirty = true;
      });
    });
    _pinnedConversationsSub = database.watchPinnedConversations().listen((
      pinned,
    ) {
      if (!mounted) return;
      setState(() => _pinnedConversations = pinned);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _checkStoragePermission(promptIfMissing: true);
      if (mounted) {
        await _refreshA11yState(triggerToast: true);
      }
      unawaited(InstalledAppsService.instance.initAndRefresh());
    });
  }

  LlmClient _createLlmClient(String model) {
    final settings = AppSettingsService.instance;
    final provider = settings.activeProvider;
    final apiKey = provider.id == ProviderPresetType.openRouter.id
        ? (provider.apiKey ?? settings.openRouterKey ?? '')
        : (provider.apiKey ?? '');
    return LlmClient(
      config: LlmConfig(
        baseUrl: provider.baseUrl.isNotEmpty
            ? provider.baseUrl
            : provider.defaultBaseUrl,
        apiKey: apiKey,
        model: model,
      ),
    );
  }

  String _pickDefaultModelForProvider(
    LlmProvider provider,
    List<ModelOption> availableModels,
  ) {
    if (availableModels.isEmpty) {
      return 'gpt-4o';
    }

    final isOpenRouter = provider.id == ProviderPresetType.openRouter.id ||
        provider.baseUrl.contains('openrouter.ai');

    if (isOpenRouter) {
      final freeRouter = availableModels.cast<ModelOption?>().firstWhere(
        (m) =>
            m != null &&
            (m.id == 'openrouter/free' ||
                m.id == 'openrouter/auto' ||
                m.id.toLowerCase().contains('openrouter/free') ||
                m.name.toLowerCase().contains('free models router')),
        orElse: () => null,
      );
      if (freeRouter != null) return freeRouter.id;
      return availableModels.first.id;
    }

    final freeModel = availableModels.cast<ModelOption?>().firstWhere(
      (m) {
        if (m == null) return false;
        final id = m.id.toLowerCase();
        final name = m.name.toLowerCase();
        return id.startsWith('free') ||
            id.endsWith('-free') ||
            id.endsWith(':free') ||
            id.contains('free') ||
            name.contains('free');
      },
      orElse: () => null,
    );

    if (freeModel != null) return freeModel.id;
    return availableModels.first.id;
  }

  /// Loads runtime configuration (decrypted keys, last-selected model) from
  /// the settings store, then refreshes the model catalog. Replaces the old
  /// compile-time --dart-define env injection.
  Future<void> _loadAppConfig() async {
    await AppSettingsService.instance.ensureLoaded();
    if (!mounted) return;
    final settings = AppSettingsService.instance;
    final provider = settings.activeProvider;
    final cached = ModelCatalogService.getCachedModels(provider.baseUrl);
    final availableModels = (cached != null && cached.isNotEmpty)
        ? cached
        : provider.defaultModels;

    var model = settings.selectedModel;
    if (!availableModels.any((m) => m.id == model)) {
      model = _pickDefaultModelForProvider(provider, availableModels);
      unawaited(settings.setSelectedModel(model));
    }

    setState(() {
      _selectedModel = model;
      _activeConversation.model = model;
      _activeConversation.provider = provider.name;
      _models = availableModels;
      _llm.close();
      _llm = _createLlmClient(_selectedModel);
    });
    await _loadModelCatalog();
  }

  /// Opens the Settings sheet; returns true when something was saved.
  /// Reloads the LLM client + catalog afterwards so new keys take effect
  /// immediately.
  Future<bool> _openSettings() async {
    if (_busy) return false;
    // Local tab shows both history (conversation inventory) and pending.
    final allAttached = <String>[
      ..._activeConversation.attachedFileUris,
      for (final p in _pendingAttachments)
        if (!_activeConversation.attachedFileUris.contains(p)) p,
    ];
    final changed = await showSettingsSheet(
      context,
      attachedFiles: List<String>.from(allAttached),
      onAttachFiles: (paths) async {
        if (!mounted) return;
        setState(() {
          for (final p in paths) {
            if (!_pendingAttachments.contains(p) &&
                !_activeConversation.attachedFileUris.contains(p)) {
              _pendingAttachments.add(p);
            }
          }
        });
      },
      onDetachFile: (uri) {
        if (!mounted) return;
        // Pending takes precedence; otherwise remove from history.
        if (_pendingAttachments.contains(uri)) {
          setState(() => _pendingAttachments.remove(uri));
        } else {
          _detachFile(uri);
        }
      },
    );
    if (changed && mounted) {
      final activeProvider = AppSettingsService.instance.activeProvider;
      final cached = ModelCatalogService.getCachedModels(activeProvider.baseUrl);
      final availableModels = (cached != null && cached.isNotEmpty)
          ? cached
          : activeProvider.defaultModels;

      String modelToUse = _selectedModel;
      if (!availableModels.any((m) => m.id == _selectedModel)) {
        modelToUse = _pickDefaultModelForProvider(activeProvider, availableModels);
        unawaited(AppSettingsService.instance.setSelectedModel(modelToUse));
      }

      setState(() {
        _selectedModel = modelToUse;
        _activeConversation.model = modelToUse;
        _activeConversation.provider = activeProvider.name;
        _models = availableModels;
        _llm.close();
        _llm = _createLlmClient(modelToUse);
        _touchConversation();
      });
      _persistNow();
      unawaited(_loadModelCatalog(forceRefresh: false));
    }
    // The Tools tab can enable/disable screen access without flagging a
    // settings change — always re-read so the system-prompt cache can't go
    // stale for the whole session. Silent: the sheet already showed state.
    if (mounted) {
      await _refreshA11yState();
    }
    return changed;
  }

  void _selectModel(String model) {
    if (_busy || model == _selectedModel) return;
    _llm.close();
    _llm = _createLlmClient(model);
    unawaited(AppSettingsService.instance.setSelectedModel(model));
    final activeProvider = AppSettingsService.instance.activeProvider;
    final cached = ModelCatalogService.getCachedModels(activeProvider.baseUrl);
    setState(() {
      if (cached != null && cached.isNotEmpty && _models != cached) {
        _models = cached;
      }
      _selectedModel = model;
      _activeConversation.model = model;
      _activeConversation.provider = _providerForModel(model) ?? activeProvider.name;
      _touchConversation();
    });
    _persistNow();
  }

  Future<List<ModelOption>> _selectProvider(LlmProvider provider) async {
    await AppSettingsService.instance.setActiveProvider(provider.id);
    final cached = ModelCatalogService.getCachedModels(provider.baseUrl);
    final availableModels = (cached != null && cached.isNotEmpty)
        ? cached
        : provider.defaultModels;
    final modelToUse = _pickDefaultModelForProvider(provider, availableModels);

    _llm.close();
    _llm = _createLlmClient(modelToUse);
    unawaited(AppSettingsService.instance.setSelectedModel(modelToUse));

    setState(() {
      _selectedModel = modelToUse;
      _activeConversation.model = modelToUse;
      _activeConversation.provider = provider.name;
      _models = availableModels;
      _touchConversation();
    });
    _persistNow();

    final hasKey = provider.id == ProviderPresetType.openRouter.id
        ? (provider.hasKey || AppSettingsService.instance.hasOpenRouterKey)
        : provider.hasKey;

    if (hasKey) {
      await _loadModelCatalog(forceRefresh: false);
    }
    return _models;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _workingFlushTimer?.cancel();
    _workingElapsedTimer?.cancel();
    _a11yToastTimer?.cancel();
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
      // while we were backgrounded. Toast only on a true→false flip (freshly
      // disabled) — a steady-off resume stays silent instead of re-nagging.
      unawaited(_refreshA11yState().then((flippedToOff) {
        if (flippedToOff) _triggerA11yToast();
      }));
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _persistNow();
    }
  }

  /// Cached screen-access availability for the system prompt. Refreshed on
  /// start, every resume, and after the Settings sheet — cheap channel calls,
  /// avoids making _systemPromptFor async. Returns true when the service
  /// flipped from available to unavailable.
  Future<bool> _refreshA11yState({bool triggerToast = false}) async {
    try {
      final supported = await _a11yService.isSupported();
      if (!mounted) return false;
      if (!supported) {
        if (_a11ySupported || _a11yAvailable || _showA11yToast) {
          setState(() {
            _a11ySupported = false;
            _a11yAvailable = false;
            _showA11yToast = false;
          });
        }
        return false;
      }
      final enabled = await _a11yService.isEnabled();
      final restricted = enabled ? false : await _a11yService.isRestricted();
      if (!mounted) return false;
      final flippedToOff = _a11yAvailable && !enabled;
      if (enabled != _a11yAvailable ||
          restricted != _a11yRestricted ||
          !_a11ySupported) {
        setState(() {
          _a11ySupported = true;
          _a11yAvailable = enabled;
          _a11yRestricted = restricted;
        });
      }
      if (enabled) {
        _dismissA11yToast();
        // Flow completed — a past dismissal must not mute future off-cycles.
        unawaited(AppSettingsService.instance.setA11yPromptDismissed(false));
      } else if (triggerToast) {
        _triggerA11yToast();
      }
      return flippedToOff;
    } catch (_) {
      return false;
    }
  }

  void _triggerA11yToast() {
    if (!mounted || !_a11ySupported || _a11yAvailable || _showA11yToast) return;
    // Mirror of the old one-time dialog: an explicit dismissal persists, so
    // cold starts don't nag forever. Fail-open when settings are unavailable.
    AppSettingsService.instance.a11yPromptDismissed().then((dismissed) {
      if (dismissed) return;
      if (!mounted || !_a11ySupported || _a11yAvailable || _showA11yToast) return;
      setState(() => _showA11yToast = true);
      _a11yToastTimer?.cancel();
      _a11yToastTimer = Timer(const Duration(seconds: 8), () {
        if (mounted && _showA11yToast) {
          setState(() => _showA11yToast = false);
        }
      });
    }).catchError((_) {
      if (!mounted || !_a11ySupported || _a11yAvailable || _showA11yToast) return;
      setState(() => _showA11yToast = true);
    });
  }

  void _dismissA11yToast({bool persist = false}) {
    _a11yToastTimer?.cancel();
    _a11yToastTimer = null;
    if (persist) {
      unawaited(AppSettingsService.instance.setA11yPromptDismissed(true));
    }
    if (_showA11yToast && mounted) {
      setState(() => _showA11yToast = false);
    }
  }

  Future<void> _checkStoragePermission({required bool promptIfMissing}) async {
    final permitted = await Workspace.instance.hasPermission();
    if (!mounted) return;
    if (!permitted && promptIfMissing) {
      await _showStoragePermissionDialog();
    }
  }

  Future<void> _loadModelCatalog({bool forceRefresh = false}) async {
    final settings = AppSettingsService.instance;
    final provider = settings.activeProvider;
    final hasKey = provider.id == ProviderPresetType.openRouter.id
        ? (provider.hasKey || settings.hasOpenRouterKey)
        : provider.hasKey;

    if (!hasKey) {
      if (mounted) {
        setState(() {
          _models = provider.defaultModels;
        });
      }
      return;
    }

    try {
      final apiKey = provider.id == ProviderPresetType.openRouter.id
          ? (provider.apiKey ?? settings.openRouterKey ?? '')
          : (provider.apiKey ?? '');
      final models = await _modelCatalog.load(
        baseUrl: provider.baseUrl.isNotEmpty
            ? provider.baseUrl
            : provider.defaultBaseUrl,
        apiKey: apiKey,
        defaultProvider: provider.name,
        isOpenRouter: provider.id == ProviderPresetType.openRouter.id ||
            provider.baseUrl.contains('openrouter.ai'),
        forceRefresh: forceRefresh,
      );
      if (!mounted) return;

      setState(() {
        _models = [
          ...models,
          if (!models.any((model) => model.id == _selectedModel))
            ModelOption(
              id: _selectedModel,
              name: _selectedModel,
              provider: provider.name,
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

  // -- Attachments (P3, storage-only for now) -------------------------------
  //
  // Attached file URIs live on the Conversation and persist via the existing
  // conversation_attachments table. Sending them as multimodal content parts
  // is the next step — today they're context for the agent's read tool.

  Future<void> _attachFiles() async {
    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles(allowMultiple: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              'Could not open picker: $e',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      return;
    }
    final paths = picked?.paths.whereType<String>().toList() ?? const [];
    if (paths.isEmpty || !mounted) return;

    setState(() {
      for (final p in paths) {
        if (!_pendingAttachments.contains(p) &&
            !_activeConversation.attachedFileUris.contains(p)) {
          _pendingAttachments.add(p);
        }
      }
    });
  }

  void _detachFile(String uri) {
    setState(() => _activeConversation.attachedFileUris.remove(uri));
    _schedulePersist();
  }

  void _detachPending(String uri) {
    setState(() => _pendingAttachments.remove(uri));
  }

  Widget _buildPendingAttachments() {
    final uris = _pendingAttachments;
    return Material(
      color: kInputBg,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
        decoration: BoxDecoration(
          color: kDarkBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kBorder),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.attach_file_rounded, size: 13, color: kMuted),
                const SizedBox(width: 6),
                Text('Attached — will send with next message',
                    style: const TextStyle(color: kMuted, fontSize: 11)),
                const Spacer(),
                Text('${uris.length}', style: const TextStyle(color: kMuted, fontSize: 11)),
              ],
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < uris.length; i++)
              Padding(
                padding: EdgeInsets.only(bottom: i == uris.length - 1 ? 0 : 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${i + 1}. ${path.basename(uris[i])}',
                        style: const TextStyle(color: kText, fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    InkWell(
                      onTap: () => _detachPending(uris[i]),
                      borderRadius: BorderRadius.circular(10),
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(Icons.close_rounded, size: 14, color: kMuted),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showMoreActions() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kDarkBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: kBorder,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.attach_file_rounded, color: kText),
              title: const Text('Attach file', style: TextStyle(color: kText)),
              subtitle: const Text('Image, audio, video or document',
                  style: TextStyle(color: kMuted, fontSize: 12)),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _attachFiles();
              },
            ),
            // Future actions slot — add more ListTiles here.
            const SizedBox(height: 8),
          ],
        ),
      ),
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
    final cached = ModelCatalogService.getCachedModels(AppSettingsService.instance.activeProvider.baseUrl);
    if (cached != null) {
      for (final option in cached) {
        if (option.id == model) return option.provider;
      }
    }
    return AppSettingsService.instance.activeProvider.name;
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
    if (!_sortedConversationsDirty) {
      return _cachedSortedConversations;
    }
    final seen = <String>{};
    final unique = <Conversation>[
      for (final conversation in [..._conversations, ..._olderConversations])
        if (conversation.id != null && seen.add(conversation.id!))
          conversation,
    ];
    unique.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _cachedSortedConversations = unique;
    _sortedConversationsDirty = false;
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
        _sortedConversationsDirty = true;
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
    _pendingAttachments.clear();
    _workingDirectory.current = _workingDirectory.root;
    final welcome = _welcomeMessages();
    _animatedMessageIds.clear();
    _animatedMessageIds.addAll(welcome.map((m) => m.id));
    setState(() {
      _messages = welcome;
      _activeConversation = _newDraftConversation();
      _workingMessageId = null;
      _workingText.clear();
      _editingMessageId = null;
      _hasOlderMessages = false;
      _updateEstimatedTokens();
    });
    _closeSidebar();
    _scrollToBottom(animated: false, force: true);
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

    if (loaded.provider != null) {
      final match = AppSettingsService.instance.providers.firstWhere(
        (p) => p.name == loaded.provider || p.id == loaded.provider,
        orElse: () => AppSettingsService.instance.activeProvider,
      );
      await AppSettingsService.instance.setActiveProvider(match.id);
      if (!mounted) return;
    }

    _pendingAttachments.clear();
    _workingDirectory.current = loaded.currentDir;
    _animatedMessageIds.clear();
    _animatedMessageIds.addAll(loaded.messages.map((m) => m.id));
    setState(() {
      _activeConversation = loaded;
      _messages = loaded.messages;
      _selectedModel = loaded.model ?? AppSettingsService.instance.selectedModel;
      _llm.close();
      _llm = _createLlmClient(_selectedModel);
      _workingMessageId = null;
      _workingText.clear();
      _editingMessageId = null;
      // A short page means the whole history fit in the first window.
      _hasOlderMessages = loaded.messages.length == _messagePageSize;
      _messageFetcher.hasMore = true;
      _updateEstimatedTokens();
    });
    _closeSidebar();
    // Land on the newest message. The flag also suppresses the leading-edge
    // pager until we're actually at the bottom — otherwise sitting at the
    // top (pre-scroll) would cascade-load the whole history.
    _loadOlderSuppressed = true;
    _scrollToBottom(animated: false, force: true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _loadOlderSuppressed = false);
    });
  }

  /// Prepends the previous page of messages, keeping the viewport anchored
  /// on the same content (no visual jump).
  Future<void> _loadOlderMessages() async {
    final conversationId = _activeConversation.id;
    if (conversationId == null ||
        !_hasOlderMessages ||
        _loadOlderSuppressed ||
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
        _animatedMessageIds.addAll(older.map((m) => m.id));
        _messages = [...older, ..._messages];
        _updateEstimatedTokens();
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
      _sortedConversationsDirty = true;
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
      _sortedConversationsDirty = true;
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
      _sortedConversationsDirty = true;
    });
    if (_activeConversation.id == id) {
      _touchConversation();
    }
  }

  void _scrollToBottom({bool animated = true, bool force = false}) {
    if (_scrollPending) return;
    _scrollPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollPending = false;
      if (!_scroll.hasClients) return;
      final distance =
          _scroll.position.maxScrollExtent - _scroll.position.pixels;
      // "Force" jumps are for opening a fresh view (new chat / conversation):
      // they must land at the newest message no matter how far away it is.
      if (!animated && !force && distance > 160) return;
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

    // Preserve attachments from the message being edited (structured field
    // for new messages, or legacy text suffix for old ones) and merge with
    // any newly staged files.
    List<String> editBase = const [];
    if (_editingMessageId != null) {
      final idx = _messages.indexWhere((m) => m.id == _editingMessageId);
      if (idx != -1) {
        final original = _messages[idx];
        if (original is UserMessage && original.attachedUris.isNotEmpty) {
          editBase = List<String>.from(original.attachedUris);
        } else {
          editBase = _extractAttachedUris(original.text);
        }
      }
      await _truncateFrom(_editingMessageId!);
      _editingMessageId = null;
    }

    // Attached files are per-message structured data (card + LLM context).
    // Pending (staged) + editBase are snapshotted into the UserMessage,
    // then also appended to the conversation's global inventory so the
    // Local tab/history reflects them.
    final strippedText = _stripAttachedBlock(text);
    final pending = List<String>.from(_pendingAttachments);
    final attachedSnapshot = <String>[...editBase];
    for (final p in pending) {
      if (!attachedSnapshot.contains(p)) attachedSnapshot.add(p);
    }

    _startConversation(strippedText);
    setState(() {
      _messages.add(
        UserMessage(
          id: 'user-${DateTime.now().millisecondsSinceEpoch}',
          text: strippedText,
          attachedUris: attachedSnapshot,
        ),
      );
      _updateEstimatedTokens();
      if (attachedSnapshot.isNotEmpty) {
        // Keep the conversation's global inventory in sync.
        for (final p in attachedSnapshot) {
          if (!_activeConversation.attachedFileUris.contains(p)) {
            _activeConversation.attachedFileUris.add(p);
          }
        }
        _pendingAttachments.clear();
        _schedulePersist();
      }
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

  /// If the message at [index] is the final assistant bubble of a user-turn response
  /// (the end-of-response step), returns the owning user message id so a
  /// regenerate can be anchored to that turn; otherwise null.
  String? _regenerateTargetFor(int index) {
    if (index < 0 || index >= _messages.length) return null;
    final message = _messages[index];
    if (message is! AssistantMessage) return null;
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

  String _stripAttachedBlock(String text) {
    const marker = '\n\n[Attached files:\n';
    final idx = text.lastIndexOf(marker);
    if (idx == -1) return text;
    final tail = text.substring(idx);
    if (!tail.trim().endsWith(']')) return text;
    return text.substring(0, idx).trimRight();
  }

  List<String> _extractAttachedUris(String text) {
    const marker = '\n\n[Attached files:\n';
    final idx = text.lastIndexOf(marker);
    if (idx == -1) return const [];
    final tail = text.substring(idx + marker.length);
    final end = tail.lastIndexOf(']');
    if (end == -1) return const [];
    final block = tail.substring(0, end);
    final uris = <String>[];
    for (final line in block.split('\n')) {
      final sep = line.indexOf(' — ');
      if (sep != -1) {
        uris.add(line.substring(sep + 3).trim());
      }
    }
    return uris;
  }

  /// Tap on own bubble: load its text into the composer for editing.
  Future<void> _editUserMessage(UserMessage message) async {
    if (_busy) return;
    final currentDraft = _controller.text.trim();
    if (currentDraft.isNotEmpty && _editingMessageId != message.id) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Discard draft?'),
          content: const Text(
            'Editing this message will replace the text currently in the composer.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Discard & Edit'),
            ),
          ],
        ),
      );
      if (discard != true || !mounted) return;
    }
    setState(() {
      _editingMessageId = message.id;
      _controller.text = _stripAttachedBlock(message.text);
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
    setState(() {
      _messages.removeRange(index, _messages.length);
      _updateEstimatedTokens();
    });
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
    final settings = AppSettingsService.instance;
    final provider = settings.activeProvider;
    final hasKey = provider.id == ProviderPresetType.openRouter.id
        ? (provider.hasKey || settings.hasOpenRouterKey)
        : provider.hasKey;
    if (!hasKey) {
      final pName = provider.name;
      _showToast('Add an API key for $pName in Settings to start chatting.');
      await _openSettings();
      return;
    }

    final workingId = 'working-${DateTime.now().microsecondsSinceEpoch}';
    _workingMessageId = workingId;
    _workingText.clear();
    _workingReasoning = false;
    _externalAppWorkDone = false;
    _externalIntentLaunched = false;
    _cancelToken.reset();
    setState(() {
      _messages.add(AssistantMessage(
        id: workingId,
        text: '…working',
        model: _selectedModel,
        provider: _activeConversation.provider ?? settings.activeProvider.name,
      ));
      _busy = true;
    });
    // Foreground service: keeps the process non-cached (and its sockets
    // alive) even when an intent tool sends Errand to the background.
    unawaited(_intentService.startWorkIndicator());
    _startWorkingElapsedTimer();
    _persistNow();
    _scrollToBottom();

    try {
      final conversation = Conversation(
        id: _activeConversation.id,
        localSystemPrompt: _systemPromptFor(
          _workingDirectory.current,
          screenAccess: _a11yAvailable,
          screenRestricted: _a11yRestricted,
          a11ySupported: _a11ySupported,
        ),
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

      final registry = ToolRegistry.defaults(
        currentDir: _workingDirectory.root,
        workingDirectory: _workingDirectory,
        supportsInput: (modality) =>
            // null = unknown → allow the attempt; only positive knowledge
            // of "no image/audio/video support" gates the read.
            // Pass normalized baseUrl to hit O(n) single-catalog path.
            ModelCatalogService.supportsInput(
              _selectedModel,
              modality,
              baseUrl: AppSettingsService.instance.effectiveBaseUrl,
            ) !=
            false,
        getAttachedFiles: () => _activeConversation.attachedFileUris,
        hasTavilyKey: AppSettingsService.instance.hasTavilyKey,
        enableA11yTools: _a11ySupported,
      );

      final budget = _getActiveBudget();

      final loop = AgentLoop(
        llm: _llm,
        registry: registry,
        budget: budget,
        systemPromptBuilder: () => _systemPromptFor(
          _workingDirectory.current,
          screenAccess: _a11yAvailable,
          screenRestricted: _a11yRestricted,
          a11ySupported: _a11ySupported,
        ),
        cancelToken: _cancelToken,
        onEvent: _handleEvent,
        onTextDelta: _handleTextDelta,
        onReasoningDelta: _handleReasoningDelta,
      );
      try {
        final answer = await loop.run(conversation);
        _replaceWorking(answer);
      } finally {
        registry.dispose();
      }
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

  /// Elapsed-seconds ticker for the …working/…thinking placeholder: slow
  /// models spend 30–90s before the first token, and a static placeholder is
  /// indistinguishable from a hung request. The ticker is the ONLY writer of
  /// the elapsed suffix; [_handleReasoningDelta] just flips the label flag.
  /// Stops updating once real text deltas arrive (streamed content takes
  /// over the bubble).
  void _startWorkingElapsedTimer() {
    _workingElapsedTimer?.cancel();
    _workingElapsedSeconds = 0;
    _workingElapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _workingMessageId == null) return;
      if (_workingText.isNotEmpty) return; // streamed text owns the bubble now
      _workingElapsedSeconds++;
      _updateWorkingPlaceholder();
    });
  }

  /// Single writer for the …working/…thinking placeholder. Every other
  /// state change (reasoning start, new turn) goes through here, so the
  /// label and the elapsed suffix can never be written out of sync.
  void _updateWorkingPlaceholder() {
    final id = _workingMessageId;
    if (id == null || _workingText.isNotEmpty) return;
    final index = _messages.indexWhere((message) => message.id == id);
    if (index == -1) return;
    final String label;
    if (_workingCompacting) {
      label = '…compacting context';
    } else if (_workingReasoning) {
      label = '…thinking';
    } else {
      label = '…working';
    }
    setState(() {
      _messages[index] = AssistantMessage(
        id: id,
        text: '$label · ${_workingElapsedSeconds}s',
        model: _selectedModel,
        provider: _activeConversation.provider ??
            AppSettingsService.instance.activeProvider.name,
      );
    });
  }

  /// Removes the working placeholder and surfaces [message] as a snackbar.
  /// Used for infra-level failures that must not enter model context.
  void _failWorking(String message) {
    _workingFlushTimer?.cancel();
    _workingFlushTimer = null;
    _workingElapsedTimer?.cancel();
    _workingCompacting = false;
    unawaited(_intentService.stopWorkIndicator());
    if (_externalAppWorkDone || _externalIntentLaunched) {
      unawaited(_intentService.bringToFront());
    }
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
      _updateEstimatedTokens();
    });
    // OPT-07: saves merge by message id now, so a working bubble that was
    // already persisted mid-stream must be removed from the DB explicitly.
    final conversationId = _activeConversation.id;
    if (conversationId != null && id != null) {
      unawaited(database.deleteMessage(conversationId, id));
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            message,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
  }

  void _handleEvent(AgentEvent event) {
    switch (event) {
      case AgentCompacting():
        _workingCompacting = true;
        _updateWorkingPlaceholder();
      case AgentCompacted(:final summary, :final tailBlockCount):
        _workingCompacting = false;
        _handleCompacted(summary, tailBlockCount: tailBlockCount);
        _updateWorkingPlaceholder();
      case AgentToolCall(
        call: final call,
        result: final result,
        reasoning: final reasoning,
        reasoningDetails: final reasoningDetails,
      ):
        _workingCompacting = false;
        if (call.name == 'screen' || call.name == 'act') {
          _externalAppWorkDone = true;
        } else if (call.name == 'intent') {
          _externalIntentLaunched = true;
        }
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

  void _handleCompacted(String summary, {int tailBlockCount = 0}) {
    if (!mounted) return;

    final beforeTokens = estimateHistoryTokens(_messages);

    late int tailTokens;

    setState(() {
      final workingId = _workingMessageId;
      AssistantMessage? workingMsg;
      if (workingId != null) {
        final workingIdx = _messages.indexWhere((m) => m.id == workingId);
        if (workingIdx != -1) {
          final m = _messages[workingIdx];
          if (m is AssistantMessage) {
            workingMsg = m;
          }
        }
      }

      final currentHistory = _messages
          .where((m) => m.id != workingId)
          .toList(growable: false);

      final blocks = groupHistoryIntoBlocks(currentHistory);
      final keepCount = tailBlockCount.clamp(1, blocks.length);
      final compactedBlocks = blocks.sublist(0, blocks.length - keepCount);
      final keptTailBlocks = blocks.sublist(blocks.length - keepCount);

      tailTokens = estimateHistoryTokens([
        for (final block in keptTailBlocks) ...block,
      ]);

      final divider = CompactedNoticeMessage(
        id: _uuid.v4(),
        text: 'compacted',
        summary: summary,
        beforeTokens: beforeTokens,
        afterTokens: tailTokens,
      );

      _messages = <Message>[
        for (final block in compactedBlocks) ...block,
        divider,
        for (final block in keptTailBlocks) ...block,
        ?workingMsg,
      ];

      _updateEstimatedTokens();
      _touchConversation();
    });

    _persistNow();

    if (mounted) {
      _showToast(
        'Context compacted: ${_formatTokens(beforeTokens)} → ${_formatTokens(tailTokens)} tokens',
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
      _workingReasoning = false; // next step starts as …working again
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
      const Duration(milliseconds: 65),
      _flushWorkingText,
    );
  }

  void _handleReasoningDelta() {
    if (!mounted || _workingMessageId == null || _workingText.isNotEmpty) {
      return;
    }
    // Flip the label once; the 1s ticker owns the elapsed suffix from here.
    // Writing the bubble per-delta used to fight the ticker's
    // '…working · Ns' write and made the placeholder flicker.
    if (_workingReasoning) return;
    _workingReasoning = true;
    _updateWorkingPlaceholder();
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
        model: _selectedModel,
        provider: _activeConversation.provider ??
            AppSettingsService.instance.activeProvider.name,
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
    _workingCompacting = false;
    unawaited(_intentService.stopWorkIndicator());
    final trimmed = text.trim();
    if (_externalAppWorkDone || (_externalIntentLaunched && trimmed.isNotEmpty)) {
      unawaited(_intentService.bringToFront());
    }
    final id = _workingMessageId;
    _workingText.clear();
    if (!mounted) return;
    // Some models return an empty/whitespace final answer (content-only
    // tool turns, stray "\n"). Trim it; if nothing is left, drop the
    // bubble instead of rendering an empty one.
    if (trimmed.isEmpty) {
      _showToast('Model produced no response.');
    }
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
          model: _selectedModel,
          provider: _activeConversation.provider ??
              AppSettingsService.instance.activeProvider.name,
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
      _updateEstimatedTokens();
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
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            message,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
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
    return PopScope(
      canPop: !_sidebarOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _sidebarOpen) {
          _closeSidebar();
        }
      },
      child: Scaffold(
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
                    if (_pendingAttachments.isNotEmpty) _buildPendingAttachments(),
                    if (_editingMessageId != null) _buildEditingBanner(),
                    _buildComposer(),
                  ],
                ),
              ),
              _buildA11yToastOverlay(),
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
              providerName: AppSettingsService.instance.activeProvider.name,
              providers: AppSettingsService.instance.providers,
              activeProvider: AppSettingsService.instance.activeProvider,
              onProviderChanged: _selectProvider,
              onManageProviders: _openSettings,
              onRefresh: () => _loadModelCatalog(forceRefresh: true),
              onChanged: _selectModel,
            ),
          ),
          IconButton(
            onPressed: _busy ? null : _openSettings,
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_rounded, size: 20),
            color: kMuted,
            visualDensity: VisualDensity.compact,
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

  Widget _buildA11yToastOverlay() {
    // Hidden state is already zero-size (SizedBox.shrink child) — the
    // IgnorePointer only guards the fade window. No early return here so
    // the slide-out exit animation can play on dismiss.
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: IgnorePointer(
        ignoring: !_showA11yToast,
        child: SafeArea(
          child: AnimatedSlide(
            offset: _showA11yToast ? Offset.zero : const Offset(0, -1.2),
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
            child: AnimatedOpacity(
              opacity: _showA11yToast ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 250),
              child: _showA11yToast
                  ? Container(
                      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E212B),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: kBorder.withValues(alpha: 0.9),
                          width: 1,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.5),
                            blurRadius: 18,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: kBubbleAssistant,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(
                                Icons.settings_accessibility_rounded,
                                size: 16,
                                color: kText,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _a11yRestricted
                                        ? 'Screen access is blocked'
                                        : 'Screen access is paused',
                                    style: const TextStyle(
                                      color: kText,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    _a11yRestricted
                                        ? 'Android blocks Errand ("Restricted setting"). Fix: Settings > Apps > Errand > ⋮ > Allow restricted settings, then enable in Accessibility.'
                                        : 'It pauses when Errand closes. Turn it on to let Errand view or control apps.',
                                    style: const TextStyle(
                                      color: kMuted,
                                      fontSize: 12,
                                      height: 1.3,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              onPressed: () =>
                                  _dismissA11yToast(persist: true),
                              icon: const Icon(Icons.close_rounded,
                                  size: 16, color: kMuted),
                              tooltip: 'Dismiss',
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              visualDensity: VisualDensity.compact,
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerRight,
                          child: FilledButton(
                            onPressed: () {
                              _dismissA11yToast();
                              unawaited(_a11yService.openSettings());
                            },
                            style: FilledButton.styleFrom(
                              backgroundColor: kBubbleUser,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 6),
                              minimumSize: const Size(0, 30),
                              tapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            child: const Text('Enable',
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600)),
                          ),
                        ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ),
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
          final shouldAnimate = !_animatedMessageIds.contains(message.id);
          if (shouldAnimate) {
            _animatedMessageIds.add(message.id);
          }

          final Widget bubbleWidget;
          if (message is CompactedNoticeMessage) {
            bubbleWidget = CompactedDividerBubble(
              key: ValueKey(message.id),
              message: message,
            );
          } else if (message is ToolMessage) {
            bubbleWidget = ToolMessageBubble(
              key: ValueKey(message.id),
              message: message,
            );
          } else {
            // Regenerate sits on the LAST assistant bubble of each user-turn
            // response (the end-of-response step), not just the literal last
            // message of the conversation. Regenerating an older turn also
            // drops every later turn — same semantics as edit-resend.
            final regenerateUserId = !_busy
                ? _regenerateTargetFor(index)
                : null;
            bubbleWidget = MessageBubble(
              key: ValueKey(message.id),
              message: message,
              onEdit:
                  message is UserMessage ? () => _editUserMessage(message) : null,
              onRegenerate: regenerateUserId == null
                  ? null
                  : () => _regenerate(regenerateUserId),
            );
          }

          return SubtleFadeIn(
            key: ValueKey('fade_${message.id}'),
            animate: shouldAnimate,
            child: bubbleWidget,
          );
        },
      ),
      ),
    );
  }

  String _formatTokens(int tokens) {
    if (tokens >= 1000000) {
      final m = tokens / 1000000;
      return m % 1 == 0 ? '${m.round()}M' : '${m.toStringAsFixed(1)}M';
    }
    if (tokens >= 1000) {
      final k = tokens / 1000;
      return k % 1 == 0 ? '${k.round()}k' : '${k.toStringAsFixed(1)}k';
    }
    return '$tokens';
  }

  /// Displays the current active token usage vs. the dynamic compaction threshold.
  Widget _buildContextFooter() {
    final budget = _getActiveBudget();
    final threshold = budget.compactionThreshold;
    final activeTokens = _estimatedActiveTokens;

    final isNearOrOver = activeTokens >= threshold;
    final hasCompacted = _messages.any(
      (m) =>
          m is CompactedNoticeMessage ||
          (m is UserMessage &&
              (m.text.startsWith(kCompactedContextMarker) ||
                  m.text.startsWith('[Compacted Conversation History'))),
    );

    final statusSuffix = isNearOrOver
        ? ' · compacts next'
        : hasCompacted
            ? ' · compacted'
            : '';

    return Material(
      color: kInputBg,
      child: Tooltip(
        message:
            'Context: $activeTokens / $threshold tokens (native max: ${_formatTokens(budget.contextSize)})',
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
          child: Text(
            'ctx ${_formatTokens(activeTokens)}/${_formatTokens(threshold)} · ${_messages.length} msgs$statusSuffix',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: isNearOrOver ? const Color(0xFFF59E0B) : kMuted,
              fontSize: 10,
              fontWeight: isNearOrOver ? FontWeight.w600 : FontWeight.normal,
            ),
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
