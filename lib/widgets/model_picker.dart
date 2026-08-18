import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/model_option.dart';
import '../theme/app_colors.dart';

class ModelPicker extends StatelessWidget {
  final String selectedModel;
  final List<ModelOption> models;
  final ValueChanged<String> onChanged;
  final bool enabled;

  const ModelPicker({
    super.key,
    required this.selectedModel,
    required this.models,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final selected = _findSelectedModel();
    final options = [
      ...models,
      if (!models.any((model) => model.id == selectedModel)) selected,
    ];
    final maxWidth = math.max(0.0, MediaQuery.of(context).size.width - 32);

    return Semantics(
      button: true,
      enabled: enabled,
      label: 'Select model',
      child: GestureDetector(
        onTap: enabled ? () => _openModelDialog(context, options) : null,
        child: SizedBox(
          width: math.min(maxWidth, 280),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  selected.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: enabled ? kText : kMuted,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                color: enabled ? kMuted : kMuted.withValues(alpha: 0.5),
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openModelDialog(
    BuildContext context,
    List<ModelOption> options,
  ) async {
    final model = await showDialog<String>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.68),
      builder: (dialogContext) =>
          _ModelPickerDialog(options: options, selectedModel: selectedModel),
    );
    if (model != null && model != selectedModel) onChanged(model);
  }

  ModelOption _findSelectedModel() {
    for (final model in models) {
      if (model.id == selectedModel) return model;
    }
    return ModelOption(
      id: selectedModel,
      name: selectedModel,
      provider: 'Configured model',
    );
  }
}

class _ModelPickerDialog extends StatefulWidget {
  final List<ModelOption> options;
  final String selectedModel;

  const _ModelPickerDialog({
    required this.options,
    required this.selectedModel,
  });

  @override
  State<_ModelPickerDialog> createState() => _ModelPickerDialogState();
}

class _ModelPickerDialogState extends State<_ModelPickerDialog> {
  late final TextEditingController _searchController;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController()..addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController
      ..removeListener(_onSearchChanged)
      ..dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    final query = _searchController.text.trim().toLowerCase();
    if (query == _query) return;
    setState(() => _query = query);
  }

  List<ModelOption> get _filteredOptions {
    if (_query.isEmpty) return widget.options;
    return [
      for (final model in widget.options)
        if ('${model.name} ${model.provider} ${model.id}'
            .toLowerCase()
            .contains(_query))
          model,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final filteredOptions = _filteredOptions;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      backgroundColor: kInputBg,
      elevation: 12,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: math.min(size.width - 40, 480),
        height: size.height * 0.65,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 10, 12),
          child: Column(
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Choose a model',
                      style: TextStyle(
                        color: kText,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: 'Close',
                    icon: const Icon(Icons.close, size: 19),
                    color: kMuted,
                    splashRadius: 20,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              TextField(
                controller: _searchController,
                autofocus: true,
                maxLines: 1,
                style: const TextStyle(color: kText, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Search models',
                  hintStyle: const TextStyle(color: kMuted),
                  prefixIcon: const Icon(Icons.search, size: 19),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          onPressed: _searchController.clear,
                          icon: const Icon(Icons.clear, size: 17),
                          tooltip: 'Clear search',
                        ),
                  filled: true,
                  fillColor: kDarkBg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: filteredOptions.isEmpty
                    ? const Center(
                        child: Text(
                          'No matching models',
                          style: TextStyle(color: kMuted, fontSize: 13),
                        ),
                      )
                    : ListView.separated(
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        padding: EdgeInsets.zero,
                        itemCount: filteredOptions.length,
                        separatorBuilder: (context, index) =>
                            const SizedBox(height: 2),
                        itemBuilder: (context, index) {
                          final model = filteredOptions[index];
                          final isSelected = model.id == widget.selectedModel;
                          return ListTile(
                            dense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 0,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            selected: isSelected,
                            selectedTileColor: kBubbleAssistant,
                            onTap: () => Navigator.of(context).pop(model.id),
                            title: Text(
                              model.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: kText,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: Text(
                              model.provider,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: kMuted,
                                fontSize: 11,
                              ),
                            ),
                            trailing: isSelected
                                ? const Icon(
                                    Icons.check_rounded,
                                    color: kBubbleUser,
                                    size: 19,
                                  )
                                : null,
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
