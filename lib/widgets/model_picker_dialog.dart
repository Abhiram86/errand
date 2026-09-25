import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/llm_provider.dart';
import '../models/model_option.dart';
import '../services/app_settings.dart';
import '../services/model_catalog.dart';
import '../theme/app_colors.dart';

/// Displays a searchable dialog to select an LLM model, with release-date sorting,
/// live catalog loading, and optional provider switching.
Future<String?> showModelPickerDialog(
  BuildContext context, {
  required List<ModelOption> options,
  required String selectedModel,
  String? providerName,
  List<LlmProvider>? providers,
  LlmProvider? activeProvider,
  Future<List<ModelOption>> Function(LlmProvider)? onProviderChanged,
  VoidCallback? onManageProviders,
  Future<void> Function()? onRefresh,
}) {
  return showDialog<String>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.68),
    builder: (dialogContext) => ModelPickerDialog(
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
}

class ModelPickerDialog extends StatefulWidget {
  final List<ModelOption> options;
  final String selectedModel;
  final String? providerName;
  final List<LlmProvider>? providers;
  final LlmProvider? activeProvider;
  final Future<List<ModelOption>> Function(LlmProvider)? onProviderChanged;
  final VoidCallback? onManageProviders;
  final Future<void> Function()? onRefresh;

  const ModelPickerDialog({
    super.key,
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
  State<ModelPickerDialog> createState() => _ModelPickerDialogState();
}

class _ModelPickerDialogState extends State<ModelPickerDialog> {
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
    final baseOptions = (cached != null && cached.isNotEmpty)
        ? cached
        : widget.options;
    _currentOptions = List<ModelOption>.from(baseOptions)
      ..sort(ModelOption.compareByReleaseDate);

    // Reset immediately only when knowably stale (free fallback with a key)
    // or when missing from a live cached list. A miss against a
    // defaults-only list proves nothing — keep the stored pick and let the
    // post-fetch check heal it if genuinely dead.
    final hasLiveList = cached != null && cached.isNotEmpty;
    final isFreeWithKey = _currentProviderHasKey &&
        (_currentSelectedModel == 'openrouter/free' ||
            _currentSelectedModel == 'openrouter/auto' ||
            _currentSelectedModel == kDefaultModelId);
    final isStaleOrFallback = (provider != null) &&
        (isFreeWithKey ||
            (hasLiveList &&
                !_currentOptions.any(
                  (m) => m.id == _currentSelectedModel,
                )));
    if (isStaleOrFallback && _currentOptions.isNotEmpty) {
      _currentSelectedModel = _resolveDisplayModel(provider, _currentOptions);
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

  String _pickInitialModel(LlmProvider provider, List<ModelOption> opts) {
    // Fresh default priority (no stored pick): first model in the sorted
    // list > hardcoded preset fallback.
    if (opts.isEmpty) {
      return provider.defaultModels.isNotEmpty
          ? provider.defaultModels.first.id
          : kDefaultModelId;
    }
    final hasKey = provider.hasKey ||
        (provider.id == ProviderPresetType.openRouter.id &&
            AppSettingsService.instance.hasOpenRouterKey);
    final isUnconfiguredOpenRouter =
        (provider.id == ProviderPresetType.openRouter.id ||
            provider.baseUrl.contains('openrouter.ai')) &&
        !hasKey;
    if (isUnconfiguredOpenRouter) {
      return opts.firstWhere(
        (m) =>
            m.id == 'openrouter/free' ||
            m.id.toLowerCase().contains('openrouter/free') ||
            m.name.toLowerCase().contains('free models router'),
        orElse: () => opts.first,
      ).id;
    }
    for (final m in opts) {
      if (hasKey &&
          (m.id == 'openrouter/free' ||
              m.id == 'openrouter/auto' ||
              m.id == kDefaultModelId)) {
        continue;
      }
      return m.id;
    }
    return opts.first.id;
  }

  /// Full per-provider priority for display: that provider's last pick
  /// > list head > hardcoded preset. The stored pick is shown optimistically
  /// even when absent from a defaults-only list (rendered as a synthetic
  /// option) — the post-fetch stale check heals it if genuinely dead. Only
  /// the free-router-with-key case resets immediately, since it is knowably
  /// stale without live data.
  String _resolveDisplayModel(LlmProvider provider, List<ModelOption> opts) {
    final stored = AppSettingsService.instance.selectedModelFor(provider.id);
    if (AppSettingsService.instance.hasSelectedModelFor(provider.id)) {
      final hasKey = provider.hasKey ||
          (provider.id == ProviderPresetType.openRouter.id &&
              AppSettingsService.instance.hasOpenRouterKey);
      final isFreeWithKey = hasKey &&
          (stored == 'openrouter/free' ||
              stored == 'openrouter/auto' ||
              stored == kDefaultModelId);
      if (!isFreeWithKey) return stored;
    }
    return _pickInitialModel(provider, opts);
  }

  Future<void> _handleProviderSelected(LlmProvider provider) async {
    if (provider.id == _currentProvider?.id) return;

    final cached = ModelCatalogService.getCachedModels(provider.baseUrl);
    final rawModels = (cached != null && cached.isNotEmpty)
        ? cached
        : provider.defaultModels;
    final initialModels = List<ModelOption>.from(rawModels)
      ..sort(ModelOption.compareByReleaseDate);

    final hasKey = provider.hasKey ||
        (provider.id == ProviderPresetType.openRouter.id &&
            AppSettingsService.instance.hasOpenRouterKey);

    final firstModel = _resolveDisplayModel(provider, initialModels);
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
            final sorted = List<ModelOption>.from(updated)
              ..sort(ModelOption.compareByReleaseDate);
            _currentOptions = sorted;
            // `updated` may be a defaults-only list when the fetch failed
            // offline — only treat a miss as stale against live data.
            final liveNow =
                ModelCatalogService.getCachedModels(provider.baseUrl);
            final hasLiveNow = liveNow != null && liveNow.isNotEmpty;
            final isFreeWithKey = hasKey &&
                (_currentSelectedModel == 'openrouter/free' ||
                    _currentSelectedModel == 'openrouter/auto' ||
                    _currentSelectedModel == kDefaultModelId);
            final isStale = isFreeWithKey ||
                (hasLiveNow &&
                    !_currentOptions.any(
                      (m) => m.id == _currentSelectedModel,
                    ));
            if (isStale) {
              _currentSelectedModel = _pickInitialModel(provider, sorted);
            }
          }
          _refreshing = false;
        });
      }
    } else if (needsFetch) {
      final apiKey = provider.id == ProviderPresetType.openRouter.id
          ? (provider.apiKey ?? AppSettingsService.instance.openRouterKey ?? '')
          : (provider.apiKey ?? '');
      try {
        final models = await ModelCatalogService.fetchAndClose(
          baseUrl: provider.baseUrl.isNotEmpty ? provider.baseUrl : provider.defaultBaseUrl,
          apiKey: apiKey,
          defaultProvider: provider.name,
          isOpenRouter: provider.id == ProviderPresetType.openRouter.id ||
              provider.baseUrl.contains('openrouter.ai'),
        );
        if (mounted && _currentProvider?.id == provider.id) {
          setState(() {
            final sorted = List<ModelOption>.from(models)
              ..sort(ModelOption.compareByReleaseDate);
            _currentOptions = sorted;
            final isStale = !_currentOptions.any((m) => m.id == _currentSelectedModel) ||
                (hasKey &&
                    (_currentSelectedModel == 'openrouter/free' ||
                        _currentSelectedModel == 'openrouter/auto' ||
                        _currentSelectedModel == kDefaultModelId));
            if (isStale) {
              _currentSelectedModel = _pickInitialModel(provider, sorted);
            }
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
            cached = await ModelCatalogService.fetchAndClose(
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
          final sorted = List<ModelOption>.from(cached)
            ..sort(ModelOption.compareByReleaseDate);
          final isStale = !sorted.any((m) => m.id == _currentSelectedModel) ||
              (_currentProviderHasKey &&
                  (_currentSelectedModel == 'openrouter/free' ||
                      _currentSelectedModel == 'openrouter/auto' ||
                      _currentSelectedModel == kDefaultModelId));
          setState(() {
            _currentOptions = sorted;
            if (isStale) {
              _currentSelectedModel = _pickInitialModel(provider, sorted);
            }
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
