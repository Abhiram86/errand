import 'dart:async';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../agent/agent_loop.dart';
import '../agent/context_budget.dart';
import '../agent/system_prompt.dart';
import '../agent/tool_registry.dart';
import '../llm/llm_client.dart';
import '../models/app_update_info.dart';
import '../models/llm_provider.dart';
import '../models/model_option.dart';
import '../services/a11y_service.dart';
import '../services/app_info_service.dart';
import '../services/app_settings.dart';
import '../services/database.dart';
import '../services/installed_apps_service.dart';
import '../services/intent_service.dart';
import '../services/location_service.dart';
import '../services/model_catalog.dart';
import '../services/models_dev_service.dart';
import '../services/speech_service.dart';
import '../services/task_scheduler_service.dart';
import '../services/update_service.dart';
import '../services/widget_service.dart';
import '../services/streaming_assistant_service.dart';
import '../services/workspace.dart';
import '../theme/app_colors.dart';
import '../tools/file_tools.dart';
import '../types/conversation.dart';
import '../types/message.dart';
import '../widgets/a11y_toast_overlay.dart';
import '../widgets/browser_widget.dart';
import '../widgets/chat_composer.dart';
import '../services/shell_service.dart';
import '../widgets/chat_sidebar.dart';
import '../widgets/command_confirmation_banner.dart';
import '../widgets/context_footer.dart';
import '../widgets/message_bubbles.dart';
import '../widgets/model_picker.dart';
import '../widgets/options_modal_sheet.dart';
import '../widgets/paging.dart';
import '../widgets/pending_attachments_banner.dart';
import '../utils/coalescing_writer.dart';
import '../widgets/settings_sheet.dart';
import '../widgets/update_toast.dart';

final database = ErrandDatabase.instance;

class PendingConfirmation {
  final String title;
  final String command;
  final String? reason;
  final Completer<ConfirmationDecision> completer;

  PendingConfirmation({
    required this.title,
    required this.command,
    this.reason,
    required this.completer,
  });
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
  final _composerFocusNode = FocusNode();
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

  /// Re-entrancy latch for [_runAgentTurn].
  ///
  /// `_busy` alone is not enough: callers such as [_regenerate] check it, then
  /// `await` real async work (message deletion in [_truncateFrom]) before
  /// reaching [_runAgentTurn], and `_busy` is not set until this method's own
  /// `setState` runs. Two taps in that window both pass the caller's guard and
  /// would start two concurrent [AgentLoop]s against the same `_messages` and
  /// `_cancelToken` — two streams writing one working-message id, two final
  /// answers, last write wins. This flag is set synchronously before any await.
  bool _turnInFlight = false;
  String? _workingMessageId;
  DateTime _sessionStartTime = DateTime.now();

  /// Set by the composer stop button; checked between SSE events and at
  /// agent-loop turn boundaries.
  final CancelToken _cancelToken = CancelToken();

  /// When set, the next send replaces this user message (and everything
  /// after it) instead of appending — the edit-resend flow.
  String? _editingMessageId;
  late final StreamingAssistantService _streamingService =
      StreamingAssistantService(onUpdate: _handleStreamingUpdate);

  void _handleStreamingUpdate(StreamingSnapshot snapshot) {
    if (!mounted || _workingMessageId == null) return;
    final id = _workingMessageId!;
    final index = _messages.indexWhere((m) => m.id == id);
    if (index == -1) return;

    setState(() {
      if (!snapshot.hasContent) {
        _messages[index] = AssistantMessage(
          id: id,
          text: snapshot.placeholderLabel,
          model: _selectedModel,
          provider: _activeConversation.provider ??
              AppSettingsService.instance.activeProvider.name,
        );
      } else {
        _messages[index] = AssistantMessage(
          id: id,
          text: snapshot.fullPristineText,
          model: _selectedModel,
          provider: _activeConversation.provider ??
              AppSettingsService.instance.activeProvider.name,
        );
        _touchConversation();
      }
    });

    if (snapshot.hasContent) {
      _schedulePersist();
      _scrollToBottom(animated: true);
    }
  }

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
      overrideThreshold: _debugCompactionThreshold > 0
          ? _debugCompactionThreshold
          : null,
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
  StreamSubscription<void>? _widgetVoiceSub;
  Timer? _persistTimer;
  String? _pendingPersistConversationId;
  final CoalescingWriter _persistWriter = CoalescingWriter();

  /// Session-owned structured-document cache, injected into every turn's
  /// [ToolRegistry].
  ///
  /// Previously each turn built its own `DocumentLruCache` and tore it down on
  /// `registry.dispose()`, so the in-flight dedup and the 64MB/16-entry bounds
  /// only ever applied within a single turn. Any PDF or Office file read on one
  /// turn was fully re-opened — including re-creating the native PDDocument — on
  /// the next, and a multi-turn document task re-parsed every turn. Owned here
  /// so the bounds mean something across the conversation, and disposed once.
  final DocumentLruCache _documentCache = DocumentLruCache();
  Completer<void>? _appConfigCoreReady;
  Future<void>? _loadAppConfigFuture;
  int _estimatedActiveTokens = 0;
  List<Conversation> _cachedSortedConversations = [];
  bool _sortedConversationsDirty = true;
  final Set<String> _animatedMessageIds = <String>{};
  final GlobalKey _composerKey = GlobalKey();

  /// In-memory store of conversation IDs trusted for destructive operations.
  /// Kept strictly in RAM for the current session; never persisted to SQLite.
  final Set<String> _sessionTrustedConversations = {};
  PendingConfirmation? _pendingConfirmation;

  bool _isCurrentSessionTrusted() {
    final activeId = _activeConversation.id;
    if (activeId == null) return false;
    return _sessionTrustedConversations.contains(activeId);
  }

  Future<ConfirmationDecision> _handleConfirmCommand({
    required String title,
    required String command,
    String? reason,
  }) async {
    final activeId = _activeConversation.id;
    if (activeId != null && _sessionTrustedConversations.contains(activeId)) {
      return ConfirmationDecision.trust;
    }

    final completer = Completer<ConfirmationDecision>();
    setState(() {
      _pendingConfirmation = PendingConfirmation(
        title: title,
        command: command,
        reason: reason,
        completer: completer,
      );
    });

    try {
      final decision = await completer.future;
      if (decision == ConfirmationDecision.trust && activeId != null) {
        _sessionTrustedConversations.add(activeId);
      }
      return decision;
    } finally {
      if (mounted) {
        setState(() {
          _pendingConfirmation = null;
        });
      }
    }
  }

  void _resolvePendingConfirmation(ConfirmationDecision decision) {
    if (_pendingConfirmation != null &&
        !_pendingConfirmation!.completer.isCompleted) {
      _pendingConfirmation!.completer.complete(decision);
    }
  }

  void _updateEstimatedTokens() {
    final lastCompactedIdx = _messages.lastIndexWhere(
      (m) => m is CompactedNoticeMessage,
    );
    final activeMessages = lastCompactedIdx != -1
        ? _messages.sublist(lastCompactedIdx)
        : _messages;
    _estimatedActiveTokens = estimateHistoryTokens(activeMessages);
  }

  final WorkingDirectory _workingDirectory = WorkingDirectory(
    Workspace.instance.root,
    current: Workspace.instance.defaultDir,
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
    final bootSettings = AppSettingsService.instance;
    _selectedModel = bootSettings.selectedModelFor(
      bootSettings.activeProviderId,
    );
    _activeConversation = _newDraftConversation();
    _llm = _createLlmClient(_selectedModel);
    _animatedMessageIds.addAll(_messages.map((m) => m.id));
    _updateEstimatedTokens();
    ModelsDevService.preload();
    _loadAppConfigFuture = _loadAppConfig();
    unawaited(Workspace.instance.ensureDefaultDirectories());
    // Startup location warm-up; never let a permission/store failure
    // surface as an unhandled async error.
    unawaited(() async {
      try {
        if (await LocationService.instance.hasPermission()) {
          await LocationService.instance.getLocation(requestIfMissing: false);
        }
      } catch (_) {}
    }());
    // One-time POST_NOTIFICATIONS grant so the foreground work indicator is
    // visible on API 33+ (the service itself runs regardless).
    unawaited(_intentService.requestNotificationPermission());
    WidgetsBinding.instance.addObserver(this);
    // Keep the sidebar in sync with everything that was persisted across
    // app restarts as well as any conversation we save while running.
    _conversationsSub = database
        .watchConversationSummaries(limit: _sidebarPageSize)
        .listen((summaries) {
          if (!mounted) return;
          _conversations = summaries;
          _sortedConversationsDirty = true;
          // The sidebar reads these fields on open; skip the full-screen
          // rebuild while it is closed (persists fire ~every 600ms mid-turn).
          if (_sidebarOpen) setState(() {});
        });
    _pinnedConversationsSub = database.watchPinnedConversations().listen((
      pinned,
    ) {
      if (!mounted) return;
      _pinnedConversations = pinned;
      // Pinned rows render inside the sidebar only; same skip-while-closed.
      if (_sidebarOpen) setState(() {});
    });

    WidgetService.instance.initialize();
    _widgetVoiceSub = WidgetService.instance.onVoicePrompt.listen((_) {
      if (!mounted) return;
      _startVoicePrompt();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _checkStoragePermission(promptIfMissing: true);
      if (mounted) {
        await _refreshA11yState(triggerToast: true);
      }
      if (mounted) {
        await UpdateService.instance.initialize();
        if (mounted) {
          await _maybeShowUpdateDisclosure();
          await _checkReleaseNotes();
        }
      }
      if (mounted) {
        final triggerVoice =
            await WidgetService.instance.consumeInitialVoicePrompt();
        if (triggerVoice && mounted) {
          _startVoicePrompt();
        } else if (mounted) {
          // Cold-open autofocus: request focus on the composer after the first
          // frame and open the software keyboard so the user can type immediately.
          // Gated to cold start only — resume from background never re-focuses.
          Future.delayed(const Duration(milliseconds: 150), () {
            if (mounted && _composerFocusNode.canRequestFocus) {
              _composerFocusNode.requestFocus();
              SystemChannels.textInput.invokeMethod('TextInput.show');
            }
          });
        }
      }
      unawaited(InstalledAppsService.instance.initAndRefresh());
    });
  }

  /// One-time opt-in for in-app update prompts, shown before the app
  /// ever surfaces an update prompt.
  ///
  /// F-Droid's Inclusion Policy \u00a75 permits an in-app updater provided the
  /// download is an explicit opt-in act, and an F-Droid maintainer asks
  /// (fdroiddata#3113) that the user additionally be *informed* that in-app
  /// updating exists before it acts, defaulting to declining. This dialog is
  /// both: bullet points, no paragraphs, and two buttons. Approve keeps
  /// prompts on; Deny (or dismissing) permanently opts out via
  /// `neverAskAgain` \u2014 re-enable anytime from Settings, or check manually
  /// with the sidebar's Check-for-updates icon. Nothing is ever downloaded
  /// unless Update is tapped.
  ///
  /// Only shown once ever; the pref lives in the database alongside the rest of
  /// the update state so it survives reinstalls-without-data-clear.
  Future<void> _maybeShowUpdateDisclosure() async {
    final service = UpdateService.instance;
    if (service.hasBeenInformed) return;
    // Never stack on top of the storage or release-notes dialogs.
    if (!mounted) return;
    bool approved = false;
    try {
      final choice = await showDialog<bool>(
        context: context,
        builder: (dialogCtx) => AlertDialog(
          backgroundColor: const Color(0xFF1E222B),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          title: const Text(
            'Updates',
            style: TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
          content: const Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _UpdateDisclosurePoint(
                text: 'Errand checks GitHub for new releases.',
              ),
              _UpdateDisclosurePoint(
                text: 'Nothing is ever downloaded unless you tap Update.',
              ),
              _UpdateDisclosurePoint(
                text:
                    'No conversations, keys, or usage are ever sent anywhere for this.',
              ),
              _UpdateDisclosurePoint(
                text:
                    'Installing it yourself means leaving your app store or F-Droid updates for this install.',
              ),
              _UpdateDisclosurePoint(
                text:
                    'You can always check manually with the Check-for-updates icon in the sidebar.',
              ),
            ],
          ),
          actions: [
            OutlinedButton(
              onPressed: () => Navigator.of(dialogCtx).pop(false),
              style: OutlinedButton.styleFrom(
                foregroundColor: kMuted,
                side: const BorderSide(color: kMuted),
              ),
              child: const Text(
                'Deny',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogCtx).pop(true),
              child: const Text(
                'Approve',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      );
      // Dismissing (back button / tap-outside) counts as declining: the
      // F-Droid guidance defaults to opt-out, and approval must be explicit.
      approved = choice ?? false;
    } catch (_) {
      // A dialog during teardown is not worth surfacing to the user.
      return;
    }
    // Marked after the dialog, not before: if teardown wins the race and the
    // dialog never displays, the user was never actually informed.
    if (!mounted) return;
    await service.markInformed();
    if (!approved) {
      await service.setNeverAskAgain(true);
    }
  }

  Future<void> _checkReleaseNotes({bool force = false}) async {
    try {
      List<String>? notes;
      String? versionName;
      if (force) {
        final cached = await UpdateService.instance.loadPersistedInfo();
        final platformInfo = await AppInfoService.instance.getAppInfo();
        versionName = platformInfo.versionName;
        String? body;
        if (cached != null &&
            AppUpdateInfo.compareSemver(
                  cached.latestVersion,
                  platformInfo.versionName,
                ) ==
                0) {
          body = cached.releaseNotes;
        }
        if (body == null || body.trim().isEmpty) {
          body = await UpdateService.instance.fetchReleaseNotes(
            platformInfo.versionName,
          );
        }
        if (body != null && body.trim().isNotEmpty) {
          notes = UpdateService.parseReleaseNotes(body);
        }
        notes ??= const [
          'Fixed OTA state after installation so the old install prompt does not return',
          'Update dismissal now lasts for the current app session',
          'Added a manual check for the latest release in the sidebar',
          'Added feedback for unavailable APKs and failed update attempts',
        ];
      } else {
        notes = await UpdateService.instance.checkFirstLaunchAfterUpdate();
        if (notes != null && notes.isNotEmpty) {
          final platformInfo = await AppInfoService.instance.getAppInfo();
          versionName = platformInfo.versionName;
        }
      }
      if (!mounted || notes == null || notes.isEmpty) return;

      await showOptionsModalSheet<void>(
        context,
        title: 'Release Notes',
        subtitle: versionName != null && versionName.isNotEmpty
            ? 'Version $versionName'
            : null,
        isScrollControlled: true,
        options: notes
            .map(
              (note) => SheetOption(
                title: note,
                icon: Icons.check_circle_outline_rounded,
                iconColor: kBubbleUser,
                onTap: null,
              ),
            )
            .toList(),
      );
    } catch (_) {}
  }

  LlmClient _createLlmClient(String model) {
    final settings = AppSettingsService.instance;
    final provider = settings.activeProvider;
    final apiKey = settings.resolveApiKey(provider);
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

  static bool _isFreeRouterId(String id) => AppSettingsService.isFreeRouterId(id);

  String _resolveModelForProvider(
    LlmProvider provider,
    List<ModelOption> availableModels,
  ) =>
      AppSettingsService.instance.resolveModelForProvider(
        provider,
        availableModels,
      );

  bool _isFallbackOrStaleModel(
    String modelId,
    LlmProvider provider,
    List<ModelOption> liveModels,
  ) =>
      AppSettingsService.instance.isFallbackOrStaleModel(
        modelId,
        provider,
        liveModels,
      );

  /// Ensures that decrypted runtime settings, API keys, and model configurations
  /// are fully hydrated before executing actions that depend on them.
  ///
  /// Sends only need the fast core (keys + stored model pick); the live
  /// catalog refresh is network-bound, so only settings surfaces and
  /// conversation switches wait for it via [requireCatalog].
  Future<void> _ensureSettingsReady({bool requireCatalog = false}) async {
    if (!AppSettingsService.instance.isLoaded) {
      await AppSettingsService.instance.whenLoaded;
    }
    final coreReady = _appConfigCoreReady;
    if (coreReady != null && !coreReady.isCompleted) {
      await coreReady.future;
    }
    if (requireCatalog && _loadAppConfigFuture != null) {
      await _loadAppConfigFuture;
    }
  }

  /// Loads runtime configuration (decrypted keys, last-selected model) from
  /// the settings store, then refreshes the model catalog. Replaces the old
  /// compile-time --dart-define env injection.
  Future<void> _loadAppConfig() async {
    // Created synchronously on first call (from initState) so senders can
    // gate on the fast core below without racing its creation. Always
    // completed (even on early return/throw) so senders can never hang.
    _appConfigCoreReady ??= Completer<void>();
    try {
      await _loadAppConfigBody();
    } finally {
      final core = _appConfigCoreReady;
      if (core != null && !core.isCompleted) core.complete();
    }
  }

  Future<void> _loadAppConfigBody() async {
    await AppSettingsService.instance.ensureLoaded();
    if (!mounted) return;
    final settings = AppSettingsService.instance;

    // Let models.dev settle briefly so release-date sorting (and therefore
    // the auto-pick) is stable across restarts instead of falling back to
    // alphabetical order on cold starts.
    try {
      await ModelsDevService().load().timeout(
        const Duration(seconds: 2),
      );
    } catch (_) {}

    // 3. ofcourse all this only if any model is not selected until now
    // if selected then we will use that like currently how we are doing
    final hasCachedModel = settings.hasSelectedModel;

    // Provider priority: last selected (when configured) > any configured
    // > any provider. Per-provider model priority is handled below in
    // _resolveModelForProvider.
    final LlmProvider provider = settings.resolveStartupProvider();
    if (provider.id != settings.activeProvider.id) {
      await settings.setActiveProvider(provider.id);
    }

    final cached = ModelCatalogService.getCachedModels(provider.baseUrl);
    final rawAvailable = (cached != null && cached.isNotEmpty)
        ? cached
        : provider.defaultModels;

    // Sort the list in model picker with release date (update date from models.dev)
    final availableModels = List<ModelOption>.from(rawAvailable)
      ..sort(ModelOption.compareByReleaseDate);

    // Startup must never clobber the persisted pick: with an empty
    // in-memory catalog `availableModels` is just the hardcoded fallback, so
    // a valid live model (e.g. provider_a/model_b) would fail the existence
    // check and get overwritten before the network ever runs. Adopt the
    // stored value optimistically; _loadModelCatalog() validates it against
    // the live list below and heals/persists only then. The single exception
    // is the free-router-with-key case, which is knowably stale without any
    // live data.
    final String model;
    if (hasCachedModel) {
      final stored = settings.selectedModelFor(provider.id);
      final isFreeWithKey =
          _isFallbackOrStaleModel(stored, provider, const []) &&
          _isFreeRouterId(stored);
      if (!isFreeWithKey) {
        model = stored;
      } else {
        model = _resolveModelForProvider(provider, availableModels);
        // Stored value is definitively wrong (free fallback despite a key),
        // safe to replace even before live data arrives.
        unawaited(settings.setSelectedModelFor(provider.id, model));
      }
    } else {
      // First launch ever: no stored pick, safe to persist a fresh default.
      model = _resolveModelForProvider(provider, availableModels);
      unawaited(settings.setSelectedModelFor(provider.id, model));
    }

    setState(() {
      _selectedModel = model;
      _activeConversation.model = model;
      _activeConversation.provider = _providerForModel(model) ?? provider.name;
      _models = availableModels;
      _llm.close();
      _llm = _createLlmClient(_selectedModel);
    });
    // Fast core done: stored keys + optimistic model pick are live. The live
    // catalog refresh below is network-bound and must not stall sends.
    _appConfigCoreReady?.complete();
    await _loadModelCatalog();
  }

  /// Opens the Settings sheet; returns true when something was saved.
  /// Reloads the LLM client + catalog afterwards so new keys take effect
  /// immediately.
  Future<bool> _openSettings() async {
    if (_busy) return false;
    await _ensureSettingsReady(requireCatalog: true);
    if (!mounted || _busy) return false;
    final previousProviderId = AppSettingsService.instance.activeProvider.id;
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
      final providerChanged = activeProvider.id != previousProviderId;
      final cached = ModelCatalogService.getCachedModels(
        activeProvider.baseUrl,
      );
      final rawAvailable = (cached != null && cached.isNotEmpty)
          ? cached
          : activeProvider.defaultModels;
      final availableModels = List<ModelOption>.from(rawAvailable)
        ..sort(ModelOption.compareByReleaseDate);

      String modelToUse = _selectedModel;
      // This runs right before _loadModelCatalog(forceRefresh: true), which
      // re-validates against the live list and persists. So when the list
      // here is just the hardcoded fallback, adopt optimistically and let
      // the catalog pass persist the confirmed value.
      final hasLiveList = cached != null && cached.isNotEmpty;
      if (providerChanged) {
        // Switching providers restores that provider's last pick, else its
        // list head, else its hardcoded fallback.
        if (hasLiveList) {
          modelToUse = _resolveModelForProvider(
            activeProvider,
            availableModels,
          );
          unawaited(
            AppSettingsService.instance.setSelectedModelFor(
              activeProvider.id,
              modelToUse,
            ),
          );
        } else {
          final stored = AppSettingsService.instance.selectedModelFor(
            activeProvider.id,
          );
          modelToUse =
              AppSettingsService.instance.hasSelectedModelFor(activeProvider.id)
              ? stored
              : _resolveModelForProvider(activeProvider, availableModels);
        }
      } else if (_isFallbackOrStaleModel(
        _selectedModel,
        activeProvider,
        hasLiveList ? availableModels : const [],
      )) {
        modelToUse = _resolveModelForProvider(
          activeProvider,
          availableModels,
        );
        // Persist only against live data; the force-refresh catalog pass
        // below persists the confirmed value otherwise.
        if (hasLiveList) {
          unawaited(
            AppSettingsService.instance.setSelectedModelFor(
              activeProvider.id,
              modelToUse,
            ),
          );
        }
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
      unawaited(_loadModelCatalog(forceRefresh: true));
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
    final activeProvider = AppSettingsService.instance.activeProvider;
    unawaited(
      AppSettingsService.instance.setSelectedModelFor(
        activeProvider.id,
        model,
      ),
    );
    final cached = ModelCatalogService.getCachedModels(activeProvider.baseUrl);
    setState(() {
      if (cached != null && cached.isNotEmpty && _models != cached) {
        _models = cached;
      }
      _selectedModel = model;
      _activeConversation.model = model;
      _activeConversation.provider =
          _providerForModel(model) ?? activeProvider.name;
      _touchConversation();
    });
    _persistNow();
  }

  Future<List<ModelOption>> _selectProvider(LlmProvider provider) async {
    await AppSettingsService.instance.setActiveProvider(provider.id);
    final cached = ModelCatalogService.getCachedModels(provider.baseUrl);
    final hasLiveList = cached != null && cached.isNotEmpty;
    final rawAvailable = hasLiveList ? cached : provider.defaultModels;
    final availableModels = List<ModelOption>.from(rawAvailable)
      ..sort(ModelOption.compareByReleaseDate);
    // Per-provider priority: that provider's last pick (when still valid)
    // > first in its sorted list > hardcoded preset. When the list is just
    // the hardcoded fallback (no live data yet), adopt the stored pick
    // optimistically and persist nothing — _loadModelCatalog() below
    // validates against the live list and persists the healed/confirmed
    // value. Persisting here would clobber a valid live pick with a
    // defaults-only guess.
    final stored = AppSettingsService.instance.selectedModelFor(provider.id);
    final hasStored =
        AppSettingsService.instance.hasSelectedModelFor(provider.id);
    final String modelToUse;
    final bool persistNow;
    if (!hasLiveList && hasStored) {
      final isFreeWithKey = _isFreeRouterId(stored) &&
          (provider.hasKey ||
              (provider.id == ProviderPresetType.openRouter.id &&
                  AppSettingsService.instance.hasOpenRouterKey));
      if (isFreeWithKey) {
        modelToUse = _resolveModelForProvider(provider, availableModels);
        persistNow = true;
      } else {
        modelToUse = stored;
        persistNow = false;
      }
    } else {
      modelToUse = _resolveModelForProvider(provider, availableModels);
      persistNow = true;
    }

    _llm.close();
    _llm = _createLlmClient(modelToUse);
    if (persistNow) {
      unawaited(
        AppSettingsService.instance.setSelectedModelFor(
          provider.id,
          modelToUse,
        ),
      );
    }

    setState(() {
      _selectedModel = modelToUse;
      _activeConversation.model = modelToUse;
      _activeConversation.provider = provider.name;
      _models = availableModels;
      _touchConversation();
    });
    _persistNow();

    final hasKey = AppSettingsService.instance.providerHasKey(provider);

    if (hasKey) {
      // Force refresh: the cached list may be the unauthenticated fallback.
      await _loadModelCatalog(forceRefresh: true);
    }
    return _models;
  }

  @override
  void dispose() {
    if (_busy || _turnInFlight) {
      _stopGeneration();
    }
    WidgetsBinding.instance.removeObserver(this);
    _composerFocusNode.dispose();
    _streamingService.dispose();
    _a11yToastTimer?.cancel();
    unawaited(_intentService.stopWorkIndicator());
    // Flush any pending debounced persistence into fire-and-forget database write
    // so pending conversation turns are never dropped on unmount.
    //
    // This MUST go through _persistWriter like every other save: writing directly
    // races any in-flight coalesced write for the same conversation, and if this
    // newer snapshot lands first the older in-flight snapshot overwrites it —
    // silently losing the final streamed answer.
    _persistTimer?.cancel();
    _persistTimer = null;
    final currentId = _activeConversation.id;
    if (currentId != null) {
      final snapshot = _snapshotConversation();
      unawaited(_persistWriter.run(() => database.saveConversation(snapshot)));
    }
    _conversationsSub?.cancel();
    _pinnedConversationsSub?.cancel();
    _widgetVoiceSub?.cancel();
    // Session-owned; every ToolRegistry got it by reference, so none of them
    // may dispose it. Closes the native PDDocuments it holds.
    _documentCache.dispose();
    _modelCatalog.close();
    _llm.close();
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _sessionStartTime = DateTime.now();
      _checkStoragePermission(promptIfMissing: true);
      // Sweep background-run fossils on every foreground return: the user
      // comes back to check a stuck task far more often than they reboot.
      unawaited(TaskSchedulerService.instance.recoverStuckTasks());
      // Reconcile cached OTA state after returning from the package installer
      // or another external app. The normal interval still limits network use.
      unawaited(UpdateService.instance.checkUpdate());
      // Re-check after the user may have toggled the service in Settings
      // while we were backgrounded. Toast only on a true→false flip (freshly
      // disabled) — a steady-off resume stays silent instead of re-nagging.
      unawaited(
        _refreshA11yState().then((flippedToOff) {
          if (flippedToOff) _triggerA11yToast();
        }),
      );
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
    AppSettingsService.instance
        .a11yPromptDismissed()
        .then((dismissed) {
          if (dismissed) return;
          if (!mounted || !_a11ySupported || _a11yAvailable || _showA11yToast) {
            return;
          }
          setState(() => _showA11yToast = true);
          _a11yToastTimer?.cancel();
          _a11yToastTimer = Timer(const Duration(seconds: 8), () {
            if (mounted && _showA11yToast) {
              setState(() => _showA11yToast = false);
            }
          });
        })
        .catchError((_) {
          if (!mounted || !_a11ySupported || _a11yAvailable || _showA11yToast) {
            return;
          }
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
    if (permitted) {
      unawaited(Workspace.instance.ensureDefaultDirectories());
    } else if (promptIfMissing) {
      await _showStoragePermissionDialog();
    }
  }

  Future<void> _loadModelCatalog({bool forceRefresh = false}) async {
    final settings = AppSettingsService.instance;
    final provider = settings.activeProvider;
    final hasKey = settings.providerHasKey(provider);

    if (!hasKey) {
      if (mounted) {
        final sorted = List<ModelOption>.from(provider.defaultModels)
          ..sort(ModelOption.compareByReleaseDate);
        setState(() {
          _models = sorted;
        });
      }
      return;
    }

    try {
      final apiKey = settings.resolveApiKey(provider);
      final models = await _modelCatalog.load(
        baseUrl: provider.baseUrl.isNotEmpty
            ? provider.baseUrl
            : provider.defaultBaseUrl,
        apiKey: apiKey,
        defaultProvider: provider.name,
        isOpenRouter:
            settings.isOpenRouterProvider(provider),
        forceRefresh: forceRefresh,
      );
      if (!mounted) return;

      final sortedModels = List<ModelOption>.from(models)
        ..sort(ModelOption.compareByReleaseDate);

      final storedForProvider = settings.selectedModelFor(provider.id);
      final bool shouldPickNewDefault =
          !settings.hasSelectedModelFor(provider.id) ||
          _isFallbackOrStaleModel(_selectedModel, provider, sortedModels) ||
          _isFallbackOrStaleModel(storedForProvider, provider, sortedModels);

      final String modelToUse;
      if (shouldPickNewDefault && sortedModels.isNotEmpty) {
        modelToUse = _resolveModelForProvider(provider, sortedModels);
        unawaited(settings.setSelectedModelFor(provider.id, modelToUse));
      } else {
        modelToUse = _selectedModel;
      }
      final modelChanged = modelToUse != _selectedModel;

      setState(() {
        _selectedModel = modelToUse;
        _activeConversation.model = modelToUse;
        _models = [
          ...sortedModels,
          if (!sortedModels.any((model) => model.id == modelToUse))
            ModelOption(
              id: modelToUse,
              name: modelToUse,
              provider: provider.name,
            ),
        ];
        if (modelChanged) {
          _llm.close();
          _llm = _createLlmClient(modelToUse);
        }
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
    return PendingAttachmentsBanner(
      uris: _pendingAttachments,
      onDetach: _detachPending,
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
              subtitle: const Text(
                'Image, audio, video or document',
                style: TextStyle(color: kMuted, fontSize: 12),
              ),
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
    final cached = ModelCatalogService.getCachedModels(
      AppSettingsService.instance.activeProvider.baseUrl,
    );
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

  Conversation _snapshotConversation() {
    final id = _activeConversation.id;
    if (id == null) {
      throw StateError('Cannot snapshot a conversation with no id');
    }

    final workingId = _workingMessageId;
    final messages = workingId == null
        ? _messages
        : _messages
              .where((message) => message.id != workingId)
              .toList(growable: false);

    return Conversation(
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
    );
  }

  /// Saves the active conversation (without the in-flight "…working" bubble)
  /// to the local database, serializing and coalescing overlapping calls via
  /// [CoalescingWriter] (unit-tested in test/coalescing_writer_test.dart).
  Future<void> _persistConversation() async {
    final targetId = _activeConversation.id;
    if (targetId == null) {
      await _persistWriter.settled;
      return;
    }

    _pendingPersistConversationId = targetId;

    try {
      await _persistWriter.run(() async {
        final currentId = _activeConversation.id;
        if (currentId != null && currentId == _pendingPersistConversationId) {
          final snapshot = _snapshotConversation();
          await database.saveConversation(snapshot);
        }
      });
    } catch (e, st) {
      debugPrint('[Persistence] Error saving conversation: $e\n$st');
    }
  }

  /// Debounces saves during streaming so we don't rewrite the whole
  /// conversation on every text delta.
  void _schedulePersist([Duration delay = const Duration(milliseconds: 600)]) {
    final targetId = _activeConversation.id;
    if (targetId == null) return;
    _pendingPersistConversationId = targetId;
    _persistTimer?.cancel();
    _persistTimer = Timer(delay, () {
      _persistTimer = null;
      unawaited(_persistConversation());
    });
  }

  Future<void> _persistNow() async {
    _persistTimer?.cancel();
    _persistTimer = null;
    await _persistConversation();
  }

  /// Cancels any debounced persist timer and flushes any pending writes
  /// for the active conversation, guaranteeing that all in-flight or scheduled
  /// writes complete before switching conversations or resetting draft state.
  Future<void> _flushActiveConversationPersistence() async {
    _persistTimer?.cancel();
    _persistTimer = null;
    if (_activeConversation.id != null) {
      await _persistConversation();
    } else {
      await _persistWriter.settled;
    }
  }

  void _startConversation(String firstMessage) {
    if (_activeConversation.id != null) {
      _touchConversation();
      return;
    }

    final newId = _uuid.v4();
    _activeConversation
      ..id = newId
      ..title = _conversationTitle(firstMessage)
      ..model = _selectedModel
      ..provider = _providerForModel(_selectedModel);
    if (_sessionTrustedConversations.remove('__active_draft__')) {
      _sessionTrustedConversations.add(newId);
    }
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
        if (conversation.id != null && seen.add(conversation.id!)) conversation,
    ];
    unique.sort((a, b) {
      // Match the database (updatedAt, id) cursor so paged rows line up
      // instead of jumping or skipping on timestamp ties.
      final byUpdated = b.updatedAt.compareTo(a.updatedAt);
      if (byUpdated != 0) return byUpdated;
      return b.id!.compareTo(a.id!);
    });
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

  Future<void> _startNewChat() async {
    if (_busy) return;
    if (_pendingConfirmation != null &&
        !_pendingConfirmation!.completer.isCompleted) {
      _pendingConfirmation!.completer.complete(ConfirmationDecision.deny);
      _pendingConfirmation = null;
    }
    await _flushActiveConversationPersistence();
    if (!mounted) return;
    await _ensureSettingsReady(requireCatalog: true);
    if (!mounted) return;
    _streamingService.reset();
    _controller.clear();
    _pendingAttachments.clear();
    _workingDirectory.current = Workspace.instance.defaultDir;
    final welcome = _welcomeMessages();
    _animatedMessageIds.clear();
    _animatedMessageIds.addAll(welcome.map((m) => m.id));

    final activeProvider = AppSettingsService.instance.activeProvider;
    final defaultModel =
        AppSettingsService.instance.selectedModelFor(activeProvider.id);
    // Guard against a persisted id that no longer exists for this provider
    // (e.g. deprecated upstream) — validate before adopting it.
    final knownIds = <String>{
      for (final m in _models) m.id,
      for (final m in activeProvider.defaultModels) m.id,
    };
    if (knownIds.isNotEmpty && !knownIds.contains(defaultModel)) {
      final fallback = _resolveModelForProvider(
        activeProvider,
        _models.isNotEmpty ? _models : activeProvider.defaultModels,
      );
      _selectedModel = fallback;
      unawaited(
        AppSettingsService.instance.setSelectedModelFor(
          activeProvider.id,
          fallback,
        ),
      );
      _llm.close();
      _llm = _createLlmClient(fallback);
    } else {
      _selectedModel = defaultModel;
      _llm.close();
      _llm = _createLlmClient(_selectedModel);
    }

    setState(() {
      _sessionStartTime = DateTime.now();
      _messages = welcome;
      _activeConversation = _newDraftConversation();
      _workingMessageId = null;
      _streamingService.reset();
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

    if (_pendingConfirmation != null &&
        !_pendingConfirmation!.completer.isCompleted) {
      _pendingConfirmation!.completer.complete(ConfirmationDecision.deny);
      _pendingConfirmation = null;
    }

    // Flush any pending persistence for the current conversation before
    // switching to the new conversation.
    await _flushActiveConversationPersistence();
    if (!mounted) return;

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
      await _ensureSettingsReady(requireCatalog: true);
      if (!mounted) return;
      final match = AppSettingsService.instance.providers.firstWhere(
        (p) => p.name == loaded.provider || p.id == loaded.provider,
        orElse: () => AppSettingsService.instance.activeProvider,
      );
      await AppSettingsService.instance.setActiveProvider(match.id);
      if (!mounted) return;
    }

    _pendingAttachments.clear();
    _workingDirectory.current =
        (loaded.currentDir.path == _workingDirectory.root.path)
        ? Workspace.instance.defaultDir
        : loaded.currentDir;
    _animatedMessageIds.clear();
    _animatedMessageIds.addAll(loaded.messages.map((m) => m.id));
    setState(() {
      _sessionStartTime = DateTime.now();
      _activeConversation = loaded;
      _messages = loaded.messages;
      final providerForCheck = AppSettingsService.instance.activeProvider;
      final storedModel = loaded.model ??
          AppSettingsService.instance.selectedModelFor(
            providerForCheck.id,
          );
      final validIds = <String>{
        for (final m in _models) m.id,
        for (final m in providerForCheck.defaultModels) m.id,
        ...?ModelCatalogService.getCachedModels(providerForCheck.baseUrl)
            ?.map((m) => m.id),
      };
      // Old conversations may reference a model that was since removed
      // upstream or belongs to a different provider — fall back instead of
      // sending a foreign/dead id to the active endpoint.
      _selectedModel =
          (validIds.isEmpty || validIds.contains(storedModel))
              ? storedModel
              : _resolveModelForProvider(
                  providerForCheck,
                  _models.isNotEmpty
                      ? _models
                      : providerForCheck.defaultModels,
                );
      _llm.close();
      _llm = _createLlmClient(_selectedModel);
      _workingMessageId = null;
      _streamingService.reset();
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
      await _startNewChat();
    }
    // Keep the sidebar open so the user can continue managing history.
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
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value.trim()),
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
    // The controller outlives the dialog unless released here; every rename
    // otherwise leaked one (with its listeners/selection state) for the session.
    controller.dispose();
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
      // If the user has scrolled up to read history (>160px), do not yank
      // their viewport down unless force is explicitly set.
      if (!force && distance > 160) return;
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
    if (text.isEmpty || _busy || _turnInFlight) return;
    // Synchronous busy-latch before the first await below: two rapid taps
    // must not both sail through the guard and append duplicate bubbles.
    // `_runAgentTurn` owns the turn itself; this only covers send's own
    // pre-turn awaits (settings, speech stop, edit truncate). Plain field
    // write (no setState): the message append rebuilds right after.
    _busy = true;
    try {
      await _ensureSettingsReady();
      if (!mounted) return;
    _controller.clear();

    // A live dictation session would keep writing its next partials into
    // the (now empty) composer after the message is gone — end it and invalidate
    // the active speech session so late callbacks never refill the composer.
    _speechSessionId++;
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
      if (!mounted) return;
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
    } finally {
      // The turn clears `_busy` itself on completion; this covers the early
      // exits above. Re-setting an already-false flag is harmless.
      _busy = false;
    }
  }

  /// Regenerate: drops everything after [userMessageId] (same truncation
  /// semantics as edit-resend) and re-runs the loop for that turn.
  Future<void> _regenerate(String userMessageId) async {
    if (_busy || _turnInFlight) return;
    // Same synchronous latch as `_send`: the truncate below awaits, and a
    // second tap must not enter a parallel truncate+turn.
    _busy = true;
    try {
      await _ensureSettingsReady();
      if (!mounted) return;
      // A pending edit (banner + loaded composer text) is superseded by an
      // explicit regenerate — drop it instead of leaving stale state around.
      if (_editingMessageId != null) _cancelEditing();
      final index = _messages.indexWhere((m) => m.id == userMessageId);
      if (index == -1) return;

      // Nothing after it (e.g. the previous turn failed) → nothing to drop.
      if (index + 1 < _messages.length) {
        await _truncateFrom(_messages[index + 1].id);
      }
      if (!mounted) return;
      await _runAgentTurn();
    } finally {
      _busy = false;
    }
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
    // Synchronous latch: see [_turnInFlight]. Must precede every await below.
    // Only the in-flight flag gates here — `_busy` is set synchronously by
    // `_send`/`_regenerate` before their first await, so testing it here
    // would make every normal send bail out immediately.
    if (_turnInFlight) return;
    _turnInFlight = true;
    final settings = AppSettingsService.instance;
    final provider = settings.activeProvider;
    final hasKey = settings.providerHasKey(provider);
    if (!hasKey) {
      final pName = provider.name;
      _showToast('Add an API key for $pName in Settings to start chatting.');
      await _openSettings();
      _turnInFlight = false;
      return;
    }

    if (!mounted) {
      _turnInFlight = false;
      return;
    }

    final workingId = 'working-${DateTime.now().microsecondsSinceEpoch}';
    _workingMessageId = workingId;
    _streamingService.reset();
    _externalAppWorkDone = false;
    _externalIntentLaunched = false;
    _cancelToken.reset();
    setState(() {
      _messages.add(
        AssistantMessage(
          id: workingId,
          text: '…working',
          model: _selectedModel,
          provider:
              _activeConversation.provider ?? settings.activeProvider.name,
        ),
      );
      _busy = true;
    });
    // Foreground service: keeps the process non-cached (and its sockets
    // alive) even when an intent tool sends Errand to the background.
    unawaited(_intentService.startWorkIndicator());
    _startWorkingElapsedTimer();
    _persistNow();
    _scrollToBottom(force: true);

    try {
      final conversation = Conversation(
        id: _activeConversation.id,
        localSystemPrompt: systemPromptFor(
          _workingDirectory.current,
          scratchDir: Workspace.instance.scratchDir,
          locationSummary: LocationService.instance.lastKnown?.toCoarseSummary(),
          now: _sessionStartTime,
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
        getCancelToken: () => _cancelToken,
        currentConversationId: _activeConversation.id,
        currentConversationIdResolver: () => _activeConversation.id,
        onConfirmCommand: _handleConfirmCommand,
        isSessionTrusted: _isCurrentSessionTrusted,
        documentCache: _documentCache,
      );

      final budget = _getActiveBudget();

      final loop = AgentLoop(
        llm: _llm,
        registry: registry,
        budget: budget,
        systemPromptBuilder: () => systemPromptFor(
          _workingDirectory.current,
          scratchDir: Workspace.instance.scratchDir,
          locationSummary: LocationService.instance.lastKnown?.toCoarseSummary(),
          now: _sessionStartTime,
          screenAccess: _a11yAvailable,
          screenRestricted: _a11yRestricted,
          a11ySupported: _a11ySupported,
        ),
        cancelToken: _cancelToken,
        supportsInput: (modality) =>
            ModelCatalogService.supportsInput(
              _selectedModel,
              modality,
              baseUrl: AppSettingsService.instance.effectiveBaseUrl,
            ) !=
            false,
        onEvent: _handleEvent,
        onTextDelta: _handleTextDelta,
        onReasoningDelta: _handleReasoningDelta,
        onReset: _handleStreamReset,
        onRetry: _handleStreamRetry,
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
    } on RepeatedToolFailureException catch (e) {
      _failWorking(e.message);
    } catch (e, stackTrace) {
      debugPrint('[AgentError] unexpected_error: $e\n$stackTrace');
      // Transport/API failures (connection aborts, timeouts, HTTP 429/5xx)
      // are not the agent's fault — show a transient toast instead of adding
      // an error message to the conversation context.
      _failWorking(e is LlmException ? e.message : 'Unexpected error: $e');
    } finally {
      if (_busy) {
        if (mounted) {
          setState(() {
            _busy = false;
            _workingMessageId = null;
          });
        } else {
          _busy = false;
          _workingMessageId = null;
        }
      }
      _streamingService.cancel();
      unawaited(_intentService.stopWorkIndicator());
      _turnInFlight = false;
    }
  }

  /// Elapsed-seconds ticker for the …working/…thinking placeholder: slow
  /// models spend 30–90s before the first token, and a static placeholder is
  /// indistinguishable from a hung request. The ticker is the ONLY writer of
  /// the elapsed suffix; [_handleReasoningDelta] just flips the label flag.
  /// Elapsed timer is now scoped locally inside _WorkingPlaceholderText (H7),
  /// eliminating the per-second ChatScreen rebuild storm.
  void _startWorkingElapsedTimer() {
    // Elapsed ticker is now scoped locally inside _WorkingPlaceholderText (H7).
  }

  /// Single writer for the …working/…thinking placeholder. Every other
  /// state change (reasoning start, new turn) goes through here.
  void _updateWorkingPlaceholder() {
    if (!mounted) return;
    final id = _workingMessageId;
    if (id == null || _streamingService.hasContent) return;
    final index = _messages.indexWhere((message) => message.id == id);
    if (index == -1) return;
    setState(() {
      _messages[index] = AssistantMessage(
        id: id,
        text: _streamingService.placeholderLabel,
        model: _selectedModel,
        provider:
            _activeConversation.provider ??
            AppSettingsService.instance.activeProvider.name,
      );
    });
  }

  /// Removes the working placeholder and surfaces [message] as a snackbar.
  /// Used for infra-level failures that must not enter model context.
  void _failWorking(String message) {
    _streamingService.reset();
    unawaited(_intentService.stopWorkIndicator());
    if (_externalAppWorkDone || _externalIntentLaunched) {
      unawaited(_intentService.bringToFront());
    }
    final id = _workingMessageId;
    if (!mounted) {
      final conversationId = _activeConversation.id;
      if (conversationId != null && id != null) {
        unawaited(database.deleteMessage(conversationId, id));
      }
      return;
    }
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
          content: Text(message, maxLines: 3, overflow: TextOverflow.ellipsis),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
  }

  void _handleEvent(AgentEvent event) {
    if (!mounted) return;
    switch (event) {
      case AgentThinking():
        break;
      case AgentToolCallStarting():
        break;
      case AgentCompacting():
        _streamingService.setCompacting(true);
      case AgentCompacted(:final summary, :final tailBlockCount):
        _streamingService.setCompacting(false);
        _handleCompacted(summary, tailBlockCount: tailBlockCount);
      case AgentToolCall(
        call: final call,
        result: final result,
        reasoning: final reasoning,
        reasoningDetails: final reasoningDetails,
      ):
        _streamingService.setCompacting(false);
        if (call.name == 'screen' ||
            call.name == 'act' ||
            call.name == 'screen_act') {
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
      // A compaction event can race with the UI replacing/removing the
      // working message. If no history blocks remain, keeping one tail block
      // would produce sublist(-1) and surface as RangeError(...: -1).
      final keepCount = blocks.isEmpty
          ? 0
          : tailBlockCount.clamp(1, blocks.length);
      final splitAt = blocks.length - keepCount;
      final compactedBlocks = blocks.sublist(0, splitAt);
      final keptTailBlocks = blocks.sublist(splitAt);

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
    _streamingService.cancel();

    setState(() {
      final workingId = _workingMessageId;
      final workingIndex = workingId == null
          ? -1
          : _messages.indexWhere((current) => current.id == workingId);

      final currentText = _streamingService.currentPristineText;
      _streamingService.reset();

      if (workingIndex == -1) {
        _messages.add(message);
        _touchConversation();
        return;
      }

      _messages.removeAt(workingIndex);
      var nextWorkingIndex = workingIndex;
      if (currentText.trim().isNotEmpty) {
        _messages.insert(
          nextWorkingIndex,
          AssistantMessage(id: workingId!, text: currentText.trim()),
        );
        nextWorkingIndex++;
      }
      _messages.insert(nextWorkingIndex, message);

      final nextWorkingId = 'working-${DateTime.now().microsecondsSinceEpoch}';
      _workingMessageId = nextWorkingId;
      _messages.insert(
        nextWorkingIndex + 1,
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
    _streamingService.appendDelta(delta);
  }

  void _handleStreamReset() {
    if (!mounted || _workingMessageId == null) return;
    _streamingService.reset();
    _updateWorkingPlaceholder();
    _schedulePersist(const Duration(milliseconds: 150));
  }

  /// A stream attempt failed and the client is redialling: surface it in the
  /// working bubble (…retrying · attempt N) and toast the reason. The bubble
  /// keeps the stale partial until [_handleStreamReset] clears it once the
  /// next attempt establishes a stream; the flag clears when fresh text
  /// renders or the turn ends.
  void _handleStreamRetry(int attempt, String reason) {
    if (!mounted || _workingMessageId == null) return;
    _streamingService.setRetry(attempt);
    _showToast('Interrupted ($reason) — retrying (attempt $attempt)…');
  }

  void _handleReasoningDelta() {
    if (!mounted || _workingMessageId == null) return;
    _streamingService.startReasoning();
  }

  void _replaceWorking(String text) {
    _streamingService.finalize();
    unawaited(_intentService.stopWorkIndicator());
    final trimmed = text.trim();
    if (_externalAppWorkDone ||
        (_externalIntentLaunched && trimmed.isNotEmpty)) {
      unawaited(_intentService.bringToFront());
    }
    final id = _workingMessageId;
    _streamingService.reset();
    if (!mounted) {
      final conversationId = _activeConversation.id;
      if (trimmed.isNotEmpty && id != null && conversationId != null) {
        final message = AssistantMessage(
          id: id,
          text: trimmed,
          model: _selectedModel,
          provider: _activeConversation.provider ??
              AppSettingsService.instance.activeProvider.name,
        );
        unawaited(_persistWriter.run(() => database.insertMessage(conversationId, message)));
      }
      return;
    }
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
          provider:
              _activeConversation.provider ??
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
    if (!_busy && !_turnInFlight) return;
    _cancelToken.cancel();
    if (_pendingConfirmation != null &&
        !_pendingConfirmation!.completer.isCompleted) {
      _pendingConfirmation!.completer.complete(ConfirmationDecision.deny);
    }
  }

  // -- Voice input ---------------------------------------------------------

  DateTime? _lastVoicePromptAt;
  bool _isTogglingVoice = false;
  int _speechSessionId = 0;


  /// Triggered via Android Home Screen Widget or direct voice shortcuts.
  Future<void> _startVoicePrompt() async {
    // Native now latches pending + emits the stream, so cold-start resume
    // can deliver both back-to-back — debounce to a single session start.
    final now = DateTime.now();
    if (_lastVoicePromptAt != null &&
        now.difference(_lastVoicePromptAt!) <
            const Duration(milliseconds: 1500)) {
      return;
    }
    _lastVoicePromptAt = now;
    final speech = SpeechService.instance;
    if (speech.listening.value) return; // already active
    if (_busy) {
      _showToast('Agent is currently busy.');
      return;
    }
    await _toggleVoiceInput();
  }

  /// Mic button: start/stop a speech-recognition session. Recognized text
  /// lands in the composer (live partials); the user reviews and sends.
  Future<void> _toggleVoiceInput() async {
    final speech = SpeechService.instance;
    if (speech.listening.value || _isTogglingVoice) {
      _speechSessionId++;
      await speech.stop();
      if (mounted) setState(() {});
      return; // listening notifier flips via onStatus / stop
    }
    _isTogglingVoice = true;
    speech.listening.value = true;
    if (mounted) setState(() {});
    // Setup generation: the stop branch bumps _speechSessionId, so capture
    // before the awaits and abort if a stop tap landed mid-setup. Without
    // this, the flow below mints a fresh session after the stop and
    // dictation starts against the user's explicit stop.
    final setupId = _speechSessionId;

    try {
      await _ensureSettingsReady();
      if (!mounted || _busy) {
        speech.listening.value = false;
        return;
      }

      if (!await speech.hasMicPermission()) {
        speech.listening.value = false;
        final granted = await speech.requestMicPermission();
        if (!mounted) return;
        if (!granted) {
          _showToast('Microphone permission is needed for voice input.');
          return;
        }
        speech.listening.value = true;
      }

      if (!await speech.initialize()) {
        speech.listening.value = false;
        if (!mounted) return;
        _showToast(
          'Speech recognition is unavailable on this device. On emulators, '
          'enable the Google app and grant it microphone access.',
        );
        return;
      }

      var localeId = await speech.savedLocaleId();
      if (localeId == null) {
        speech.listening.value = false;
        localeId = await _pickVoiceLocale();
        if (!mounted) return;
        if (localeId == null) return; // user cancelled the picker
        await speech.saveLocaleId(localeId);
        speech.listening.value = true;
      }

      final sessionId = ++_speechSessionId;
      if (sessionId - 1 != setupId) {
        // A stop tap landed during setup (permission/locale awaits).
        speech.listening.value = false;
        if (mounted) setState(() {});
        return;
      }
      try {
        await speech.listen(
          localeId: localeId,
          onResult: (words, isFinal) {
            if (!mounted || sessionId != _speechSessionId) return;
            // Already cleaned inside SpeechService.listen; applying
            // cleanSpeechText twice compounds aggressive trims.
            final cleanWords = words;
            // Cumulative partials replace the composer text; keep the cursor
            // at the end so typing can continue seamlessly.
            _controller.value = TextEditingValue(
              text: cleanWords,
              selection: TextSelection.collapsed(offset: cleanWords.length),
            );
            if (isFinal && mounted) {
              speech.stop();
              setState(() {});
            }
          },
        );
      } catch (e) {
        speech.listening.value = false;
        if (!mounted) return;
        _showToast('Could not start voice input: $e');
      }
    } finally {
      _isTogglingVoice = false;
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
              onPressed: () => Navigator.of(dialogContext).pop(locale.localeId),
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
          content: Text(message, maxLines: 3, overflow: TextOverflow.ellipsis),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
  }

  /// Finalizes a stopped turn: partial streamed text becomes the final
  /// answer (marked "(stopped)"); nothing streamed → drop the bubble.
  void _finishStopped() {
    final stopped = _streamingService.finalizeStopped();
    _replaceWorking(stopped);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_sidebarOpen && !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          if (_busy) _stopGeneration();
          return;
        }
        if (_sidebarOpen) {
          _closeSidebar();
          return;
        }
        if (_busy) {
          _stopGeneration();
          _showToast('Stopped generation');
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
                      _buildUpdateToast(),
                      Expanded(child: _buildMessageList()),
                      if (kDebugMode) _buildContextFooter(),
                      if (_pendingAttachments.isNotEmpty)
                        _buildPendingAttachments(),
                      if (_editingMessageId != null) _buildEditingBanner(),
                      ListenableBuilder(
                        listenable: _composerFocusNode,
                        builder: (context, _) => BrowserDockSpacer(
                          isComposerFocused: _composerFocusNode.hasFocus,
                        ),
                      ),
                      KeyedSubtree(key: _composerKey, child: _buildComposer()),
                    ],
                  ),
                ),
                _buildA11yToastOverlay(),
                ListenableBuilder(
                  listenable: _composerFocusNode,
                  builder: (context, _) => BrowserWidget(
                    composerKey: _composerKey,
                    isComposerFocused: _composerFocusNode.hasFocus,
                    onUnfocusComposer: () {
                      if (_composerFocusNode.hasFocus) {
                        _composerFocusNode.unfocus();
                      }
                    },
                  ),
                ),
                if (_pendingConfirmation != null)
                  Positioned.fill(
                    child: CommandConfirmationModal(
                      title: _pendingConfirmation!.title,
                      command: _pendingConfirmation!.command,
                      reason: _pendingConfirmation!.reason,
                      onAccept: () => _resolvePendingConfirmation(
                        ConfirmationDecision.accept,
                      ),
                      onDeny: () => _resolvePendingConfirmation(
                        ConfirmationDecision.deny,
                      ),
                      onTrust: () => _resolvePendingConfirmation(
                        ConfirmationDecision.trust,
                      ),
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
                    onShowReleaseNotes: () => _checkReleaseNotes(force: true),
                    onCheckForUpdates: _checkForUpdates,
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
                        title: conversation.isPinned
                            ? 'Unpin Conversation'
                            : 'Pin Conversation',
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
              onPressed: _busy ? null : () => unawaited(_startNewChat()),
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

  Widget _buildUpdateToast() {
    return ValueListenableBuilder<AppUpdateInfo?>(
      valueListenable: UpdateService.instance.activeUpdate,
      builder: (context, updateInfo, _) {
        if (updateInfo == null) return const SizedBox.shrink();
        return ValueListenableBuilder<double?>(
          valueListenable: UpdateService.instance.downloadProgress,
          builder: (context, progress, _) {
            return UpdateToast(
              updateInfo: updateInfo,
              isBusy: _busy,
              downloadProgress: progress,
              onInstall: () {
                unawaited(_installUpdate(updateInfo));
              },
              onDismiss: () {
                unawaited(UpdateService.instance.dismissUpdate());
              },
            );
          },
        );
      },
    );
  }

  Future<void> _installUpdate(AppUpdateInfo updateInfo) async {
    final installed = await UpdateService.instance.installUpdate(updateInfo);
    if (!mounted || installed) return;
    _showToast('Could not download or open the update package.');
  }

  Future<void> _checkForUpdates() async {
    final result = await UpdateService.instance.checkUpdate(force: true);
    if (!mounted) return;

    if (result == null) {
      _showToast('Could not check for updates.');
    } else if (!result.hasUpdate) {
      _showToast('You are already running the latest version.');
    } else if (!result.hasCompatibleApk) {
      _showToast(
        'Update v${result.latestVersion} is available, but no compatible APK was found.',
      );
    } else {
      _showToast(
        'Update v${result.latestVersion} found. Use the update banner to download it.',
      );
    }
  }

  Widget _buildA11yToastOverlay() {
    return A11yToastOverlay(
      show: _showA11yToast,
      isRestricted: _a11yRestricted,
      onDismiss: () => _dismissA11yToast(persist: true),
      onEnable: () {
        _dismissA11yToast();
        unawaited(_a11yService.openSettings());
      },
    );
  }

  Widget _buildMessageList() {
    final displayItems = groupMessagesForDisplay(_messages);

    // M12: Precompute latest active tool group in a single O(N) backward scan.
    int? latestActiveToolGroupIndex;
    for (var j = displayItems.length - 1; j >= 0; j--) {
      final item = displayItems[j];
      if (item is ToolGroupDisplayItem) {
        latestActiveToolGroupIndex = j;
        break;
      }
      if (item is SingleMessageDisplayItem && item.message.id != _workingMessageId) {
        break;
      }
    }

    // M12: Precompute regenerate targets in a single O(N) pass over _messages.
    final regenerateTargets = <int, String>{};
    String? currentUserId;
    int? lastAssistantIndexInTurn;
    for (var idx = 0; idx < _messages.length; idx++) {
      final msg = _messages[idx];
      if (msg is UserMessage) {
        if (currentUserId != null && lastAssistantIndexInTurn != null) {
          regenerateTargets[lastAssistantIndexInTurn] = currentUserId;
        }
        currentUserId = msg.id;
        lastAssistantIndexInTurn = null;
      } else if (msg is AssistantMessage) {
        if (currentUserId != null) {
          lastAssistantIndexInTurn = idx;
        }
      }
    }
    if (currentUserId != null && lastAssistantIndexInTurn != null) {
      regenerateTargets[lastAssistantIndexInTurn] = currentUserId;
    }

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
          itemCount: displayItems.length + (_loadingOlderMessages ? 1 : 0),
          itemBuilder: (context, i) {
            if (_loadingOlderMessages && i == 0) {
              return const LoadMoreIndicator(label: 'Loading earlier messages');
            }
            final index = _loadingOlderMessages ? i - 1 : i;
            final item = displayItems[index];
            final shouldAnimate = !_animatedMessageIds.contains(item.id);
            if (shouldAnimate) {
              // Post-frame: mutating build-observed state during build is a
              // side effect that can produce inconsistent frames. The add is
              // not a setState, so post-dispose execution is harmless.
              final animateId = item.id;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _animatedMessageIds.add(animateId);
              });
            }

            final Widget bubbleWidget;
            if (item is ToolGroupDisplayItem) {
              final isLatestActive = index == latestActiveToolGroupIndex;
              final isRunning = _busy && isLatestActive && !_streamingService.hasContent;
              bubbleWidget = ToolGroupBubble(
                key: ValueKey(item.id),
                tools: item.tools,
                isFinished: !isRunning,
              );
            } else if (item is SingleMessageDisplayItem) {
              final message = item.message;
              if (message is CompactedNoticeMessage) {
                bubbleWidget = CompactedDividerBubble(
                  key: ValueKey(message.id),
                  message: message,
                );
              } else {
                // Regenerate sits on the LAST assistant bubble of each user-turn
                // response (the end-of-response step), not just the literal last
                // message of the conversation. Regenerating an older turn also
                // drops every later turn — same semantics as edit-resend.
                final regenerateUserId = !_busy
                    ? regenerateTargets[item.originalIndex]
                    : null;
                bubbleWidget = MessageBubble(
                  key: ValueKey(message.id),
                  message: message,
                  isStreaming: _busy && message.id == _workingMessageId,
                  onEdit: message is UserMessage
                      ? () => _editUserMessage(message)
                      : null,
                  onRetry: message is UserMessage && !_busy
                      ? () => _regenerate(message.id)
                      : null,
                  onRegenerate: regenerateUserId == null
                      ? null
                      : () => _regenerate(regenerateUserId),
                );
              }
            } else {
              bubbleWidget = const SizedBox.shrink();
            }

            return SubtleFadeIn(
              key: ValueKey('fade_${item.id}'),
              animate: shouldAnimate,
              child: bubbleWidget,
            );
          },
        ),
      ),
    );
  }


  String _formatTokens(int tokens) => formatTokenCount(tokens);

  /// Displays the current active token usage vs. the dynamic compaction threshold.
  Widget _buildContextFooter() {
    final budget = _getActiveBudget();
    final hasCompacted = _messages.any(
      (m) =>
          m is CompactedNoticeMessage ||
          (m is UserMessage &&
              (m.text.startsWith(kCompactedContextMarker) ||
                  m.text.startsWith('[Compacted Conversation History'))),
    );

    return ContextFooter(
      budget: budget,
      activeTokens: _estimatedActiveTokens,
      messageCount: _messages.length,
      hasCompacted: hasCompacted,
    );
  }

  Widget _buildComposer() {
    return ChatComposer(
      controller: _controller,
      focusNode: _composerFocusNode,
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

/// One bullet row in the update opt-in dialog: dot + text, no paragraphs.
class _UpdateDisclosurePoint extends StatelessWidget {
  final String text;

  const _UpdateDisclosurePoint({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '•  ',
            style: TextStyle(color: Color(0xFFC9D1D9), fontSize: 13.5),
          ),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: Color(0xFFC9D1D9),
                fontSize: 13.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
