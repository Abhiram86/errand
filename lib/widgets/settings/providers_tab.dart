import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/llm_provider.dart';
import '../../models/model_option.dart';
import '../../services/app_settings.dart';
import '../../services/model_catalog.dart';
import '../../theme/app_colors.dart';
import 'provider_form_dialog.dart';
import 'settings_helpers.dart';

class ProvidersTab extends StatelessWidget {
  final bool loaded;
  final VoidCallback onSettingsChanged;

  const ProvidersTab({
    super.key,
    required this.loaded,
    required this.onSettingsChanged,
  });

  Future<void> _openAddProviderDialog(BuildContext context) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => const ProviderFormDialog(),
    );
    if (changed == true) {
      onSettingsChanged();
    }
  }

  Future<void> _openEditProviderDialog(
    BuildContext context,
    LlmProvider provider,
  ) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => ProviderFormDialog(provider: provider),
    );
    if (changed == true) {
      onSettingsChanged();
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
      onSettingsChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!loaded) {
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
                style: TextStyle(
                  color: kMuted,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
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
              final hasKey = provider.hasKey ||
                  (provider.id == ProviderPresetType.openRouter.id &&
                      settings.hasOpenRouterKey);

              return InkWell(
                onTap: () async {
                  await settings.setActiveProvider(provider.id);
                  onSettingsChanged();
                  if (hasKey &&
                      !ModelCatalogService.hasCachedModels(provider.baseUrl)) {
                    final apiKey = provider.id ==
                            ProviderPresetType.openRouter.id
                        ? (provider.apiKey ?? settings.openRouterKey ?? '')
                        : (provider.apiKey ?? '');
                    unawaited(
                      ModelCatalogService()
                          .load(
                            baseUrl: provider.baseUrl.isNotEmpty
                                ? provider.baseUrl
                                : provider.defaultBaseUrl,
                            apiKey: apiKey,
                            defaultProvider: provider.name,
                            isOpenRouter: provider.id ==
                                    ProviderPresetType.openRouter.id ||
                                provider.baseUrl.contains('openrouter.ai'),
                          )
                          .catchError((_) => <ModelOption>[]),
                    );
                  }
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
                                settingsStatusChip(
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
                          icon: const Icon(Icons.key_off_outlined,
                              size: 18, color: kMuted),
                          tooltip: 'Clear API key',
                          onPressed: () async {
                            ModelCatalogService.clearCache(
                                baseUrl: provider.baseUrl);
                            await settings.saveProvider(provider, clearKey: true);
                            onSettingsChanged();
                          },
                          visualDensity: VisualDensity.compact,
                        ),
                      IconButton(
                        icon: const Icon(Icons.edit_outlined,
                            size: 18, color: kMuted),
                        tooltip: 'Edit provider',
                        onPressed: () =>
                            _openEditProviderDialog(context, provider),
                        visualDensity: VisualDensity.compact,
                      ),
                      if (providers.length > 1)
                        IconButton(
                          icon: const Icon(Icons.delete_outline,
                              size: 18, color: kDanger),
                          tooltip: 'Delete provider',
                          onPressed: () =>
                              _confirmDeleteProvider(context, provider),
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
}
