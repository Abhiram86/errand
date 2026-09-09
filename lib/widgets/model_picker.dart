import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/llm_provider.dart';
import '../models/model_option.dart';
import '../services/app_settings.dart';
import '../services/model_catalog.dart';
import '../theme/app_colors.dart';

class ModelPicker extends StatelessWidget {
  final String selectedModel;
  final List<ModelOption> models;
  final ValueChanged<String> onChanged;
  final bool enabled;
  final bool expand;
  final String? providerName;
  final List<LlmProvider>? providers;
  final LlmProvider? activeProvider;
  final Future<List<ModelOption>> Function(LlmProvider)? onProviderChanged;
  final VoidCallback? onManageProviders;
  final Future<void> Function()? onRefresh;

  const ModelPicker({
    super.key,
    required this.selectedModel,
    required this.models,
    required this.onChanged,
    this.enabled = true,
    this.expand = false,
    this.providerName,
    this.providers,
    this.activeProvider,
    this.onProviderChanged,
    this.onManageProviders,
    this.onRefresh,
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
          width: expand ? double.infinity : math.min(maxWidth, 280),
          child: Row(
            children: [
              Expanded(
                child: _ScrollingModelName(
                  name: selected.name,
                  color: enabled ? kText : kMuted,
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
      builder: (dialogContext) => _ModelPickerDialog(
        options: options,
        selectedModel: selectedModel,
        providerName: providerName ?? activeProvider?.name,
        providers: providers,
        activeProvider: activeProvider,
        onProviderChanged: onProviderChanged,
        onManageProviders: onManageProviders,
        onRefresh: onRefresh,
      ),
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
      provider: providerName ?? activeProvider?.name ?? 'Configured model',
    );
  }
}

class _ScrollingModelName extends StatefulWidget {
  final String name;
  final Color color;

  const _ScrollingModelName({required this.name, required this.color});

  @override
  State<_ScrollingModelName> createState() => _ScrollingModelNameState();
}

class _ScrollingModelNameState extends State<_ScrollingModelName>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _curvedAnimation;
  bool _shouldAnimate = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 7),
    );
    _curvedAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOut,
    );
  }

  @override
  void dispose() {
    _curvedAnimation.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _ScrollingModelName oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.name != widget.name) {
      _controller
        ..reset()
        ..stop();
      _shouldAnimate = false;
    }
  }

  void _syncAnimation(bool shouldAnimate) {
    if (_shouldAnimate == shouldAnimate) return;
    _shouldAnimate = shouldAnimate;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (shouldAnimate) {
        if (!_controller.isAnimating) _controller.repeat(reverse: true);
      } else {
        if (_controller.isAnimating) _controller.stop();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: widget.color,
      fontSize: 14,
      fontWeight: FontWeight.w600,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.name, style: style),
          maxLines: 1,
          textDirection: Directionality.of(context),
        )..layout();

        final overflow = painter.width - constraints.maxWidth;
        final shouldAnimate = overflow > 0 && constraints.maxWidth > 0;

        _syncAnimation(shouldAnimate);

        if (!shouldAnimate) {
          return Text(
            widget.name,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.clip,
            style: style,
          );
        }

        return ClipRect(
          child: AnimatedBuilder(
            animation: _curvedAnimation,
            builder: (context, child) {
              final offset = overflow * _controller.value;
              return Transform.translate(
                offset: Offset(-offset, 0),
                child: child,
              );
            },
            child: SizedBox(
              width: painter.width,
              child: Text(
                widget.name,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.visible,
                style: style,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ModelPickerDialog extends StatefulWidget {
  final List<ModelOption> options;
  final String selectedModel;
  final String? providerName;
  final List<LlmProvider>? providers;
  final LlmProvider? activeProvider;
  final Future<List<ModelOption>> Function(LlmProvider)? onProviderChanged;
  final VoidCallback? onManageProviders;
  final Future<void> Function()? onRefresh;

  const _ModelPickerDialog({
    required this.options,
    required this.selectedModel,
    this.providerName,
    this.providers,
    this.activeProvider,
    this.onProviderChanged,
    this.onManageProviders,
    this.onRefresh,
  });

  @override
  State<_ModelPickerDialog> createState() => _ModelPickerDialogState();
}

class _ModelPickerDialogState extends State<_ModelPickerDialog> {
  late final TextEditingController _searchController;
  String _query = '';
  bool _refreshing = false;
  LlmProvider? _currentProvider;
  late String _currentSelectedModel;
  late List<ModelOption> _currentOptions;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController()..addListener(_onSearchChanged);
    final provider = widget.activeProvider ??
        (widget.providers != null && widget.providers!.isNotEmpty
            ? widget.providers!.first
            : null);
    _currentProvider = provider;
    _currentSelectedModel = widget.selectedModel;

    final cached = provider != null
        ? ModelCatalogService.getCachedModels(provider.baseUrl)
        : null;
    if (cached != null && cached.isNotEmpty) {
      _currentOptions = List.of(cached);
    } else {
      _currentOptions = List.of(widget.options);
    }

    if (cached == null && _currentProviderHasKey) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _handleRefresh();
      });
    }
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

  bool get _currentProviderHasKey {
    if (_currentProvider == null) return true;
    if (_currentProvider!.hasKey) return true;
    if (_currentProvider!.id == ProviderPresetType.openRouter.id &&
        AppSettingsService.instance.hasOpenRouterKey) {
      return true;
    }
    return false;
  }

  Future<void> _handleProviderSelected(LlmProvider provider) async {
    if (provider.id == _currentProvider?.id) return;

    final cached = ModelCatalogService.getCachedModels(provider.baseUrl);
    final initialModels = (cached != null && cached.isNotEmpty)
        ? cached
        : provider.defaultModels;

    final firstModel = initialModels.isNotEmpty
        ? initialModels.first.id
        : 'gpt-4o';

    final hasKey = provider.hasKey ||
        (provider.id == ProviderPresetType.openRouter.id &&
            AppSettingsService.instance.hasOpenRouterKey);
    final needsFetch = cached == null && hasKey;

    setState(() {
      _currentProvider = provider;
      _currentSelectedModel = firstModel;
      _currentOptions = initialModels;
      _refreshing = needsFetch;
    });

    if (widget.onProviderChanged != null) {
      final updated = await widget.onProviderChanged!(provider);
      if (mounted && _currentProvider?.id == provider.id) {
        setState(() {
          if (updated.isNotEmpty) {
            _currentOptions = updated;
          }
          _refreshing = false;
        });
      }
    } else if (needsFetch) {
      final apiKey = provider.id == ProviderPresetType.openRouter.id
          ? (provider.apiKey ?? AppSettingsService.instance.openRouterKey ?? '')
          : (provider.apiKey ?? '');
      try {
        final models = await ModelCatalogService().load(
          baseUrl: provider.baseUrl.isNotEmpty ? provider.baseUrl : provider.defaultBaseUrl,
          apiKey: apiKey,
          defaultProvider: provider.name,
          isOpenRouter: provider.id == ProviderPresetType.openRouter.id ||
              provider.baseUrl.contains('openrouter.ai'),
        );
        if (mounted && _currentProvider?.id == provider.id) {
          setState(() {
            _currentOptions = models;
            _refreshing = false;
          });
        }
      } catch (_) {
        if (mounted && _currentProvider?.id == provider.id) {
          setState(() => _refreshing = false);
        }
      }
    } else {
      if (mounted) {
        setState(() => _refreshing = false);
      }
    }
  }

  List<ModelOption> get _filteredOptions {
    final opts = [
      ..._currentOptions,
      if (!_currentOptions.any((m) => m.id == _currentSelectedModel))
        ModelOption(
          id: _currentSelectedModel,
          name: _currentSelectedModel,
          provider: _currentProvider?.name ??
              widget.providerName ??
              'Configured model',
        ),
    ];
    if (_query.isEmpty) return opts;
    return [
      for (final model in opts)
        if ('${model.name} ${model.provider} ${model.id}'
            .toLowerCase()
            .contains(_query))
          model,
    ];
  }

  Future<void> _handleRefresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    final provider = _currentProvider ?? widget.activeProvider;
    try {
      if (widget.onRefresh != null) {
        await widget.onRefresh!();
      }
      if (provider != null) {
        var cached = ModelCatalogService.getCachedModels(provider.baseUrl);
        if ((cached == null || cached.isEmpty) && _currentProviderHasKey) {
          final apiKey = provider.id == ProviderPresetType.openRouter.id
              ? (provider.apiKey ?? AppSettingsService.instance.openRouterKey ?? '')
              : (provider.apiKey ?? '');
          try {
            cached = await ModelCatalogService().load(
              baseUrl: provider.baseUrl.isNotEmpty ? provider.baseUrl : provider.defaultBaseUrl,
              apiKey: apiKey,
              defaultProvider: provider.name,
              isOpenRouter: provider.id == ProviderPresetType.openRouter.id ||
                  provider.baseUrl.contains('openrouter.ai'),
              forceRefresh: true,
            );
          } catch (_) {}
        }
        if (mounted && cached != null && cached.isNotEmpty) {
          setState(() {
            _currentOptions = cached!;
          });
        }
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _showCustomModelPrompt(BuildContext context) async {
    final navigator = Navigator.of(context);
    final controller = TextEditingController();
    final modelId = await showDialog<String>(
      context: context,
      builder: (promptCtx) => AlertDialog(
        backgroundColor: kDarkBg,
        title: const Text('Add Custom Model',
            style: TextStyle(color: kText, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter the model identifier slug (e.g. claude-3-7-sonnet, deepseek-chat):',
              style: TextStyle(color: kMuted, fontSize: 12),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: controller,
              autofocus: true,
              style: const TextStyle(color: kText, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'model-id-slug',
                hintStyle: const TextStyle(color: kMuted),
                filled: true,
                fillColor: kInputBg,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: kBorder),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(promptCtx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final text = controller.text.trim();
              if (text.isNotEmpty) Navigator.of(promptCtx).pop(text);
            },
            child: const Text('Select'),
          ),
        ],
      ),
    );

    if (modelId != null && modelId.isNotEmpty && mounted) {
      navigator.pop(modelId);
    }
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
        height: size.height * 0.74,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 10, 12),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Choose a model',
                          style: TextStyle(
                            color: kText,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          _currentProvider?.name ??
                              widget.providerName ??
                              'Active Provider',
                          style: const TextStyle(
                            color: kBubbleUser,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (widget.onRefresh != null)
                    IconButton(
                      onPressed: _refreshing ? null : _handleRefresh,
                      tooltip: 'Refresh catalog',
                      icon: _refreshing
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh_rounded, size: 19),
                      color: kMuted,
                      splashRadius: 20,
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
              if (widget.providers != null && widget.providers!.isNotEmpty) ...[
                const SizedBox(height: 8),
                SizedBox(
                  height: 32,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: widget.providers!.length +
                        (widget.onManageProviders != null ? 1 : 0),
                    separatorBuilder: (_, _) => const SizedBox(width: 6),
                    itemBuilder: (context, index) {
                      if (index == widget.providers!.length) {
                        return ActionChip(
                          avatar: const Icon(Icons.settings_outlined,
                              size: 13, color: kMuted),
                          label: const Text('Manage',
                              style: TextStyle(color: kMuted, fontSize: 11)),
                          backgroundColor: kDarkBg,
                          side: const BorderSide(color: kBorder),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          onPressed: () {
                            Navigator.of(context).pop();
                            widget.onManageProviders?.call();
                          },
                        );
                      }

                      final p = widget.providers![index];
                      final isSelected = p.id == _currentProvider?.id;
                      final hasKey = p.hasKey ||
                          (p.id == ProviderPresetType.openRouter.id &&
                              AppSettingsService.instance.hasOpenRouterKey);

                      return ChoiceChip(
                        showCheckmark: false,
                        selected: isSelected,
                        label: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              p.name,
                              style: TextStyle(
                                color: isSelected ? Colors.white : kText,
                                fontSize: 12,
                                fontWeight: isSelected
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                            ),
                            if (!hasKey) ...[
                              const SizedBox(width: 5),
                              Container(
                                width: 6,
                                height: 6,
                                decoration: const BoxDecoration(
                                  color: Colors.amber,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ],
                          ],
                        ),
                        selectedColor: kBubbleUser,
                        backgroundColor: kDarkBg,
                        side: BorderSide(
                          color: isSelected ? kBubbleUser : kBorder,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        onSelected: (_) => _handleProviderSelected(p),
                      );
                    },
                  ),
                ),
                if (!_currentProviderHasKey && _currentProvider != null) ...[
                  const SizedBox(height: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.amber.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                      border:
                          Border.all(color: Colors.amber.withValues(alpha: 0.25)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline,
                            size: 14, color: Colors.amber),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'No API key set for ${_currentProvider!.name}.',
                            style: const TextStyle(
                                color: Colors.amber, fontSize: 11),
                          ),
                        ),
                        if (widget.onManageProviders != null)
                          GestureDetector(
                            onTap: () {
                              Navigator.of(context).pop();
                              widget.onManageProviders?.call();
                            },
                            child: const Text(
                              'Configure',
                              style: TextStyle(
                                color: Colors.amber,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                decoration: TextDecoration.underline,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
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
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: () => _showCustomModelPrompt(context),
                    tooltip: 'Add custom model',
                    icon: const Icon(Icons.add_rounded, size: 20),
                    style: IconButton.styleFrom(
                      backgroundColor: kDarkBg,
                      foregroundColor: kText,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Expanded(
                child: filteredOptions.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              'No matching models',
                              style: TextStyle(color: kMuted, fontSize: 13),
                            ),
                            const SizedBox(height: 8),
                            TextButton.icon(
                              onPressed: () => _showCustomModelPrompt(context),
                              icon: const Icon(Icons.add, size: 16),
                              label: const Text('Use custom model slug'),
                            ),
                          ],
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
                          final isSelected = model.id == _currentSelectedModel;
                          final hasVision = model.supportsInput('image');

                          return ListTile(
                            dense: true,
                            visualDensity: const VisualDensity(vertical: -2),
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
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    model.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: kText,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                if (hasVision)
                                  const Padding(
                                    padding: EdgeInsets.only(left: 4),
                                    child: Icon(
                                      Icons.image_outlined,
                                      size: 14,
                                      color: kMuted,
                                    ),
                                  ),
                              ],
                            ),
                            subtitle: Text(
                              '${model.provider} • ${model.id}',
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
