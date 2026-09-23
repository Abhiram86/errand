import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/llm_provider.dart';
import '../models/model_option.dart';
import '../theme/app_colors.dart';
import 'model_picker_dialog.dart';

export 'model_picker_dialog.dart';

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
    final rawOptions = [
      ...models,
      if (!models.any((model) => model.id == selectedModel)) selected,
    ];
    final options = List<ModelOption>.from(rawOptions)
      ..sort(ModelOption.compareByReleaseDate);
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
    final model = await showModelPickerDialog(
      context,
      options: options,
      selectedModel: selectedModel,
      providerName: providerName ?? activeProvider?.name,
      providers: providers,
      activeProvider: activeProvider,
      onProviderChanged: onProviderChanged,
      onManageProviders: onManageProviders,
      onRefresh: onRefresh,
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
