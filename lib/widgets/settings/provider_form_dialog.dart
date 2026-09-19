import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/llm_provider.dart';
import '../../models/model_option.dart';
import '../../services/app_settings.dart';
import '../../services/model_catalog.dart';
import '../../theme/app_colors.dart';
import 'settings_helpers.dart';

class ProviderFormDialog extends StatefulWidget {
  final LlmProvider? provider;

  const ProviderFormDialog({super.key, this.provider});

  @override
  State<ProviderFormDialog> createState() => _ProviderFormDialogState();
}

class _ProviderFormDialogState extends State<ProviderFormDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _baseUrlController;
  late final TextEditingController _keyController;
  bool _obscureKey = true;
  bool _testing = false;
  ConnectionTestResult? _testResult;

  @override
  void initState() {
    super.initState();
    final p = widget.provider;
    _nameController = TextEditingController(text: p?.name ?? '');
    _baseUrlController = TextEditingController(text: p?.baseUrl ?? '');
    _keyController = TextEditingController(text: p?.apiKey ?? '');
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
    final isOpenRouter = baseUrl.contains('openrouter.ai');

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
    final String id = existing != null
        ? existing.id
        : 'custom_${DateTime.now().millisecondsSinceEpoch}';

    final bool shouldClearKey = apiKey.isEmpty;

    final updated = LlmProvider(
      id: id,
      name: name,
      baseUrl: baseUrl,
      apiKey: shouldClearKey ? null : apiKey,
      isDefault: existing?.isDefault ?? false,
      isPreset: existing?.isPreset ?? false,
      createdAt: existing?.createdAt ?? DateTime.now(),
      updatedAt: DateTime.now(),
    );

    await AppSettingsService.instance.saveProvider(
      updated,
      apiKey: shouldClearKey ? null : apiKey,
      clearKey: shouldClearKey,
    );

    if (existing != null && existing.baseUrl != baseUrl) {
      ModelCatalogService.clearCache(baseUrl: existing.baseUrl);
    }

    if (apiKey.isNotEmpty) {
      ModelCatalogService.clearCache(baseUrl: baseUrl);
      unawaited(
        ModelCatalogService().load(
          baseUrl: baseUrl,
          apiKey: apiKey,
          defaultProvider: name,
          isOpenRouter: id == ProviderPresetType.openRouter.id ||
              baseUrl.contains('openrouter.ai'),
          forceRefresh: true,
        ).catchError((_) => <ModelOption>[]),
      );
    } else {
      ModelCatalogService.clearCache(baseUrl: baseUrl);
    }

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
            const SizedBox(height: 14),
            const Text('Provider Name',
                style: TextStyle(color: kText, fontSize: 13)),
            const SizedBox(height: 6),
            TextField(
              controller: _nameController,
              style: const TextStyle(color: kText, fontSize: 14),
              decoration: settingsInputDecoration(
                hint: 'e.g. Ollama, Mistral, Together AI',
              ),
            ),
            const SizedBox(height: 14),
            const Text('Base URL',
                style: TextStyle(color: kText, fontSize: 13)),
            const SizedBox(height: 6),
            TextField(
              controller: _baseUrlController,
              keyboardType: TextInputType.url,
              style: const TextStyle(color: kText, fontSize: 14),
              decoration: settingsInputDecoration(
                hint: 'e.g. http://localhost:11434/v1 or https://api.openai.com/v1',
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
              decoration: settingsInputDecoration(
                hint: 'Enter token or API key',
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
