import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:path/path.dart' as p;

import '../services/intent_service.dart';
import '../theme/app_colors.dart';
import '../utils/markdown_links.dart';
import '../widgets/bubbles/clamped_table_view.dart';

/// Full-page preview screen for task execution output files (Markdown, HTML, text).
class TaskFilePreviewScreen extends StatefulWidget {
  final String filePath;
  final String? title;

  const TaskFilePreviewScreen({
    super.key,
    required this.filePath,
    this.title,
  });

  static Future<void> show(BuildContext context, {required String filePath, String? title}) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (context) => TaskFilePreviewScreen(filePath: filePath, title: title),
      ),
    );
  }

  @override
  State<TaskFilePreviewScreen> createState() => _TaskFilePreviewScreenState();
}

class _TaskFilePreviewScreenState extends State<TaskFilePreviewScreen> {
  bool _loading = true;
  String? _error;
  String _content = '';
  bool _showRaw = false;

  @override
  void initState() {
    super.initState();
    _loadFile();
  }

  Future<void> _loadFile() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final file = File(widget.filePath);
      if (!await file.exists()) {
        if (!mounted) return;
        setState(() {
          _error = 'File not found: ${widget.filePath}';
          _loading = false;
        });
        return;
      }

      final content = await file.readAsString();
      if (!mounted) return;
      setState(() {
        _content = content;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to read file: $e';
        _loading = false;
      });
    }
  }

  bool get _isHtml {
    final ext = p.extension(widget.filePath).toLowerCase();
    if (ext == '.html' || ext == '.htm') return true;
    final lower = _content.trim().toLowerCase();
    return lower.startsWith('<!doctype html') || lower.startsWith('<html');
  }

  @override
  Widget build(BuildContext context) {
    final fileName = widget.title ?? p.basename(widget.filePath);

    return Scaffold(
      backgroundColor: kDarkBg,
      appBar: AppBar(
        backgroundColor: kInputBg,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded, color: kText),
          tooltip: 'Close',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              fileName,
              style: const TextStyle(
                color: kText,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              widget.filePath,
              style: const TextStyle(color: kMuted, fontSize: 11),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        actions: [
          if (!_loading && _error == null) ...[
            IconButton(
              icon: Icon(
                _showRaw ? Icons.visibility_rounded : Icons.code_rounded,
                color: kMuted,
                size: 20,
              ),
              tooltip: _showRaw ? 'Rendered view' : 'Raw source',
              onPressed: () => setState(() => _showRaw = !_showRaw),
            ),
            IconButton(
              icon: const Icon(Icons.copy_rounded, color: kMuted, size: 20),
              tooltip: 'Copy content',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _content));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Copied file content to clipboard'),
                    duration: Duration(seconds: 2),
                    backgroundColor: kBubbleUser,
                  ),
                );
              },
            ),
          ],
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(strokeWidth: 2.5),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, color: kDanger, size: 40),
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: kDanger, fontSize: 14),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: _loadFile,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_showRaw) {
      return SelectionArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Text(
            _content,
            style: const TextStyle(
              color: kText,
              fontSize: 13,
              fontFamily: 'monospace',
              height: 1.45,
            ),
          ),
        ),
      );
    }

    if (_isHtml) {
      return _buildHtmlView();
    }

    return _buildMarkdownView();
  }

  Widget _buildHtmlView() {
    if (InAppWebViewPlatform.instance == null) {
      // Fallback for environments where InAppWebView platform is unavailable (e.g. desktop/tests)
      return SelectionArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Text(
            _content,
            style: const TextStyle(
              color: kText,
              fontSize: 13,
              fontFamily: 'monospace',
            ),
          ),
        ),
      );
    }

    return InAppWebView(
      initialData: InAppWebViewInitialData(
        data: _content,
        mimeType: 'text/html',
        encoding: 'utf-8',
      ),
      initialSettings: InAppWebViewSettings(
        isInspectable: false,
        allowFileAccess: false,
        allowContentAccess: false,
        allowFileAccessFromFileURLs: false,
        allowUniversalAccessFromFileURLs: false,
        geolocationEnabled: false,
        databaseEnabled: false,
        domStorageEnabled: false,
        supportMultipleWindows: false,
        javaScriptCanOpenWindowsAutomatically: false,
        mediaPlaybackRequiresUserGesture: true,
        supportZoom: true,
        builtInZoomControls: true,
        displayZoomControls: false,
        useWideViewPort: true,
        loadWithOverviewMode: true,
      ),
      shouldOverrideUrlLoading: (controller, navigationAction) async {
        // Sandboxed preview: nothing loads inside the WebView. http(s) link
        // taps escape to the external browser so report links stay usable;
        // everything else (iframes, file/, data:, javascript:) stays
        // cancelled and can neither navigate nor exfiltrate local content.
        final url = navigationAction.request.url;
        final scheme = url?.scheme.toLowerCase();
        if (navigationAction.navigationType == NavigationType.LINK_ACTIVATED &&
            (scheme == 'http' || scheme == 'https')) {
          try {
            await IntentService().launchAction('open_url', data: url.toString());
          } catch (_) {}
        }
        return NavigationActionPolicy.CANCEL;
      },
    );
  }

  Widget _buildMarkdownView() {
    return SelectionArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
        child: GptMarkdown(
          _content,
          style: const TextStyle(
            color: kText,
            fontSize: 15,
            height: 1.5,
          ),
          tableBuilder: buildClampedTable,
          onLinkTap: (url, _) => openMarkdownLink(context, url),
        ),
      ),
    );
  }
}
