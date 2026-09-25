import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';

import '../../models/llm_provider.dart';
import '../../models/model_option.dart';
import '../../services/app_settings.dart';
import '../../services/database.dart';
import '../../services/model_catalog.dart';
import '../../services/task_scheduler_service.dart';
import '../../theme/app_colors.dart';
import '../model_picker_dialog.dart';

/// Bottom Sheet to Edit Settings (Schedule Type, Notifications, Provider & Model) for a Task.
class EditTaskModelSheet extends StatefulWidget {
  final SchedulerTaskRow task;
  final ErrandDatabase db;

  const EditTaskModelSheet({
    super.key,
    required this.task,
    required this.db,
  });

  @override
  State<EditTaskModelSheet> createState() => _EditTaskModelSheetState();
}

class _EditTaskModelSheetState extends State<EditTaskModelSheet> {
  late final AppSettingsService _settings;
  late String _taskType;
  int? _repeatAfter;
  late bool _notify;
  String? _selectedProviderId;
  String _selectedModel = '';
  List<ModelOption> _models = [];
  bool _loadingModels = false;
  bool _customModelMode = false;
  late final TextEditingController _customModelController;
  late final TextEditingController _titleController;
  bool _saving = false;
  // Set once the user picks anything; guards the settings-ready refresh
  // below from clobbering an in-progress choice.
  bool _userTouchedSelection = false;

  static const _standardIntervals = <({int millis, String label})>[
    (millis: 15 * 60 * 1000, label: 'Every 15 min'),
    (millis: 30 * 60 * 1000, label: 'Every 30 min'),
    (millis: 60 * 60 * 1000, label: 'Every 1 hr'),
    (millis: 2 * 60 * 60 * 1000, label: 'Every 2 hrs'),
    (millis: 6 * 60 * 60 * 1000, label: 'Every 6 hrs'),
    (millis: 12 * 60 * 60 * 1000, label: 'Every 12 hrs'),
    (millis: 24 * 60 * 60 * 1000, label: 'Daily (24 hrs)'),
  ];

  List<({int millis, String label})> get _repeatIntervalOptions {
    final list = List<({int millis, String label})>.from(_standardIntervals);
    final cur = _repeatAfter;
    if (cur != null && cur > 0 && !list.any((opt) => opt.millis == cur)) {
      final label = cur >= 60000
          ? 'Every ${cur ~/ 60000} min (custom)'
          : 'Every ${cur ~/ 1000}s (custom)';
      list.insert(0, (millis: cur, label: label));
    }
    return list;
  }

  /// Single source of truth for the interval: always positive, defaults to 15 min.
  int get _effectiveRepeatAfter {
    final cur = _repeatAfter;
    if (cur != null && cur > 0) return cur;
    return 15 * 60 * 1000;
  }

  @override
  void initState() {
    super.initState();
    _settings = AppSettingsService.instance;
    _taskType = widget.task.type;
    _repeatAfter = widget.task.repeatAfter ?? (15 * 60 * 1000);
    _notify = widget.task.notify;
    _titleController = TextEditingController(text: widget.task.title);

    _resolveInitialSelection();
    _customModelController = TextEditingController(text: _selectedModel);
    _customModelController.addListener(_markSelectionTouched);

    _loadModelsForProvider(_selectedProviderId);

    // Cold-tap path can open this sheet before settings finish loading,
    // leaving provider/model resolved from empty defaults. Re-resolve once
    // settings are ready unless the user already chose something.
    unawaited(AppSettingsService.instance.ensureLoaded().then((_) {
      if (!mounted || _userTouchedSelection) return;
      final prevProvider = _selectedProviderId;
      final prevModel = _selectedModel;
      _resolveInitialSelection();
      if (_selectedProviderId == prevProvider &&
          _selectedModel == prevModel) {
        return;
      }
      _customModelController.text = _selectedModel;
      if (!mounted) return;
      setState(() {});
      if (_selectedProviderId != prevProvider) {
        _loadModelsForProvider(_selectedProviderId);
      }
    }).catchError((_) {}));
  }

  void _markSelectionTouched() {
    _userTouchedSelection = true;
  }

  /// Resolves provider/model from task payload with global fallbacks.
  /// No setState: callers handle notifying (initState runs pre-build).
  void _resolveInitialSelection() {
    String initialModel = '';
    String? initialProvider;
    try {
      final payload = jsonDecode(widget.task.payloadJson) as Map<String, dynamic>;
      initialModel = (payload['model'] as String?)?.trim() ?? '';
      initialProvider = (payload['providerId'] as String?)?.trim();
    } catch (_) {}

    if (initialModel.isEmpty) {
      initialModel = _settings.selectedModel;
    }
    _selectedModel = initialModel;
    // Normalize the provider up front so display and save always agree:
    // fall back to the active (or first) provider when the stored id is gone.
    var resolvedProvider = initialProvider ?? _settings.activeProviderId;
    final knownIds = _settings.providers.map((p) => p.id).toSet();
    if (!knownIds.contains(resolvedProvider)) {
      resolvedProvider = knownIds.contains(_settings.activeProviderId)
          ? _settings.activeProviderId
          : (_settings.providers.isNotEmpty
              ? _settings.providers.first.id
              : _settings.activeProviderId);
    }
    _selectedProviderId = resolvedProvider;
  }

  @override
  void dispose() {
    _customModelController.dispose();
    _titleController.dispose();
    super.dispose();
  }

  Future<void> _loadModelsForProvider(String? providerId,
      {bool resetModelIfMissing = false}) async {
    if (providerId == null) return;
    final provider = _settings.providers.firstWhere(
      (p) => p.id == providerId,
      orElse: () => _settings.activeProvider,
    );

    final cached = ModelCatalogService.getCachedModels(provider.baseUrl);
    final fallbackList = List<ModelOption>.from(
      (cached != null && cached.isNotEmpty) ? cached : provider.defaultModels,
    )..sort(ModelOption.compareByReleaseDate);

    setState(() {
      _models = fallbackList;
      _loadingModels = cached == null;
      // Switching provider orphaned the selected model: follow the provider
      // instead of persisting a model that doesn't belong to it.
      if (resetModelIfMissing &&
          _selectedModel.isNotEmpty &&
          !fallbackList.any((m) => m.id == _selectedModel) &&
          fallbackList.isNotEmpty) {
        _selectedModel = fallbackList.first.id;
      }
    });

    final hasKey = provider.hasKey ||
        (provider.id == ProviderPresetType.openRouter.id && _settings.hasOpenRouterKey);

    if (cached == null && hasKey) {
      final apiKey = provider.id == ProviderPresetType.openRouter.id
          ? (provider.apiKey ?? _settings.openRouterKey ?? '')
          : (provider.apiKey ?? '');
      try {
        final fetched = await ModelCatalogService.fetchAndClose(
          baseUrl: provider.baseUrl.isNotEmpty ? provider.baseUrl : provider.defaultBaseUrl,
          apiKey: apiKey,
          defaultProvider: provider.name,
          isOpenRouter: provider.id == ProviderPresetType.openRouter.id ||
              provider.baseUrl.contains('openrouter.ai'),
        );
        if (mounted && _selectedProviderId == providerId) {
          final sorted = List<ModelOption>.from(fetched)..sort(ModelOption.compareByReleaseDate);
          setState(() {
            _models = sorted;
            _loadingModels = false;
            if (resetModelIfMissing &&
                _selectedModel.isNotEmpty &&
                !sorted.any((m) => m.id == _selectedModel) &&
                sorted.isNotEmpty) {
              _selectedModel = sorted.first.id;
            }
          });
        }
      } catch (_) {
        if (mounted) setState(() => _loadingModels = false);
      }
    } else {
      if (mounted) setState(() => _loadingModels = false);
    }
  }

  Future<void> _save() async {
    final finalModel = _customModelMode
        ? _customModelController.text.trim()
        : _selectedModel.trim();
    if (finalModel.isEmpty || _saving) return;

    final newTitle = _titleController.text.trim();
    if (newTitle.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Task title cannot be empty'),
          backgroundColor: kDanger,
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    final now = DateTime.now().millisecondsSinceEpoch;

    // Fetch the freshest row from DB to avoid any stale data overwrites
    final freshTask = await (widget.db.select(widget.db.schedulerTasks)
          ..where((t) => t.id.equals(widget.task.id)))
        .getSingleOrNull();
    if (freshTask == null) {
      if (!mounted) return;
      setState(() => _saving = false);
      Navigator.of(context).pop();
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Task was deleted'),
          backgroundColor: kDanger,
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    Map<String, dynamic> payload = {};
    try {
      payload = jsonDecode(freshTask.payloadJson) as Map<String, dynamic>;
    } catch (_) {}

    payload['model'] = finalModel;
    if (_selectedProviderId != null && _selectedProviderId!.isNotEmpty) {
      payload['providerId'] = _selectedProviderId;
    }

    try {
      final newPayloadJson = jsonEncode(payload);

      // Status/timing transitions come from the tested helper so the sheet
      // can never persist a combination the scheduler doesn't understand
      // (e.g. failed + future nextRun with no alarm).
      final transition = TaskSchedulerService.computeEditTransition(
        oldType: freshTask.type,
        oldStatus: freshTask.status,
        oldNextRunAt: freshTask.nextRunAt,
        oldRepeatAfter: freshTask.repeatAfter,
        newType: _taskType,
        newRepeatAfter: _effectiveRepeatAfter,
        startsAt: freshTask.startsAt,
        nowMillis: now,
      );
      final int? nextRun = transition.nextRunAt;
      final String newStatus = transition.status;

      await (widget.db.update(widget.db.schedulerTasks)..where((t) => t.id.equals(widget.task.id))).write(
        SchedulerTasksCompanion(
          title: Value(newTitle),
          type: Value(_taskType),
          repeatAfter: Value(transition.repeatAfter),
          status: Value(newStatus),
          notify: Value(_notify),
          nextRunAt: Value(nextRun),
          payloadJson: Value(newPayloadJson),
          updatedAt: Value(now),
        ),
      );

      if (newStatus == 'scheduled') {
        await TaskSchedulerService.instance.scheduleTask(widget.task.id);
      }

      if (!mounted) return;
      Navigator.of(context).pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text('Updated settings for Task #${widget.task.id}'),
          backgroundColor: kBubbleUser,
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(
        SnackBar(
          content: Text('Failed to save settings: $e'),
          backgroundColor: kDanger,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  String get _selectedModelDisplayName {
    if (_selectedModel.isEmpty) return 'Select model (tap to search)';
    final match = _models.where((m) => m.id == _selectedModel).firstOrNull;
    if (match != null && match.name.isNotEmpty && match.name != match.id) {
      return '${match.name} (${match.id})';
    }
    return _selectedModel;
  }

  Widget _buildTypeOption({
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
        decoration: BoxDecoration(
          color: selected
              ? kBubbleUser.withValues(alpha: 0.15)
              : kInputBg.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? kBubbleUser : Colors.transparent,
            width: 1.2,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 15,
              color: selected ? kBubbleUser : kMuted,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: selected ? kText : kMuted,
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final providers = _settings.providers;
    final activeProviderId = providers.any((p) => p.id == _selectedProviderId)
        ? _selectedProviderId
        : (providers.isNotEmpty ? providers.first.id : null);

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.90,
      ),
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 14,
          bottom: MediaQuery.of(context).viewInsets.bottom + 14,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.tune_rounded, color: kBubbleUser, size: 19),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Task Settings (#${widget.task.id})',
                      style: const TextStyle(
                        color: kText,
                        fontSize: 15.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: kMuted, size: 20),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // Task Title
              const Text(
                'Task Title',
                style: TextStyle(color: kMuted, fontSize: 11, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Container(
                height: 42,
                decoration: BoxDecoration(
                  color: kInputBg.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: TextField(
                  controller: _titleController,
                  style: const TextStyle(color: kText, fontSize: 12.5),
                  decoration: InputDecoration(
                    hintText: 'Enter task title...',
                    hintStyle: TextStyle(color: kMuted.withValues(alpha: 0.5), fontSize: 12.5),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                  ),
                ),
              ),
              const SizedBox(height: 10),

              // Schedule Type
              const Text(
                'Schedule Type',
                style: TextStyle(color: kMuted, fontSize: 11, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: _buildTypeOption(
                      label: 'One-off',
                      icon: Icons.bolt_rounded,
                      selected: _taskType == 'one_off',
                      onTap: () => setState(() => _taskType = 'one_off'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildTypeOption(
                      label: 'Recurring',
                      icon: Icons.repeat_rounded,
                      selected: _taskType == 'recurring',
                      onTap: () => setState(() {
                        _taskType = 'recurring';
                        _repeatAfter ??= 15 * 60 * 1000;
                      }),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // Repeat Interval & Notifications (combined side-by-side if recurring)
              if (_taskType == 'recurring') ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 5,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Repeat Interval',
                            style: TextStyle(color: kMuted, fontSize: 11, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 4),
                          Container(
                            height: 42,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            decoration: BoxDecoration(
                              color: kInputBg.withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<int>(
                                value: _effectiveRepeatAfter,
                                dropdownColor: kInputBg,
                                icon: const Icon(Icons.arrow_drop_down_rounded, color: kMuted),
                                isExpanded: true,
                                isDense: true,
                                items: _repeatIntervalOptions.map((opt) {
                                  return DropdownMenuItem<int>(
                                    value: opt.millis,
                                    child: Text(
                                      opt.label,
                                      style: const TextStyle(color: kText, fontSize: 12.5),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  );
                                }).toList(),
                                onChanged: (val) {
                                  if (val != null) {
                                    setState(() => _repeatAfter = val);
                                  }
                                },
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 4,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Notifications',
                            style: TextStyle(color: kMuted, fontSize: 11, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 4),
                          InkWell(
                            onTap: () => setState(() => _notify = !_notify),
                            borderRadius: BorderRadius.circular(10),
                            child: Container(
                              height: 42,
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              decoration: BoxDecoration(
                                color: kInputBg.withValues(alpha: 0.5),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    _notify ? Icons.notifications_active_rounded : Icons.notifications_off_outlined,
                                    color: _notify ? kBubbleUser : kMuted,
                                    size: 17,
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      _notify ? 'On' : 'Off',
                                      style: TextStyle(
                                        color: _notify ? kText : kMuted,
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                  Transform.scale(
                                    scale: 0.75,
                                    child: Switch.adaptive(
                                      value: _notify,
                                      activeTrackColor: kBubbleUser,
                                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                      onChanged: (val) => setState(() => _notify = val),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ] else ...[
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Notifications',
                      style: TextStyle(color: kMuted, fontSize: 11, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    InkWell(
                      onTap: () => setState(() => _notify = !_notify),
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        height: 42,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        decoration: BoxDecoration(
                          color: kInputBg.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              _notify ? Icons.notifications_active_rounded : Icons.notifications_off_outlined,
                              color: _notify ? kBubbleUser : kMuted,
                              size: 17,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _notify ? 'Notifications enabled' : 'Notifications disabled',
                                style: TextStyle(
                                  color: _notify ? kText : kMuted,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                            Transform.scale(
                              scale: 0.75,
                              child: Switch.adaptive(
                                value: _notify,
                                activeTrackColor: kBubbleUser,
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                onChanged: (val) => setState(() => _notify = val),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 10),

              // Provider selector
              const Text(
                'LLM Provider',
                style: TextStyle(color: kMuted, fontSize: 11, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Container(
                height: 42,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: kInputBg.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: activeProviderId,
                    dropdownColor: kInputBg,
                    icon: const Icon(Icons.arrow_drop_down_rounded, color: kMuted),
                    isExpanded: true,
                    isDense: true,
                    items: providers.map((p) {
                      return DropdownMenuItem<String>(
                        value: p.id,
                        child: Text(
                          p.name,
                          style: const TextStyle(color: kText, fontSize: 12.5),
                        ),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) {
                        setState(() {
                          _selectedProviderId = val;
                          _customModelMode = false;
                          _userTouchedSelection = true;
                        });
                        _loadModelsForProvider(val, resetModelIfMissing: true);
                      }
                    },
                  ),
                ),
              ),
              const SizedBox(height: 10),

              // Model selector / text field header
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Model',
                      style: TextStyle(color: kMuted, fontSize: 11, fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (_loadingModels) ...[
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 1.5, color: kBubbleUser),
                    ),
                    const SizedBox(width: 8),
                  ],
                  InkWell(
                    onTap: () {
                      setState(() {
                        _customModelMode = !_customModelMode;
                        _userTouchedSelection = true;
                        if (_customModelMode) {
                          _customModelController.text = _selectedModel;
                        }
                      });
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      child: Text(
                        _customModelMode ? 'Pick from list' : 'Custom / ID',
                        style: const TextStyle(
                          color: kBubbleUser,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),

              if (_customModelMode) ...[
                Container(
                  height: 42,
                  decoration: BoxDecoration(
                    color: kInputBg.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: TextField(
                    controller: _customModelController,
                    style: const TextStyle(color: kText, fontSize: 12.5),
                    decoration: InputDecoration(
                      hintText: 'e.g. google/gemini-2.5-flash',
                      hintStyle: TextStyle(color: kMuted.withValues(alpha: 0.5), fontSize: 12.5),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                    ),
                  ),
                ),
              ] else ...[
                InkWell(
                  onTap: _loadingModels
                      ? null
                      : () async {
                          final provider = _settings.providers.firstWhere(
                            (p) => p.id == _selectedProviderId,
                            orElse: () => _settings.activeProvider,
                          );
                          final picked = await showModelPickerDialog(
                            context,
                            options: _models,
                            selectedModel: _selectedModel,
                            providerName: provider.name,
                            activeProvider: provider,
                          );
                          if (picked != null && mounted) {
                            setState(() {
                              _selectedModel = picked;
                              _userTouchedSelection = true;
                            });
                          }
                        },
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    height: 42,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: kInputBg.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _selectedModelDisplayName,
                            style: TextStyle(
                              color: _selectedModel.isNotEmpty ? kText : kMuted,
                              fontSize: 12.5,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (_loadingModels)
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 1.5, color: kMuted),
                          )
                        else
                          const Icon(Icons.search_rounded, color: kMuted, size: 18),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 14),

              // Save button (blocked while models load so a stale
              // selection can never be persisted for the new provider)
              ElevatedButton(
                onPressed: (_saving || _loadingModels) ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: kBubbleUser,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text(
                        'Save Changes',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
