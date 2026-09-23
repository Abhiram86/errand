import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';

import '../../models/llm_provider.dart';
import '../../models/model_option.dart';
import '../../services/app_settings.dart';
import '../../services/database.dart';
import '../../services/model_catalog.dart';
import '../../theme/app_colors.dart';
import '../model_picker_dialog.dart';

/// Bottom Sheet to Edit Provider & Model for a Task.
class EditTaskModelSheet extends StatefulWidget {
  final SchedulerTaskRow task;
  final ErrandDatabase db;
  final ValueChanged<String>? onSaved;

  const EditTaskModelSheet({
    super.key,
    required this.task,
    required this.db,
    this.onSaved,
  });

  @override
  State<EditTaskModelSheet> createState() => _EditTaskModelSheetState();
}

class _EditTaskModelSheetState extends State<EditTaskModelSheet> {
  late final AppSettingsService _settings;
  String? _selectedProviderId;
  String _selectedModel = '';
  List<ModelOption> _models = [];
  bool _loadingModels = false;
  bool _customModelMode = false;
  late final TextEditingController _customModelController;
  bool _saving = false;
  // Set once the user picks anything; guards the settings-ready refresh
  // below from clobbering an in-progress choice.
  bool _userTouchedSelection = false;

  @override
  void initState() {
    super.initState();
    _settings = AppSettingsService.instance;

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
        final fetched = await ModelCatalogService().load(
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

    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    final now = DateTime.now().millisecondsSinceEpoch;

    // Fetch the freshest row from DB to avoid any stale data overwrites
    final freshTask = await (widget.db.select(widget.db.schedulerTasks)
          ..where((t) => t.id.equals(widget.task.id)))
        .getSingleOrNull();
    if (freshTask == null) return;

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

      await (widget.db.update(widget.db.schedulerTasks)..where((t) => t.id.equals(widget.task.id))).write(
        SchedulerTasksCompanion(
          payloadJson: Value(newPayloadJson),
          updatedAt: Value(now),
        ),
      );

      widget.onSaved?.call(finalModel);

      if (!mounted) return;
      Navigator.of(context).pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text('Updated execution model for Task #${widget.task.id}'),
          backgroundColor: kBubbleUser,
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(
        SnackBar(
          content: Text('Failed to save model override: $e'),
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

  @override
  Widget build(BuildContext context) {
    final providers = _settings.providers;
    final activeProviderId = providers.any((p) => p.id == _selectedProviderId)
        ? _selectedProviderId
        : (providers.isNotEmpty ? providers.first.id : null);

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.psychology_rounded, color: kBubbleUser, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Task Model Override (#${widget.task.id})',
                  style: const TextStyle(
                    color: kText,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded, color: kMuted, size: 20),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            widget.task.title,
            style: const TextStyle(color: kMuted, fontSize: 12),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 16),

          // Provider selector
          const Text(
            'LLM Provider',
            style: TextStyle(color: kMuted, fontSize: 11, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
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
                items: providers.map((p) {
                  return DropdownMenuItem<String>(
                    value: p.id,
                    child: Text(
                      p.name,
                      style: const TextStyle(color: kText, fontSize: 13),
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
          const SizedBox(height: 14),

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
          const SizedBox(height: 6),

          if (_customModelMode) ...[
            TextField(
              controller: _customModelController,
              style: const TextStyle(color: kText, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'e.g. google/gemini-2.5-flash',
                hintStyle: TextStyle(color: kMuted.withValues(alpha: 0.5), fontSize: 13),
                filled: true,
                fillColor: kInputBg.withValues(alpha: 0.5),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
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
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
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
                          fontSize: 13,
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
          const SizedBox(height: 20),

          // Save button (blocked while models load so a stale
          // selection can never be persisted for the new provider)
          ElevatedButton(
            onPressed: (_saving || _loadingModels) ? null : _save,
            style: ElevatedButton.styleFrom(
              backgroundColor: kBubbleUser,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
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
    );
  }
}
