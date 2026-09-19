import '../llm/llm_client.dart';
import '../services/app_settings.dart';
import '../services/location_service.dart';
import '../services/model_catalog.dart';
import '../services/shell_service.dart';
import '../services/workspace.dart';
import '../tools/file_tools.dart';
import '../types/conversation.dart';
import 'agent_loop.dart';
import 'context_budget.dart';
import 'system_prompt.dart';
import 'tool_registry.dart';

/// Single source of truth for executing an [AgentLoop].
///
/// Encapsulates tool registry initialization, system prompt generation,
/// context budgeting, and lifecycle management. Used by both interactive
/// chat sessions and headless background scheduled tasks.
class AgentRunner {
  final LlmClient llm;
  final WorkingDirectory workingDirectory;
  final String selectedModel;
  final bool a11ySupported;
  final bool a11yAvailable;
  final bool a11yRestricted;
  final bool hasTavilyKey;
  final String? effectiveBaseUrl;
  final ContextBudget? budget;
  final List<String> Function()? getAttachedFiles;
  final CancelToken? cancelToken;
  final Future<ConfirmationDecision> Function({
    required String title,
    required String command,
    String? reason,
  })? onConfirmCommand;
  final bool Function()? isSessionTrusted;

  const AgentRunner({
    required this.llm,
    required this.workingDirectory,
    required this.selectedModel,
    this.a11ySupported = false,
    this.a11yAvailable = false,
    this.a11yRestricted = false,
    this.hasTavilyKey = false,
    this.effectiveBaseUrl,
    this.budget,
    this.getAttachedFiles,
    this.cancelToken,
    this.onConfirmCommand,
    this.isSessionTrusted,
  });

  /// Builds the standard system prompt based on the current workspace and permissions.
  String buildSystemPrompt() {
    return systemPromptFor(
      workingDirectory.current,
      scratchDir: Workspace.instance.scratchDir,
      locationSummary: LocationService.instance.lastKnown?.toCoarseSummary(),
      screenAccess: a11yAvailable,
      screenRestricted: a11yRestricted,
      a11ySupported: a11ySupported,
    );
  }

  /// Executes the agent loop for the given [conversation].
  ///
  /// Disposes the underlying [ToolRegistry] upon completion or failure.
  Future<String> run({
    required Conversation conversation,
    AgentObserver? onEvent,
    AgentTextObserver? onTextDelta,
    AgentReasoningObserver? onReasoningDelta,
    void Function()? onReset,
    AgentRetryObserver? onRetry,
    void Function(String summary)? onCompacted,
  }) async {
    final token = cancelToken;
    final registry = ToolRegistry.defaults(
      currentDir: workingDirectory.root,
      workingDirectory: workingDirectory,
      supportsInput: (modality) =>
          ModelCatalogService.supportsInput(
            selectedModel,
            modality,
            baseUrl: effectiveBaseUrl ??
                AppSettingsService.instance.effectiveBaseUrl,
          ) !=
          false,
      getAttachedFiles: getAttachedFiles ?? () => conversation.attachedFileUris,
      hasTavilyKey: hasTavilyKey,
      enableA11yTools: a11ySupported,
      getCancelToken: token != null ? () => token : null,
      currentConversationId: conversation.id,
      onConfirmCommand: onConfirmCommand,
      isSessionTrusted: isSessionTrusted,
    );

    final activeBudget = budget ??
        ContextBudget(
          contextSize: ModelCatalogService.getContextLength(
            selectedModel,
            baseUrl: effectiveBaseUrl ??
                AppSettingsService.instance.effectiveBaseUrl,
          ),
        );

    final loop = AgentLoop(
      llm: llm,
      registry: registry,
      budget: activeBudget,
      systemPromptBuilder: buildSystemPrompt,
      cancelToken: cancelToken,
      supportsInput: (modality) =>
          ModelCatalogService.supportsInput(
            selectedModel,
            modality,
            baseUrl: effectiveBaseUrl ??
                AppSettingsService.instance.effectiveBaseUrl,
          ) !=
          false,
      onEvent: onEvent,
      onTextDelta: onTextDelta,
      onReasoningDelta: onReasoningDelta,
      onReset: onReset,
      onRetry: onRetry,
      onCompacted: onCompacted,
    );

    try {
      return await loop.run(conversation);
    } finally {
      registry.dispose();
    }
  }
}
