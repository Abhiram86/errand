import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/a11y_service.dart';
import '../services/app_settings.dart';
import '../services/memory_service.dart';
import '../theme/app_colors.dart';
import '../types/memory.dart';
import 'settings/files_tab.dart';
import 'settings/providers_tab.dart';
import 'settings/tools_tab.dart';

export 'settings/provider_form_dialog.dart';
export 'settings/settings_helpers.dart';

/// Modal sheet for runtime configuration:
/// - Providers: Manage LLM providers (OpenRouter, NVIDIA, Groq, Custom),
///   API tokens, base URLs, active provider selection, and connection testing.
/// - Tools: Search API keys (Tavily) and stored user memories.
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

  bool _loaded = false;
  bool _settingsChanged = false;
  bool _a11ySupported = A11yService.isSupportedSync;
  bool _a11yEnabled = false;
  late List<String> _localAttached;
  bool _picking = false;
  List<UserMemory> _memories = const [];

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
    final supported = await A11yService().isSupported();
    if (!mounted) return;
    if (!supported) {
      if (_a11ySupported || _a11yEnabled) {
        setState(() {
          _a11ySupported = false;
          _a11yEnabled = false;
        });
      }
      return;
    }
    final a11y = await A11yService().isEnabled();
    if (!mounted) return;
    setState(() {
      _a11ySupported = true;
      _a11yEnabled = a11y;
    });
  }

  Future<List<UserMemory>> _safeLoadMemories() async {
    try {
      return await MemoryService.instance.getAll();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _load() async {
    final results = await Future.wait([
      AppSettingsService.instance.ensureLoaded(),
      A11yService().isEnabled(),
      A11yService().isSupported(),
      _safeLoadMemories(),
    ]);
    if (!mounted) return;
    setState(() {
      _hasTavilyKey = AppSettingsService.instance.hasTavilyKey;
      _a11yEnabled = results[1] as bool;
      _a11ySupported = results[2] as bool;
      _memories = results[3] as List<UserMemory>;
      _loaded = true;
    });
  }

  Future<void> _deleteMemory(String id) async {
    try {
      await MemoryService.instance.delete(id);
      final updated = await _safeLoadMemories();
      if (!mounted) return;
      setState(() {
        _memories = updated;
        _settingsChanged = true;
      });
    } catch (_) {}
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
                  icon: const Icon(Icons.close_rounded,
                      size: 18, color: kMuted),
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
                  ProvidersTab(
                    loaded: _loaded,
                    onSettingsChanged: () {
                      if (!mounted) return;
                      setState(() => _settingsChanged = true);
                    },
                  ),
                  SingleChildScrollView(
                    child: ToolsTab(
                      a11ySupported: _a11ySupported,
                      a11yEnabled: _a11yEnabled,
                      onA11yChanged: (updated) {
                        setState(() {
                          if (_a11yEnabled != updated) {
                            _a11yEnabled = updated;
                            _settingsChanged = true;
                          }
                        });
                      },
                      loaded: _loaded,
                      hasTavilyKey: _hasTavilyKey,
                      tavilyController: _tavilyController,
                      onSaveTavily: _saveTavily,
                      onClearTavily: _clearTavily,
                      memories: _memories,
                      onDeleteMemory: _deleteMemory,
                    ),
                  ),
                  FilesTab(
                    localAttached: _localAttached,
                    picking: _picking,
                    onPickFiles: _pickLocalFiles,
                    onDetachFile: _detachLocal,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
