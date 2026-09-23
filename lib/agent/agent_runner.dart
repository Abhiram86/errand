import 'dart:io';
import 'package:flutter/foundation.dart';

import '../llm/llm_client.dart';
import '../services/app_settings.dart';
import '../services/browser_service.dart';
import '../services/database.dart';
import '../services/location_service.dart';
import '../services/memory_service.dart';
import '../services/model_catalog.dart';
import '../services/shell_service.dart';
import '../services/task_scheduler_service.dart';
import '../services/workspace.dart';
import '../tools/file_tools.dart';
import '../tools/headless/report_tool.dart';
import '../types/conversation.dart';
import '../types/message.dart';
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

  /// Executes an isolated, headless background agent turn for a scheduled task.
  ///
  /// Disallows UI tools, enforces task ID isolation, generates output reports
  /// in the scratch directory, and cleanly releases tool resources on completion.
  Future<HeadlessRunResult> runHeadless({
    required int taskId,
    required String prompt,
    String? taskTitle,
    Directory? scratchDirectory,
    MemoryService? memoryService,
    BrowserService? browserService,
    LocationService? locationService,
    ErrandDatabase? db,
    TaskSchedulerService? schedulerService,
    CancelToken? cancelToken,
    AgentObserver? onEvent,
    AgentTextObserver? onTextDelta,
    AgentReasoningObserver? onReasoningDelta,
    void Function()? onReset,
    AgentRetryObserver? onRetry,
  }) async {
    final scratch = scratchDirectory ?? Workspace.instance.scratchDir;
    final token = cancelToken ?? this.cancelToken;
    final baseUrl = effectiveBaseUrl ?? llm.config.baseUrl;
    final runStartMillis = DateTime.now().millisecondsSinceEpoch;
    final reportCollector = HeadlessReportCollector();
    // Route headless turns through the streaming path even when nobody
    // observes deltas: it carries the longer timeout, stall watchdog, and
    // progress-based retries that the single-shot path lacks.
    final textSink = onTextDelta ?? (_) {};

    final registry = ToolRegistry.headless(
      currentDir: workingDirectory.root,
      workingDirectory: workingDirectory,
      currentTaskId: taskId,
      supportsInput: (modality) =>
          ModelCatalogService.supportsInput(
            selectedModel,
            modality,
            baseUrl: baseUrl,
          ) !=
          false,
      getCancelToken: token != null ? () => token : null,
      memoryService: memoryService,
      browserService: browserService,
      locationService: locationService,
      db: db,
      schedulerService: schedulerService,
      scratchDirectory: scratch,
      reportCollector: reportCollector,
      runStartedAtMillis: runStartMillis,
    );

    final activeBudget = budget ??
        ContextBudget(
          contextSize: ModelCatalogService.getContextLength(
            selectedModel,
            baseUrl: baseUrl,
          ),
        );

    final loop = AgentLoop(
      llm: llm,
      registry: registry,
      budget: activeBudget,
      systemPromptBuilder: () => headlessSystemPromptFor(
        currentDir: workingDirectory.current,
        scratchDir: scratch,
        taskId: taskId,
        taskTitle: taskTitle,
        locationSummary: locationService?.lastKnown?.toCoarseSummary() ??
            LocationService.instance.lastKnown?.toCoarseSummary(),
      ),
      cancelToken: token,
      supportsInput: (modality) =>
          ModelCatalogService.supportsInput(
            selectedModel,
            modality,
            baseUrl: baseUrl,
          ) !=
          false,
      onEvent: onEvent,
      onTextDelta: textSink,
      onReasoningDelta: onReasoningDelta,
      onReset: onReset,
      onRetry: onRetry,
    );

    final nowIso = DateTime.now().toIso8601String().replaceAll(':', '-');
    final conversation = Conversation(
      id: 'headless_task_${taskId}_$nowIso',
      currentDir: workingDirectory.current,
      messages: [
        UserMessage(
          id: 'prompt_$nowIso',
          text: prompt,
        ),
      ],
      model: selectedModel,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    try {
      final output = await loop.run(conversation);
      String? reportPath;
      try {
        // Primary: the save_report tool saved a file during the turn.
        final collected = reportCollector.reportPath;
        if (collected != null && File(collected).existsSync()) {
          reportPath = collected;
        } else {
          // Fallback: persist the final answer text to the default path.
          if (!scratch.existsSync()) {
            scratch.createSync(recursive: true);
          }
          final reportFile =
              File('${scratch.path}/task-$taskId-$runStartMillis.md');
          await reportFile.writeAsString(output);
          reportPath = reportFile.path;
        }
      } catch (e, st) {
        debugPrint('Failed to save headless task report: $e\n$st');
      }

      return HeadlessRunResult(
        ok: true,
        output: output,
        reportPath: reportPath,
      );
    } catch (e) {
      return HeadlessRunResult(
        ok: false,
        output: '',
        errorMessage: e.toString(),
      );
    } finally {
      registry.dispose();
    }
  }

  /// Disposes resources held by this runner.
  void dispose() {
    llm.close();
  }
}

/// The result of an autonomous headless background execution turn.
class HeadlessRunResult {
  final bool ok;
  final String output;
  final String? reportPath;
  final String? errorMessage;

  const HeadlessRunResult({
    required this.ok,
    required this.output,
    this.reportPath,
    this.errorMessage,
  });
}

