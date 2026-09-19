import 'package:flutter/material.dart';

import '../../services/a11y_service.dart';
import '../../theme/app_colors.dart';
import '../../types/memory.dart';
import 'settings_helpers.dart';

class ToolsTab extends StatefulWidget {
  final bool a11ySupported;
  final bool a11yEnabled;
  final ValueChanged<bool> onA11yChanged;
  final bool loaded;
  final bool hasTavilyKey;
  final TextEditingController tavilyController;
  final VoidCallback onSaveTavily;
  final VoidCallback onClearTavily;
  final List<UserMemory> memories;
  final ValueChanged<String> onDeleteMemory;

  const ToolsTab({
    super.key,
    required this.a11ySupported,
    required this.a11yEnabled,
    required this.onA11yChanged,
    required this.loaded,
    required this.hasTavilyKey,
    required this.tavilyController,
    required this.onSaveTavily,
    required this.onClearTavily,
    required this.memories,
    required this.onDeleteMemory,
  });

  @override
  State<ToolsTab> createState() => _ToolsTabState();
}

class _ToolsTabState extends State<ToolsTab> {
  bool _tavilyObscured = true;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.a11ySupported) ...[
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text(
                    'Screen Access (Accessibility)',
                    style: TextStyle(
                      color: kText,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 8),
                  settingsStatusChip(
                    configured: widget.a11yEnabled,
                    label: widget.a11yEnabled ? 'Active' : 'Disabled',
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
                  if (widget.a11yEnabled)
                    OutlinedButton.icon(
                      onPressed: () async {
                        final ok = await A11yService().disableService();
                        final updated =
                            ok ? false : await A11yService().isEnabled();
                        widget.onA11yChanged(updated);
                      },
                      icon: const Icon(Icons.power_settings_new_rounded,
                          size: 16),
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
                      icon: const Icon(Icons.settings_accessibility_rounded,
                          size: 16),
                      label: const Text('Enable in Settings'),
                      style:
                          FilledButton.styleFrom(backgroundColor: kBubbleUser),
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 20),
          const Divider(color: kBorder),
          const SizedBox(height: 16),
        ],
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
                settingsStatusChip(configured: widget.hasTavilyKey),
                const Spacer(),
                if (widget.hasTavilyKey)
                  IconButton(
                    onPressed: widget.onClearTavily,
                    icon: const Icon(Icons.delete_outline_rounded,
                        size: 18, color: kDanger),
                    tooltip: 'Remove saved key',
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 6),
            TextField(
              controller: widget.tavilyController,
              enabled: widget.loaded,
              obscureText: _tavilyObscured,
              autocorrect: false,
              enableSuggestions: false,
              style: const TextStyle(color: kText, fontSize: 14),
              decoration: settingsInputDecoration(hint: 'tvly-…').copyWith(
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
          onPressed: widget.onSaveTavily,
          style: FilledButton.styleFrom(backgroundColor: kBubbleUser),
          child: const Text('Save Tool Key'),
        ),
        const SizedBox(height: 20),
        const Divider(color: kBorder),
        const SizedBox(height: 16),
        Row(
          children: [
            const Text(
              'Memory',
              style: TextStyle(
                color: kText,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            settingsStatusChip(
              configured: widget.memories.isNotEmpty,
              label: '${widget.memories.length}',
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Text(
          'Saved user facts and preferences.',
          style: TextStyle(color: kMuted, fontSize: 12),
        ),
        const SizedBox(height: 12),
        if (!widget.loaded)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else if (widget.memories.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'No saved memories.',
              style: TextStyle(
                color: kMuted,
                fontSize: 12,
                fontStyle: FontStyle.italic,
              ),
            ),
          )
        else
          Column(
            children: [
              for (final mem in widget.memories)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: kInputBg,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: kBorder),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          mem.about,
                          style: const TextStyle(
                            color: kText,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        onPressed: () => widget.onDeleteMemory(mem.id),
                        icon: const Icon(
                          Icons.delete_outline_rounded,
                          size: 18,
                          color: kDanger,
                        ),
                        tooltip: 'Delete memory',
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                ),
            ],
          ),
      ],
    );
  }
}
