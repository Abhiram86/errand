import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import '../models/llm_provider.dart';
import '../services/a11y_service.dart';
import '../services/app_settings.dart';
import '../services/model_catalog.dart';
import '../theme/app_colors.dart';

/// Modal sheet for runtime configuration:
/// - Providers: Manage LLM providers (OpenCode Zen, OpenRouter, Groq, BYOK/Custom),
///   API tokens, base URLs, active provider selection, and connection testing.
/// - Tools: Search API keys (Tavily).
/// - Local: Attached files for the current conversation.
///
/// Pops with `true` when configuration changed so the caller can reload the
/// model catalog / LLM client.
Future<bool> showSettingsSheet(
  BuildContext context, {
  List<String> attachedFiles = const [],
  Future<void> Function(List<String> paths)? onAttachFiles,
  void Function(String uri)? onDetachFile,
}) async {
  final changed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: kDarkBg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => _SettingsSheet(
      attachedFiles: attachedFiles,
      onAttachFiles: onAttachFiles,
      onDetachFile: onDetachFile,
    ),
  );
  return changed ?? false;
}

class _SettingsSheet extends StatefulWidget {
  final List<String> attachedFiles;
  final Future<void> Function(List<String> paths)? onAttachFiles;
  final void Function(String uri)? onDetachFile;

  const _SettingsSheet({
    this.attachedFiles = const [],
    this.onAttachFiles,
    this.onDetachFile,
  });

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet>
    with WidgetsBindingObserver {
  final _tavilyController = TextEditingController();
  bool _hasTavilyKey = false;
  bool _tavilyObscured = true;

  bool _loaded = false;
  bool _settingsChanged = false;
  bool _a11yEnabled = false;
  late List<String> _localAttached;
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    _localAttached = List<String>.from(widget.attachedFiles);
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  /// The Enable button fires an intent into system Settings (returns
  /// immediately — the user enables while we're backgrounded), so refresh
  /// the chip when we come back instead of going stale until reopen.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshA11y());
    }
  }

  Future<void> _refreshA11y() async {
    final a11y = await A11yService().isEnabled();
    if (!mounted) return;
    setState(() => _a11yEnabled = a11y);
  }

  Future<void> _load() async {
    final results = await Future.wait([
      AppSettingsService.instance.ensureLoaded(),
      A11yService().isEnabled(),
    ]);
    if (!mounted) return;
    setState(() {
      _hasTavilyKey = AppSettingsService.instance.hasTavilyKey;
      _a11yEnabled = results[1] as bool;
      _loaded = true;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tavilyController.dispose();
    super.dispose();
  }

  Future<void> _saveTavily() async {
    final settings = AppSettingsService.instance;
    final newTavily = _tavilyController.text.trim();
    if (newTavily.isNotEmpty) {
      await settings.setTavilyKey(newTavily);
      _tavilyController.clear();
      if (!mounted) return;
      setState(() {
        _hasTavilyKey = settings.hasTavilyKey;
        _settingsChanged = true;
      });
    }
  }

  Future<void> _clearTavily() async {
    final settings = AppSettingsService.instance;
    await settings.setTavilyKey(null);
    if (!mounted) return;
    setState(() {
      _hasTavilyKey = false;
      _tavilyController.clear();
      _settingsChanged = true;
    });
  }

  Future<void> _pickLocalFiles() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final result = await FilePicker.platform.pickFiles(allowMultiple: true);
      final paths = result?.paths.whereType<String>().toList() ?? const [];
      if (paths.isEmpty) return;
      if (widget.onAttachFiles != null) {
        await widget.onAttachFiles!(paths);
      }
      if (!mounted) return;
      setState(() {
        for (final p in paths) {
          if (!_localAttached.contains(p)) _localAttached.add(p);
        }
      });
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _detachLocal(String uri) {
    setState(() => _localAttached.remove(uri));
    widget.onDetachFile?.call(uri);
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.tune_rounded, size: 18, color: kMuted),
                const SizedBox(width: 8),
                const Text(
                  'Settings',
                  style: TextStyle(
                    color: kText,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(_settingsChanged),
                  icon: const Icon(Icons.close_rounded, size: 18, color: kMuted),
                  tooltip: 'Close',
                ),
              ],
            ),
            const SizedBox(height: 12),
            const TabBar(
              labelColor: kText,
              unselectedLabelColor: kMuted,
              indicatorColor: kBubbleUser,
              dividerColor: Colors.transparent,
              dividerHeight: 0,
              tabs: [
                Tab(text: 'Providers'),
                Tab(text: 'Tools'),
                Tab(text: 'Files'),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 440,
              child: TabBarView(
                children: [
                  _buildProvidersTab(),
                  SingleChildScrollView(child: _buildToolsTab()),
                  _buildLocalTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProvidersTab() {
    if (!_loaded) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    final settings = AppSettingsService.instance;
    final providers = settings.providers;
    final activeId = settings.activeProviderId;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'LLM Providers',
                style: TextStyle(color: kMuted, fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
            FilledButton.tonal(
              onPressed: () => _openAddProviderDialog(context),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                minimumSize: const Size(0, 32),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Add', style: TextStyle(fontSize: 12)),
                  SizedBox(width: 4),
                  Icon(Icons.add, size: 16),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: ListView.separated(
            itemCount: providers.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final provider = providers[i];
              final isActive = provider.id == activeId;
              final hasKey = provider.hasKey;

              return InkWell(
                onTap: () async {
                  await settings.setActiveProvider(provider.id);
                  if (!mounted) return;
                  setState(() => _settingsChanged = true);
                },
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: isActive ? kBubbleAssistant : kInputBg,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isActive ? kBubbleUser : kBorder,
                      width: isActive ? 1.5 : 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        isActive
                            ? Icons.radio_button_checked_rounded
                            : Icons.radio_button_off_rounded,
                        size: 18,
                        color: isActive ? kBubbleUser : kMuted,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    provider.name,
                                    style: TextStyle(
                                      color: kText,
                                      fontSize: 14,
                                      fontWeight: isActive
                                          ? FontWeight.w600
                                          : FontWeight.normal,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                _statusChip(
                                  configured: hasKey,
                                  label: hasKey ? 'Key set' : 'No key',
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              provider.baseUrl,
                              style: const TextStyle(
                                color: kMuted,
                                fontSize: 11,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      if (hasKey)
                        IconButton(
                          icon: const Icon(Icons.key_off_outlined, size: 18, color: kMuted),
                          tooltip: 'Clear API key',
                          onPressed: () async {
                            ModelCatalogService.clearCache(baseUrl: provider.baseUrl);
                            await settings.saveProvider(provider, clearKey: true);
                            if (!mounted) return;
                            setState(() => _settingsChanged = true);
                          },
                          visualDensity: VisualDensity.compact,
                        ),
                      IconButton(
                        icon: const Icon(Icons.edit_outlined, size: 18, color: kMuted),
                        tooltip: 'Edit provider',
                        onPressed: () => _openEditProviderDialog(context, provider),
                        visualDensity: VisualDensity.compact,
                      ),
                      if (providers.length > 1)
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 18, color: kDanger),
                          tooltip: 'Delete provider',
                          onPressed: () => _confirmDeleteProvider(context, provider),
                          visualDensity: VisualDensity.compact,
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildToolsTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('Screen Access (Accessibility)',
                    style: TextStyle(color: kText, fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(width: 8),
                _statusChip(
                  configured: _a11yEnabled,
                  label: _a11yEnabled ? 'Active' : 'Disabled',
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'Enables screen reading and device automation. Pauses when Errand closes to keep other apps secure.',
              style: TextStyle(color: kMuted, fontSize: 12),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                if (_a11yEnabled)
                  OutlinedButton.icon(
                    onPressed: () async {
                      // disableSelf() applies async at OS level — an immediate
                      // isEnabled() re-read can still return true. Trust a
                      // successful disable call instead of the racy re-read.
                      final ok = await A11yService().disableService();
                      final updated = ok ? false : await A11yService().isEnabled();
                      if (mounted) {
                        setState(() {
                          if (_a11yEnabled != updated) {
                            _a11yEnabled = updated;
                            _settingsChanged = true;
                          }
                        });
                      }
                    },
                    icon: const Icon(Icons.power_settings_new_rounded, size: 16),
                    label: const Text('Disable now'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: kDanger,
                      side: const BorderSide(color: kDanger),
                    ),
                  )
                else
                  FilledButton.icon(
                    onPressed: () async {
                      await A11yService().openSettings();
                    },
                    icon: const Icon(Icons.settings_accessibility_rounded, size: 16),
                    label: const Text('Enable in Settings'),
                    style: FilledButton.styleFrom(backgroundColor: kBubbleUser),
                  ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 20),
        const Divider(color: kBorder),
        const SizedBox(height: 16),
        const Text(
          'API keys for optional agent tools.',
          style: TextStyle(color: kMuted, fontSize: 12),
        ),
        const SizedBox(height: 16),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('Tavily Search API key',
                    style: TextStyle(color: kText, fontSize: 13)),
                const SizedBox(width: 8),
                _statusChip(configured: _hasTavilyKey),
                const Spacer(),
                if (_hasTavilyKey)
                  IconButton(
                    onPressed: _clearTavily,
                    icon: const Icon(Icons.delete_outline_rounded,
                        size: 18, color: kDanger),
                    tooltip: 'Remove saved key',
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _tavilyController,
              enabled: _loaded,
              obscureText: _tavilyObscured,
              autocorrect: false,
              enableSuggestions: false,
              style: const TextStyle(color: kText, fontSize: 14),
              decoration: _inputDecoration(hint: 'tvly-…').copyWith(
                suffixIcon: IconButton(
                  onPressed: () =>
                      setState(() => _tavilyObscured = !_tavilyObscured),
                  icon: Icon(
                    _tavilyObscured
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 18,
                    color: kMuted,
                  ),
                  tooltip: _tavilyObscured ? 'Show' : 'Hide',
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _saveTavily,
          style: FilledButton.styleFrom(backgroundColor: kBubbleUser),
          child: const Text('Save Tool Key'),
        ),
      ],
    );
  }

  Widget _buildLocalTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              'Attached files (${_localAttached.length})',
              style: const TextStyle(
                color: kText,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            FilledButton.tonal(
              onPressed: _picking ? null : _pickLocalFiles,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                minimumSize: const Size(0, 36),
              ),
              child: _picking
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Attach', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'Visible to the model via attached_files / read. Paths outside /storage/emulated/0 are allowed for picked files.',
          style: TextStyle(color: kMuted, fontSize: 11),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _localAttached.isEmpty
              ? const Center(
                  child: Text(
                    'No files attached in this conversation.',
                    style: TextStyle(color: kMuted, fontSize: 12),
                  ),
                )
              : ListView.separated(
                  itemCount: _localAttached.length,
                  separatorBuilder: (_, _) =>
                      const Divider(color: kBorder, height: 1),
                  itemBuilder: (context, i) {
                    final uri = _localAttached[i];
                    return ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                      leading: const Icon(
                        Icons.insert_drive_file_outlined,
                        size: 18,
                        color: kMuted,
                      ),
                      title: Text(
                        path.basename(uri),
                        style: const TextStyle(color: kText, fontSize: 12),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        uri,
                        style: const TextStyle(color: kMuted, fontSize: 10),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.close_rounded,
                            size: 16, color: kMuted),
                        onPressed: () => _detachLocal(uri),
                        tooltip: 'Remove',
                        visualDensity: VisualDensity.compact,
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _openAddProviderDialog(BuildContext context) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => const _ProviderFormDialog(),
    );
    if (changed == true && mounted) {
      setState(() => _settingsChanged = true);
    }
  }

  Future<void> _openEditProviderDialog(
    BuildContext context,
    LlmProvider provider,
  ) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => _ProviderFormDialog(provider: provider),
    );
    if (changed == true && mounted) {
      ModelCatalogService.clearCache(baseUrl: provider.baseUrl);
      setState(() => _settingsChanged = true);
    }
  }

  Future<void> _confirmDeleteProvider(
    BuildContext context,
    LlmProvider provider,
  ) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: kDarkBg,
        title: Text('Delete ${provider.name}?'),
        content: const Text(
          'This will remove this provider configuration and its stored API key.',
          style: TextStyle(color: kMuted, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kDanger),
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      ModelCatalogService.clearCache(baseUrl: provider.baseUrl);
      await AppSettingsService.instance.deleteProvider(provider.id);
      if (!mounted) return;
      setState(() => _settingsChanged = true);
    }
  }

  Widget _statusChip({required bool configured, String? label}) {
    final text = label ?? (configured ? 'configured' : 'not set');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: configured ? kBubbleAssistant : kInputBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kBorder),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: configured ? kText : kMuted,
          fontSize: 10,
        ),
      ),
    );
  }
}

InputDecoration _inputDecoration({required String hint}) {
  return InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(color: kSendDisabled, fontSize: 14),
    filled: true,
    fillColor: kInputBg,
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: kBorder),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: kBorder),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: kBubbleUser),
    ),
  );
}

class _ProviderFormDialog extends StatefulWidget {
  final LlmProvider? provider;

  const _ProviderFormDialog({this.provider});

  @override
  State<_ProviderFormDialog> createState() => _ProviderFormDialogState();
}

class _ProviderFormDialogState extends State<_ProviderFormDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _baseUrlController;
  late final TextEditingController _keyController;
  bool _obscureKey = true;
  bool _testing = false;
  ConnectionTestResult? _testResult;

  ProviderPresetType? _selectedPreset;

  @override
  void initState() {
    super.initState();
    final p = widget.provider;
    _nameController = TextEditingController(text: p?.name ?? '');
    _baseUrlController = TextEditingController(text: p?.baseUrl ?? '');
    _keyController = TextEditingController(text: p?.apiKey ?? '');

    if (p != null) {
      for (final preset in ProviderPresetType.values) {
        if (preset.id == p.id) {
          _selectedPreset = preset;
          break;
        }
      }
    } else {
      // Default to OpenCode Zen preset when creating
      _selectPreset(ProviderPresetType.openCodeZen);
    }
  }

  void _selectPreset(ProviderPresetType preset) {
    setState(() {
      _selectedPreset = preset;
      if (widget.provider == null) {
        _nameController.text = preset.displayName;
        _baseUrlController.text = preset.defaultBaseUrl;
      }
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _baseUrlController.dispose();
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _testConnection() async {
    final baseUrl = _baseUrlController.text.trim();
    final apiKey = _keyController.text.trim();
    if (baseUrl.isEmpty) return;

    setState(() {
      _testing = true;
      _testResult = null;
    });

    final service = ModelCatalogService();
    final isOpenRouter = _selectedPreset == ProviderPresetType.openRouter ||
        baseUrl.contains('openrouter.ai');

    final result = await service.testConnection(
      baseUrl: baseUrl,
      apiKey: apiKey,
      defaultProvider: _nameController.text.trim(),
      isOpenRouter: isOpenRouter,
    );
    service.close();

    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = result;
    });
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    final baseUrl = _baseUrlController.text.trim();
    final apiKey = _keyController.text.trim();

    if (name.isEmpty || baseUrl.isEmpty) return;

    final existing = widget.provider;
    final String id;
    if (existing != null) {
      id = existing.id;
    } else if (_selectedPreset == ProviderPresetType.byok) {
      // Multiple BYOK providers get unique IDs
      id = 'byok_${DateTime.now().millisecondsSinceEpoch}';
    } else if (_selectedPreset != null) {
      final exists = AppSettingsService.instance.providers.any((p) => p.id == _selectedPreset!.id);
      id = exists ? '${_selectedPreset!.id}_${DateTime.now().millisecondsSinceEpoch}' : _selectedPreset!.id;
    } else {
      id = 'byok_${DateTime.now().millisecondsSinceEpoch}';
    }

    final bool shouldClearKey = apiKey.isEmpty;

    final updated = LlmProvider(
      id: id,
      name: name,
      baseUrl: baseUrl,
      apiKey: shouldClearKey ? null : apiKey,
      isDefault: existing?.isDefault ?? false,
      isPreset: _selectedPreset != null,
      createdAt: existing?.createdAt ?? DateTime.now(),
      updatedAt: DateTime.now(),
    );

    await AppSettingsService.instance.saveProvider(
      updated,
      apiKey: shouldClearKey ? null : apiKey,
      clearKey: shouldClearKey,
    );
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.provider != null;

    return Dialog(
      backgroundColor: kDarkBg,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  isEditing ? 'Edit Provider' : 'Add Provider',
                  style: const TextStyle(
                    color: kText,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  icon: const Icon(Icons.close_rounded, size: 18, color: kMuted),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (!isEditing) ...[
              const Text('Select Preset',
                  style: TextStyle(color: kMuted, fontSize: 12)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                children: ProviderPresetType.values.map((preset) {
                  final isSelected = _selectedPreset == preset;
                  return ChoiceChip(
                    label: Text(preset.displayName),
                    selected: isSelected,
                    onSelected: (selected) {
                      if (selected) _selectPreset(preset);
                    },
                    selectedColor: kBubbleUser,
                    labelStyle: TextStyle(
                      color: isSelected ? Colors.white : kText,
                      fontSize: 12,
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
            ],
            const Text('Provider Name',
                style: TextStyle(color: kText, fontSize: 13)),
            const SizedBox(height: 6),
            TextField(
              controller: _nameController,
              style: const TextStyle(color: kText, fontSize: 14),
              decoration: _inputDecoration(hint: 'OpenCode Zen, etc.'),
            ),
            const SizedBox(height: 14),
            const Text('Base URL',
                style: TextStyle(color: kText, fontSize: 13)),
            const SizedBox(height: 6),
            TextField(
              controller: _baseUrlController,
              keyboardType: TextInputType.url,
              style: const TextStyle(color: kText, fontSize: 14),
              decoration: _inputDecoration(
                hint: 'https://opencode.ai/zen/v1',
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                const Text('API Token / Key',
                    style: TextStyle(color: kText, fontSize: 13)),
                const Spacer(),
                if (_keyController.text.isNotEmpty || (widget.provider?.hasKey ?? false))
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: kDanger,
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                    ),
                    onPressed: () {
                      setState(() {
                        _keyController.clear();
                      });
                    },
                    icon: const Icon(Icons.clear, size: 14),
                    label: const Text('Clear Key', style: TextStyle(fontSize: 11)),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _keyController,
              obscureText: _obscureKey,
              style: const TextStyle(color: kText, fontSize: 14),
              decoration: _inputDecoration(
                hint: _selectedPreset?.keyHint ?? 'Enter token or API key',
              ).copyWith(
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscureKey
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 18,
                    color: kMuted,
                  ),
                  onPressed: () => setState(() => _obscureKey = !_obscureKey),
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (_testResult != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: _testResult!.success
                      ? Colors.green.withValues(alpha: 0.15)
                      : Colors.red.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _testResult!.success ? Colors.green : Colors.red,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      _testResult!.success
                          ? Icons.check_circle_outline
                          : Icons.error_outline,
                      size: 16,
                      color: _testResult!.success ? Colors.green : Colors.red,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _testResult!.message,
                        style: TextStyle(
                          color: _testResult!.success ? Colors.green : Colors.red,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 16),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _testing ? null : _testConnection,
                  icon: _testing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.wifi_tethering, size: 16),
                  label: const Text('Test Connection',
                      style: TextStyle(fontSize: 12)),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: _save,
                  style: FilledButton.styleFrom(backgroundColor: kBubbleUser),
                  child: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
