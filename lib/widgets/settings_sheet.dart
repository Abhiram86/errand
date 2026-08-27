import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import '../services/app_settings.dart';
import '../theme/app_colors.dart';

/// Modal sheet for runtime configuration: LLM/Tavily API keys (stored
/// AES-GCM encrypted in SQLite) and an optional base-URL override.
///
/// Tabs: Global (keys) and Local (attached files for the current conversation).
/// Pops with `true` when anything was saved so the caller can reload the
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

class _SettingsSheetState extends State<_SettingsSheet> {
  final _openRouterController = TextEditingController();
  final _tavilyController = TextEditingController();
  final _baseUrlController = TextEditingController();
  final _obscured = <_SecretField, bool>{};

  bool _hasOpenRouterKey = false;
  bool _hasTavilyKey = false;
  bool _saving = false;
  bool _loaded = false;
  late List<String> _localAttached;
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    _localAttached = List<String>.from(widget.attachedFiles);
    _load();
  }

  Future<void> _load() async {
    await AppSettingsService.instance.ensureLoaded();
    if (!mounted) return;
    setState(() {
      _hasOpenRouterKey = AppSettingsService.instance.hasOpenRouterKey;
      _hasTavilyKey = AppSettingsService.instance.hasTavilyKey;
      _baseUrlController.text =
          AppSettingsService.instance.baseUrlOverride ?? '';
      _loaded = true;
    });
  }

  @override
  void dispose() {
    _openRouterController.dispose();
    _tavilyController.dispose();
    _baseUrlController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final settings = AppSettingsService.instance;

      // Empty fields leave existing keys untouched; clearing is explicit
      // via the trash buttons so a stray keystroke can't wipe a key.
      final newOpenRouter = _openRouterController.text.trim();
      if (newOpenRouter.isNotEmpty) {
        await settings.setOpenRouterKey(newOpenRouter);
        _openRouterController.clear();
      }
      final newTavily = _tavilyController.text.trim();
      if (newTavily.isNotEmpty) {
        await settings.setTavilyKey(newTavily);
        _tavilyController.clear();
      }

      final url = _baseUrlController.text.trim();
      if (url.isEmpty || url == AppSettingsService.defaultBaseUrl) {
        await settings.setBaseUrlOverride(null);
      } else {
        await settings.setBaseUrlOverride(url);
      }

      if (!mounted) return;
      setState(() {
        _hasOpenRouterKey = settings.hasOpenRouterKey;
        _hasTavilyKey = settings.hasTavilyKey;
      });
      Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _clear(_SecretField field) async {
    final settings = AppSettingsService.instance;
    switch (field) {
      case _SecretField.openRouter:
        await settings.setOpenRouterKey(null);
      case _SecretField.tavily:
        await settings.setTavilyKey(null);
    }
    if (!mounted) return;
    setState(() {
      switch (field) {
        case _SecretField.openRouter:
          _hasOpenRouterKey = false;
          _openRouterController.clear();
        case _SecretField.tavily:
          _hasTavilyKey = false;
          _tavilyController.clear();
      }
    });
  }

  Future<void> _pickLocalFiles() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final result = await FilePicker.platform.pickFiles(allowMultiple: true);
      final paths = result?.paths.whereType<String>().toList() ?? const [];
      if (paths.isEmpty) return;
      // Delegate to host so conversation inventory + persistence stays canonical.
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
      length: 2,
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
                const Text('Settings',
                    style:
                        TextStyle(color: kText, fontSize: 16, fontWeight: FontWeight.w600)),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(false),
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
                Tab(text: 'Global'),
                Tab(text: 'Local'),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 420,
              child: TabBarView(
                children: [
                  SingleChildScrollView(child: _buildGlobalTab()),
                  _buildLocalTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGlobalTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Keys are encrypted and stored on this device only.',
          style: const TextStyle(color: kMuted, fontSize: 12),
        ),
        const SizedBox(height: 16),
        _secretField(
          field: _SecretField.openRouter,
          label: 'OpenRouter API key',
          hint: 'sk-or-v1-…',
          configured: _hasOpenRouterKey,
          controller: _openRouterController,
        ),
        const SizedBox(height: 14),
        _secretField(
          field: _SecretField.tavily,
          label: 'Tavily API key',
          hint: 'tvly-…',
          configured: _hasTavilyKey,
          controller: _tavilyController,
        ),
        const SizedBox(height: 14),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Base URL', style: TextStyle(color: kText, fontSize: 13)),
            const SizedBox(height: 2),
            Text(
              'Leave empty for ${AppSettingsService.defaultBaseUrl}',
              style: const TextStyle(color: kMuted, fontSize: 11),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _baseUrlController,
              enabled: _loaded,
              keyboardType: TextInputType.url,
              autocorrect: false,
              style: const TextStyle(color: kText, fontSize: 14),
              decoration: _inputDecoration(hint: 'https://…'),
            ),
          ],
        ),
        const SizedBox(height: 18),
        FilledButton(
          onPressed: _saving ? null : _save,
          style: FilledButton.styleFrom(backgroundColor: kBubbleUser),
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
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
            Text('Attached files (${_localAttached.length})',
                style: const TextStyle(color: kText, fontSize: 13, fontWeight: FontWeight.w600)),
            const Spacer(),
            FilledButton.tonal(
              onPressed: _picking ? null : _pickLocalFiles,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                minimumSize: const Size(0, 36),
              ),
              child: _picking
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Attach', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text('Visible to the model via attached_files / read. Paths outside /storage/emulated/0 are allowed for picked files.',
            style: TextStyle(color: kMuted, fontSize: 11)),
        const SizedBox(height: 12),
        Expanded(
          child: _localAttached.isEmpty
              ? const Center(
                  child: Text('No files attached in this conversation.',
                      style: TextStyle(color: kMuted, fontSize: 12)),
                )
              : ListView.separated(
                  itemCount: _localAttached.length,
                  separatorBuilder: (_, _) => const Divider(color: kBorder, height: 1),
                  itemBuilder: (context, i) {
                    final uri = _localAttached[i];
                    return ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                      leading: const Icon(Icons.insert_drive_file_outlined, size: 18, color: kMuted),
                      title: Text(path.basename(uri),
                          style: const TextStyle(color: kText, fontSize: 12),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      subtitle: Text(uri, style: const TextStyle(color: kMuted, fontSize: 10), maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: IconButton(
                        icon: const Icon(Icons.close_rounded, size: 16, color: kMuted),
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

  Widget _secretField({
    required _SecretField field,
    required String label,
    required String hint,
    required bool configured,
    required TextEditingController controller,
  }) {
    final obscure = _obscured[field] ?? true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: const TextStyle(color: kText, fontSize: 13)),
            const SizedBox(width: 8),
            _statusChip(configured),
            const Spacer(),
            if (configured)
              IconButton(
                onPressed: () => _clear(field),
                icon: const Icon(Icons.delete_outline_rounded, size: 18, color: kDanger),
                tooltip: 'Remove saved key',
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          enabled: _loaded,
          obscureText: obscure,
          autocorrect: false,
          enableSuggestions: false,
          style: const TextStyle(color: kText, fontSize: 14),
          decoration: _inputDecoration(hint: hint).copyWith(
            suffixIcon: IconButton(
              onPressed: () =>
                  setState(() => _obscured[field] = !obscure),
              icon: Icon(
                obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                size: 18,
                color: kMuted,
              ),
              tooltip: obscure ? 'Show' : 'Hide',
            ),
          ),
        ),
      ],
    );
  }

  Widget _statusChip(bool configured) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: configured ? kBubbleAssistant : kInputBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kBorder),
      ),
      child: Text(
        configured ? 'configured' : 'not set',
        style: TextStyle(
          color: configured ? kText : kMuted,
          fontSize: 10,
        ),
      ),
    );
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
}

enum _SecretField { openRouter, tavily }
