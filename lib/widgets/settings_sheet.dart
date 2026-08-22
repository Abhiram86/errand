import 'package:flutter/material.dart';

import '../services/app_settings.dart';
import '../theme/app_colors.dart';

/// Modal sheet for runtime configuration: LLM/Tavily API keys (stored
/// AES-GCM encrypted in SQLite) and an optional base-URL override.
///
/// Pops with `true` when anything was saved so the caller can reload the
/// model catalog / LLM client.
Future<bool> showSettingsSheet(BuildContext context) async {
  final changed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: kDarkBg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => const _SettingsSheet(),
  );
  return changed ?? false;
}

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet();

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

  @override
  void initState() {
    super.initState();
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

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 16,
        // Keep the form above the keyboard.
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.tune_rounded, size: 18, color: kMuted),
                const SizedBox(width: 8),
                const Text('Settings', style: TextStyle(color: kText, fontSize: 16, fontWeight: FontWeight.w600)),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  icon: const Icon(Icons.close_rounded, size: 18, color: kMuted),
                  tooltip: 'Close',
                ),
              ],
            ),
            const SizedBox(height: 4),
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
                      width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save'),
            ),
          ],
        ),
      ),
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
