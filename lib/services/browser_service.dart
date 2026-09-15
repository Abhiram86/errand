import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:html2md/html2md.dart' as html2md;

/// Display modes for the embedded browser UI.
enum BrowserDisplayMode {
  /// Slim dock bar right above composer (ref mockup 1: "Browser full closed").
  closed,

  /// Embedded preview card sitting right above composer (ref mockup 2: "Browser preview").
  preview,

  /// Full-screen overlay covering the entire screen (ref mockup 3: "Browser full screen").
  fullScreen,
}

/// Information about the currently loaded browser page.
class BrowserPageInfo {
  final String url;
  final String title;
  final String status;

  const BrowserPageInfo({
    required this.url,
    required this.title,
    required this.status,
  });

  @override
  String toString() => 'BrowserPageInfo(url: $url, title: $title, status: $status)';
}

/// Abstract controller interface to allow mocking and testing without native platform views.
abstract class BrowserController {
  Future<void> loadUrl(String url);
  Future<void> reload();
  Future<void> goBack();
  Future<void> goForward();
  Future<bool> canGoBack();
  Future<bool> canGoForward();
  Future<dynamic> evaluateJavascript(String source);
  Future<Uint8List?> takeScreenshot();
  Future<String?> getUrl();
  Future<String?> getTitle();
  Future<void> stopLoading();
  Future<void> pauseTimers();
  Future<void> resumeTimers();
}

/// Real implementation of [BrowserController] wrapping [InAppWebViewController].
class InAppWebViewBrowserController implements BrowserController {
  final InAppWebViewController _controller;

  InAppWebViewBrowserController(this._controller);

  @override
  Future<void> loadUrl(String url) async {
    await _controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  @override
  Future<void> reload() async {
    await _controller.reload();
  }

  @override
  Future<void> goBack() async {
    await _controller.goBack();
  }

  @override
  Future<void> goForward() async {
    await _controller.goForward();
  }

  @override
  Future<bool> canGoBack() async {
    return await _controller.canGoBack();
  }

  @override
  Future<bool> canGoForward() async {
    return await _controller.canGoForward();
  }

  @override
  Future<dynamic> evaluateJavascript(String source) async {
    return await _controller.evaluateJavascript(source: source);
  }

  @override
  Future<Uint8List?> takeScreenshot() async {
    return await _controller.takeScreenshot();
  }

  @override
  Future<String?> getUrl() async {
    final uri = await _controller.getUrl();
    return uri?.toString();
  }

  @override
  Future<String?> getTitle() async {
    return await _controller.getTitle();
  }

  @override
  Future<void> stopLoading() async {
    await _controller.stopLoading();
  }

  @override
  Future<void> pauseTimers() async {
    await _controller.pauseTimers();
  }

  @override
  Future<void> resumeTimers() async {
    await _controller.resumeTimers();
  }
}

/// Service managing the single, live embedded browser WebView and its agent interactions.
///
/// Implements high-level navigation, DOM extraction, JavaScript evaluation,
/// and reactive state synchronization with the UI.
class BrowserService extends ChangeNotifier {
  BrowserController? _controller;
  Completer<BrowserController>? _controllerCompleter;
  Completer<void>? _loadCompleter;

  bool _isOpen = false;
  BrowserDisplayMode _displayMode = BrowserDisplayMode.preview;
  String? _currentUrl;
  String? _currentTitle;
  int _progress = 0;
  bool _isLoading = false;
  bool _canGoBack = false;
  bool _canGoForward = false;
  String? _targetLoadingUrl;
  String? _lastError;
  int _navigationGeneration = 0;

  final BrowserController? _controllerOverride;

  BrowserService({BrowserController? controllerOverride})
      : _controllerOverride = controllerOverride {
    if (controllerOverride != null) {
      _controller = controllerOverride;
    }
  }

  static final BrowserService instance = BrowserService();

  // -- Reactive Getters -----------------------------------------------------

  bool get isOpen => _isOpen;
  BrowserDisplayMode get displayMode => _displayMode;
  bool get isExpanded => _isOpen && _displayMode != BrowserDisplayMode.closed;
  String? get currentUrl => _currentUrl;
  String? get currentTitle => _currentTitle;
  int get progress => _progress;
  bool get isLoading => _isLoading;
  bool get canGoBack => _canGoBack;
  bool get canGoForward => _canGoForward;
  bool get hasController => _controller != null;
  String? get lastError => _lastError;
  String? get targetLoadingUrl => _targetLoadingUrl;
  int get navigationGeneration => _navigationGeneration;
  BrowserController? get controllerOverride => _controllerOverride;

  // -- Controller Attachment & Event Callbacks ------------------------------

  /// Attaches the native [InAppWebViewController] when the widget tree mounts it.
  void attachInAppController(InAppWebViewController controller) {
    if (_controllerOverride != null) return;
    _controller = InAppWebViewBrowserController(controller);
    if (_controllerCompleter != null && !_controllerCompleter!.isCompleted) {
      _controllerCompleter!.complete(_controller);
    }
    notifyListeners();
  }

  /// Sets or clears the active controller.
  void setController(BrowserController? controller) {
    _controller = controller;
    if (controller != null && _controllerCompleter != null && !_controllerCompleter!.isCompleted) {
      _controllerCompleter!.complete(controller);
    } else if (controller == null) {
      _controllerCompleter = null;
    }
    notifyListeners();
  }

  void onLoadStart(String? url) {
    final cleanUrl = url?.trim();
    // Do not let about:blank overwrite our target while waiting for a page to load
    if (_targetLoadingUrl != null &&
        _targetLoadingUrl != 'about:blank' &&
        (cleanUrl == null || cleanUrl.isEmpty || cleanUrl == 'about:blank')) {
      return;
    }

    _isLoading = true;
    _progress = 0;
    if (cleanUrl != null && cleanUrl.isNotEmpty) {
      _currentUrl = cleanUrl;
    }
    notifyListeners();
  }

  void onLoadStop(String? url) {
    final cleanUrl = url?.trim();
    // Ignore about:blank native initialization event when we are expecting a real URL
    if (_targetLoadingUrl != null &&
        _targetLoadingUrl != 'about:blank' &&
        (cleanUrl == null || cleanUrl.isEmpty || cleanUrl == 'about:blank')) {
      return;
    }

    _isLoading = false;
    _progress = 100;
    if (cleanUrl != null && cleanUrl.isNotEmpty) {
      _currentUrl = cleanUrl;
    }
    if (_loadCompleter != null && !_loadCompleter!.isCompleted) {
      _loadCompleter!.complete();
    }
    _targetLoadingUrl = null;
    unawaited(_updateNavState());
    unawaited(_syncZoom());
    notifyListeners();
  }

  void onLoadError(String? url, String description, {bool isForMainFrame = true}) {
    if (!isForMainFrame) return;
    _isLoading = false;
    _lastError = description;
    if (_loadCompleter != null && !_loadCompleter!.isCompleted) {
      _loadCompleter!.complete();
    }
    notifyListeners();
  }

  void onProgressChanged(int progress) {
    _progress = progress;
    if (progress >= 100) {
      _isLoading = false;
    }
    notifyListeners();
  }

  void onTitleChanged(String? title) {
    _currentTitle = title;
    notifyListeners();
  }

  Future<void> _updateNavState() async {
    if (_controller == null) return;
    try {
      _canGoBack = await _controller!.canGoBack();
      _canGoForward = await _controller!.canGoForward();
    } catch (_) {}
  }

  // -- Display Mode Controls -----------------------------------------------

  /// Sets the active UI display mode (closed dock bar, preview card, or full screen).
  void setDisplayMode(BrowserDisplayMode mode) {
    if (_displayMode != mode) {
      _displayMode = mode;
      if (mode == BrowserDisplayMode.closed) {
        _controller?.pauseTimers().catchError((_) {});
      } else if (_isOpen) {
        _controller?.resumeTimers().catchError((_) {});
      }
      unawaited(_syncZoom());
      notifyListeners();
    }
  }

  /// Adjusts page zoom based on display mode.
  /// Preview mode uses a moderate zoom-out (0.80) to maximize visible context
  /// while keeping subheadings legible. Fullscreen mode restores normal zoom (1.0).
  Future<void> _syncZoom() async {
    if (_controller == null || !_isOpen) return;
    try {
      final zoom = _displayMode == BrowserDisplayMode.preview ? '0.80' : '1.0';
      await _controller!.evaluateJavascript(
        "try { document.documentElement.style.zoom = '$zoom'; } catch (_) {}",
      );
    } catch (_) {}
  }

  /// Switches to slim dock bar right above composer ("Browser full closed").
  void setClosed() => setDisplayMode(BrowserDisplayMode.closed);

  /// Switches to live preview card sitting right above composer ("Browser preview").
  void setPreview() => setDisplayMode(BrowserDisplayMode.preview);

  /// Switches to full-screen overlay covering the entire screen ("Browser full screen").
  void setFullScreen() => setDisplayMode(BrowserDisplayMode.fullScreen);

  /// Toggles between closed dock bar and preview card.
  void toggleExpand() {
    if (!_isOpen || _displayMode == BrowserDisplayMode.closed) {
      _isOpen = true;
      _controller?.resumeTimers().catchError((_) {});
      setPreview();
    } else {
      setClosed();
    }
  }

  /// Sets expanded state: preview when true, closed when false.
  void setExpanded(bool expanded) {
    if (expanded) {
      _isOpen = true;
      _controller?.resumeTimers().catchError((_) {});
      setPreview();
    } else {
      setClosed();
    }
  }

  void expand() {
    _isOpen = true;
    _controller?.resumeTimers().catchError((_) {});
    setPreview();
  }

  void collapse() => setClosed();

  // -- Browser Actions ------------------------------------------------------

  /// Opens the browser with the given [url] and waits for the page to load.
  ///
  /// The user's active display mode is preserved (defaulting to preview on initial launch).
  Future<BrowserPageInfo> open(
    String url, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    var targetUrl = url.trim();
    if (targetUrl.isEmpty) {
      throw ArgumentError('URL cannot be empty.');
    }

    if (!targetUrl.startsWith('http://') &&
        !targetUrl.startsWith('https://') &&
        !targetUrl.startsWith('about:')) {
      targetUrl = 'https://$targetUrl';
    }

    final generation = ++_navigationGeneration;
    _isOpen = true;
    _currentUrl = targetUrl;
    _targetLoadingUrl = targetUrl;
    _currentTitle = null;
    _lastError = null;
    _isLoading = true;
    _progress = 10;
    _loadCompleter = Completer<void>();
    notifyListeners();

    // If controller is not yet ready, wait for it with timeout
    if (_controller == null) {
      _controllerCompleter ??= Completer<BrowserController>();
      try {
        _controller = await _controllerCompleter!.future.timeout(
          const Duration(seconds: 8),
        );
      } catch (_) {
        if (_controller == null) {
          throw StateError(
            'Browser view is still initializing. Please retry in a moment.',
          );
        }
      }
    }

    try {
      await _controller!.resumeTimers();
    } catch (_) {}

    if (_controllerOverride != null) {
      await _controller!.loadUrl(targetUrl);
    } else {
      bool timedOut = false;
      try {
        await _controller!.loadUrl(targetUrl);
        await _loadCompleter!.future.timeout(timeout);
      } on TimeoutException {
        timedOut = true;
        _lastError ??= 'Navigation timed out after ${timeout.inSeconds}s';
      } catch (e) {
        _lastError ??= e.toString();
      }

      if (generation != _navigationGeneration) {
        return BrowserPageInfo(
          url: _currentUrl ?? targetUrl,
          title: _currentTitle ?? '',
          status: 'superseded',
        );
      }

      // Verify URL reported by controller
      final actualUrl = await _controller!.getUrl();
      if (actualUrl != null &&
          actualUrl != 'about:blank' &&
          actualUrl.isNotEmpty) {
        _currentUrl = actualUrl;
      } else if (!timedOut && (_currentUrl == 'about:blank' || _currentUrl == null)) {
        await Future.delayed(const Duration(milliseconds: 300));
        try {
          await _controller!.loadUrl(targetUrl);
          await Future.delayed(const Duration(milliseconds: 500));
          final retryUrl = await _controller!.getUrl();
          if (retryUrl != null &&
              retryUrl.isNotEmpty &&
              retryUrl != 'about:blank') {
            _currentUrl = retryUrl;
          }
        } catch (_) {}
      }

      // Brief settle delay for dynamic rendering if not errored
      if (!timedOut && _lastError == null) {
        await Future.delayed(const Duration(milliseconds: 350));
      }
    }

    if (generation != _navigationGeneration) {
      return BrowserPageInfo(
        url: _currentUrl ?? targetUrl,
        title: _currentTitle ?? '',
        status: 'superseded',
      );
    }

    _isLoading = false;
    _targetLoadingUrl = null;
    final isError = _lastError != null;
    if (!isError) {
      final reportedUrl = await _controller!.getUrl();
      if (reportedUrl != null && reportedUrl.isNotEmpty && reportedUrl != 'about:blank') {
        _currentUrl = reportedUrl;
      }
      final reportedTitle = await _controller!.getTitle();
      if (reportedTitle != null && reportedTitle.isNotEmpty) {
        _currentTitle = reportedTitle;
      }
    } else {
      _currentTitle = null;
    }
    await _updateNavState();
    await _syncZoom();
    notifyListeners();

    final hasLoadedPage = !isError &&
        _currentUrl != null &&
        _currentUrl != 'about:blank';

    return BrowserPageInfo(
      url: _currentUrl ?? targetUrl,
      title: _currentTitle ?? '',
      status: isError
          ? 'error: $_lastError'
          : (hasLoadedPage ? 'loaded' : 'unknown'),
    );
  }

  /// Closes the browser sheet and optionally resets the page.
  Future<void> close({bool clear = false}) async {
    _isOpen = false;
    if (_controller != null) {
      try {
        await _controller!.stopLoading();
      } catch (_) {}
      try {
        await _controller!.pauseTimers();
      } catch (_) {}
      if (clear) {
        try {
          await _controller!.loadUrl('about:blank');
          _currentUrl = null;
          _currentTitle = null;
        } catch (_) {}
      }
    }
    notifyListeners();
  }

  /// Reloads the currently active page.
  Future<BrowserPageInfo> reload({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    _ensureOpenAndReady();

    final generation = ++_navigationGeneration;
    _isLoading = true;
    _progress = 10;
    _lastError = null;
    _currentTitle = null;
    _loadCompleter = Completer<void>();
    notifyListeners();

    try {
      await _controller!.resumeTimers();
    } catch (_) {}

    if (_controllerOverride != null) {
      await _controller!.reload();
    } else {
      bool timedOut = false;
      try {
        await _controller!.reload();
        await _loadCompleter!.future.timeout(timeout);
      } on TimeoutException {
        timedOut = true;
        _lastError ??= 'Reload timed out after ${timeout.inSeconds}s';
      } catch (e) {
        _lastError ??= e.toString();
      }
      if (!timedOut && _lastError == null) {
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }

    if (generation != _navigationGeneration) {
      return BrowserPageInfo(
        url: _currentUrl ?? '',
        title: _currentTitle ?? '',
        status: 'superseded',
      );
    }

    _isLoading = false;
    final isError = _lastError != null;
    if (!isError) {
      _currentUrl = await _controller!.getUrl() ?? _currentUrl;
      final reportedTitle = await _controller!.getTitle();
      if (reportedTitle != null && reportedTitle.isNotEmpty) {
        _currentTitle = reportedTitle;
      }
    } else {
      _currentTitle = null;
    }
    await _updateNavState();
    await _syncZoom();
    notifyListeners();

    return BrowserPageInfo(
      url: _currentUrl ?? '',
      title: _currentTitle ?? '',
      status: isError ? 'error: $_lastError' : 'reloaded',
    );
  }

  /// Navigates back in webview history.
  Future<void> goBack() async {
    if (_controller != null) {
      await _controller!.goBack();
      await _updateNavState();
      notifyListeners();
    }
  }

  /// Navigates forward in webview history.
  Future<void> goForward() async {
    if (_controller != null) {
      await _controller!.goForward();
      await _updateNavState();
      notifyListeners();
    }
  }

  /// Stops ongoing page loading.
  Future<void> stopLoading() async {
    if (_controller != null) {
      await _controller!.stopLoading();
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Extracts a structured DOM outline containing interactive elements,
  /// assigned `data-agent-id` references, scroll position, and text preview.
  /// When [ref] or [selector] is provided, scopes the snapshot to that specific container element.
  /// When [fullDump] is true, returns the pure DOM HTML dump paginated with [dumpOffset] and [dumpLimit].
  Future<String> snapshot({
    int maxNodes = 200,
    bool fullDump = false,
    int dumpOffset = 0,
    int dumpLimit = 100000,
    String? ref,
    String? selector,
  }) async {
    _ensureOpenAndReady();

    if (fullDump) {
      final safeOffset = dumpOffset.clamp(0, 50000000);
      final safeLimit = dumpLimit.clamp(1000, 200000);
      final dumpScript = '''
(() => {
  try {
    const html = document.documentElement ? document.documentElement.outerHTML : '';
    const total = html.length;
    const offset = $safeOffset;
    const limit = $safeLimit;
    const chunk = html.slice(offset, offset + limit);
    return JSON.stringify({
      chunk: chunk,
      total: total,
      offset: offset,
      length: chunk.length,
      hasMore: (offset + chunk.length) < total
    });
  } catch (e) {
    return JSON.stringify({ error: e.toString() });
  }
})()
''';
      final raw = await _controller!.evaluateJavascript(dumpScript);
      if (raw == null || raw.toString().trim().isEmpty) {
        return 'Pure DOM dump returned empty.';
      }
      try {
        final decoded = jsonDecode(raw.toString()) as Map<String, dynamic>;
        if (decoded.containsKey('error')) {
          return 'DOM dump error: ${decoded['error']}';
        }
        final chunk = decoded['chunk']?.toString() ?? '';
        final total = decoded['total'] ?? chunk.length;
        final offset = decoded['offset'] ?? safeOffset;
        final hasMore = decoded['hasMore'] == true;
        if (chunk.isEmpty) {
          return 'Pure DOM dump returned empty (offset $offset >= total $total).';
        }
        final buffer = StringBuffer();
        buffer.writeln('<!-- DOM Dump chunk [$offset..${offset + chunk.length} of $total chars] -->');
        buffer.writeln(chunk);
        if (hasMore) {
          buffer.writeln();
          buffer.writeln('<!-- [More DOM content available: call snapshot(full_dump: true, dump_offset: ${offset + chunk.length})] -->');
        }
        return buffer.toString().trim();
      } catch (_) {
        return raw.toString().trim();
      }
    }

    final targetRef = ref?.trim();
    final targetSel = selector?.trim();
    final script = _kPlaywrightSnapshotScript
        .replaceFirst('__MAX_NODES__', '$maxNodes')
        .replaceFirst('__TARGET_REF__', targetRef != null && targetRef.isNotEmpty ? jsonEncode(targetRef) : 'null')
        .replaceFirst('__TARGET_SEL__', targetSel != null && targetSel.isNotEmpty ? jsonEncode(targetSel) : 'null');
    final raw = await _controller!.evaluateJavascript(script);

    if (raw == null) {
      return 'Snapshot failed: no response from browser DOM.';
    }

    try {
      final decoded = jsonDecode(raw.toString()) as Map<String, dynamic>;

      if (decoded.containsKey('error')) {
        return 'Snapshot error: ${decoded['error']}';
      }

      final meta = decoded['meta'] as Map<String, dynamic>? ?? {};
      final stats = decoded['stats'] as Map<String, dynamic>? ?? {};

      final buffer = StringBuffer();

      buffer.writeln('Page Title: ${meta['title'] ?? ''}');
      buffer.writeln('URL: ${meta['url'] ?? ''}');
      if (meta['scoped'] != null && meta['scoped'].toString().isNotEmpty) {
        buffer.writeln('Scope: ${meta['scoped']}');
      }

      final scroll = meta['scroll'] as Map<String, dynamic>? ?? {};
      buffer.writeln(
        'Scroll: (${scroll['x'] ?? 0}, ${scroll['y'] ?? 0}) '
        '/ ${scroll['totalHeight'] ?? 0}px',
      );
      buffer.writeln();

      final tree = decoded['tree']?.toString().trim() ?? '';
      if (tree.isNotEmpty) {
        buffer.writeln(tree);
      } else {
        // Backward-compatible fallback if structured 'nodes' list was provided
        final nodes = decoded['nodes'] as List<dynamic>? ?? [];
        if (nodes.isNotEmpty) {
          for (final item in nodes) {
            if (item is! Map) continue;
            final ref = item['ref'];
            final tag = item['tag'] ?? 'generic';
            final name = item['name'];
            final text = item['text'];
            final domId = item['id'];
            final domClass = item['class'];
            final href = item['href'];
            final role = item['role'] ?? tag;
            final parts = <String>[
              if (name != null && name.toString().isNotEmpty) '"$name"',
              if (ref != null) '[ref=$ref]',
              if (item['level'] != null) '[level=${item['level']}]',
              if (domId != null && domId.toString().isNotEmpty) '[id="$domId"]',
              if (domClass != null && domClass.toString().isNotEmpty) '[class="$domClass"]',
              if (item['cursor'] == true || tag == 'a' || tag == 'button' || role == 'button' || role == 'link')
                '[cursor=pointer]',
              if (item['value'] != null) '[value="${item['value']}"]',
            ];
            final hasSub = href != null && href.toString().isNotEmpty;
            buffer.writeln('- $role ${parts.join(' ')}${hasSub ? ':' : ''}');
            if (hasSub) {
              buffer.writeln('  - /url: $href');
            }
            if (text != null && text.toString().isNotEmpty && text != name) {
              buffer.writeln('  - text: $text');
            }
          }
        } else {
          buffer.writeln('(Empty page or no visible content)');
        }
      }

      if (stats['truncated'] == true) {
        buffer.writeln();
        final reason = stats['reason'];
        if (reason == 'traversal_budget') {
          buffer.writeln('[Snapshot capped by traversal/time budget (${stats['visitedCount']} elements visited)]');
        } else {
          buffer.writeln('[Snapshot truncated at $maxNodes nodes]');
        }
      }

      return buffer.toString().trim();
    } catch (e) {
      return 'Snapshot parsing error: $e\nRaw: $raw';
    }
  }

  /// Extracts clean Markdown text from the current page using html2md.
  /// If [selector] is provided, extracts text only from the matching container element.
  /// Caps internal HTML extraction at [maxChars] (default 150000) inside page JS to protect memory.
  Future<String> extractText({String? selector, int maxChars = 150000}) async {
    _ensureOpenAndReady();

    final targetSel = selector?.trim();
    final safeMaxChars = maxChars.clamp(1000, 500000);
    final script = '''
(() => {
  try {
    let target = null;
    ${targetSel != null && targetSel.isNotEmpty ? 'target = document.querySelector(${jsonEncode(targetSel)});' : ''}
    if (!target) target = document.body || document.documentElement;
    if (!target) return JSON.stringify({ html: '', truncated: false, total: 0 });
    const clone = target.cloneNode(true);
    const toRemove = clone.querySelectorAll('script, style, noscript, svg, iframe, object, embed, applet');
    toRemove.forEach(el => el.remove());
    let rawHtml = clone.innerHTML || '';
    const total = rawHtml.length;
    const MAX_CHARS = $safeMaxChars;
    const isTruncated = total > MAX_CHARS;
    if (isTruncated) {
      rawHtml = rawHtml.slice(0, MAX_CHARS);
    }
    return JSON.stringify({ html: rawHtml, truncated: isTruncated, total: total });
  } catch (e) {
    return JSON.stringify({ html: (document.body ? document.body.innerHTML.slice(0, $safeMaxChars) : ''), truncated: false, total: 0, error: e.toString() });
  }
})()
''';

    final raw = await _controller!.evaluateJavascript(script);
    if (raw == null || raw.toString().trim().isEmpty) {
      return 'Page returned empty content.';
    }

    String html = '';
    bool truncated = false;
    try {
      final decoded = jsonDecode(raw.toString()) as Map<String, dynamic>;
      html = decoded['html']?.toString() ?? '';
      truncated = decoded['truncated'] == true;
    } catch (_) {
      html = raw.toString();
    }

    if (html.trim().isEmpty) {
      return 'Page returned empty content.';
    }

    final markdown = html2md.convert(
      html,
      styleOptions: {'headingStyle': 'atx'},
    );
    if (markdown.trim().isEmpty) {
      return 'No readable text could be extracted from the page.';
    }
    final result = markdown.trim();
    if (truncated) {
      return '$result\n\n[Content truncated at $safeMaxChars characters. Pass selector for specific section.]';
    }
    return result;
  }

  /// Evaluates arbitrary JavaScript in the page DOM and returns the result.
  /// Result serialization is capped inside page JS at [maxChars] (default 50000) to protect memory.
  Future<String> executeDomJs(String script, {int maxChars = 50000}) async {
    _ensureOpenAndReady();

    final trimmed = script.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('JavaScript script cannot be empty.');
    }

    final safeMaxChars = maxChars.clamp(500, 200000);
    final wrapped = '''
(() => {
  const MAX_RES_CHARS = $safeMaxChars;
  try {
    const val = (function() { $trimmed })();
    if (val === undefined) return JSON.stringify({ ok: true, result: null, type: 'undefined', truncated: false });
    let serialized = '';
    const type = typeof val;
    if (type === 'string') {
      serialized = val;
    } else {
      try {
        serialized = JSON.stringify(val);
      } catch (_) {
        serialized = String(val);
      }
    }
    const truncated = serialized.length > MAX_RES_CHARS;
    if (truncated) {
      serialized = serialized.slice(0, MAX_RES_CHARS);
    }
    return JSON.stringify({ ok: true, result: serialized, type: type, truncated: truncated });
  } catch (err) {
    return JSON.stringify({ ok: false, error: err.toString() });
  }
})()
''';

    final raw = await _controller!.evaluateJavascript(wrapped);
    if (raw == null) {
      return 'JavaScript execution returned null.';
    }

    try {
      final decoded = jsonDecode(raw.toString());
      if (decoded is Map) {
        if (decoded['ok'] == false) {
          return 'JavaScript error: ${decoded['error']}';
        }
        final res = decoded['result'];
        final truncated = decoded['truncated'] == true;
        final suffix = truncated ? '\n[Result capped at $safeMaxChars characters]' : '';
        if (res == null) return 'Result: null$suffix';
        if (decoded['type'] == 'string') return 'Result: "$res"$suffix';
        return 'Result: $res$suffix';
      }
      return 'Result: $raw';
    } catch (_) {
      return 'Result: $raw';
    }
  }

  /// Performs a high-level action (click, type, select, get, or scroll) on the page.
  Future<String> act({
    required String action,
    String? ref,
    String? selector,
    String? text,
    String? direction,
  }) async {
    _ensureOpenAndReady();

    final actType = action.trim().toLowerCase();
    switch (actType) {
      case 'click':
        return await _actClick(ref: ref, selector: selector);
      case 'type':
        return await _actType(ref: ref, selector: selector, text: text ?? '');
      case 'select':
      case 'choose':
        return await _actSelect(ref: ref, selector: selector, text: text ?? '');
      case 'get':
      case 'read':
        return await _actGet(ref: ref, selector: selector);
      case 'scroll':
        return await _actScroll(direction: direction ?? 'down');
      case 'back':
        await goBack();
        return 'Navigated back.';
      case 'forward':
        await goForward();
        return 'Navigated forward.';
      default:
        throw ArgumentError('Unknown act action "$action". Supported: click, type, select, get, scroll, back, forward.');
    }
  }

  String _resolveElementJs(String? ref, String? sel) {
    return '''
  let el = null;
  ${ref != null && ref.isNotEmpty ? '''
  el = document.querySelector('[data-agent-id="$ref"]');
  if (!el) el = document.getElementById(${jsonEncode(ref)});
  if (!el) {
    try { el = document.querySelector(${jsonEncode(ref)}); } catch (_) {}
  }
  ''' : ''}
  if (!el && ${sel != null && sel.isNotEmpty ? 'true' : 'false'}) {
    try { el = document.querySelector(${jsonEncode(sel)}); } catch (_) {}
  }
''';
  }

  Future<String> _actClick({String? ref, String? selector}) async {
    final targetRef = ref?.trim();
    final targetSel = selector?.trim();
    if ((targetRef == null || targetRef.isEmpty) && (targetSel == null || targetSel.isEmpty)) {
      throw ArgumentError('Either ref or selector is required to click an element.');
    }

    final script = '''
(() => {
  ${_resolveElementJs(targetRef, targetSel)}
  if (!el) return JSON.stringify({ ok: false, error: 'Element not found' });
  try {
    el.scrollIntoView({ behavior: 'instant', block: 'center' });
    if (typeof el.focus === 'function') el.focus();

    const tag = el.tagName.toLowerCase();
    const isCheckable = el instanceof HTMLInputElement && (el.type === 'checkbox' || el.type === 'radio');

    const mouseEvents = ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click'];
    for (const evtName of mouseEvents) {
      try {
        const evt = new MouseEvent(evtName, {
          bubbles: true,
          cancelable: true,
          view: window,
          buttons: 1
        });
        el.dispatchEvent(evt);
      } catch (_) {}
    }
    if (typeof el.click === 'function') {
      el.click();
    }

    let checked = undefined;
    if (isCheckable) {
      checked = el.checked;
    }

    return JSON.stringify({
      ok: true,
      tag: tag,
      text: (el.innerText || el.textContent || '').trim().slice(0, 50),
      checked: checked,
      value: el.value ? el.value.slice(0, 50) : undefined
    });
  } catch (err) {
    return JSON.stringify({ ok: false, error: err.toString() });
  }
})()
''';

    final raw = await _controller!.evaluateJavascript(script);
    try {
      final decoded = jsonDecode(raw.toString()) as Map<String, dynamic>;
      if (decoded['ok'] == true) {
        final tag = decoded['tag'] ?? 'element';
        final text = decoded['text'] ?? '';
        final targetStr = targetRef != null ? '[$targetRef]' : (targetSel ?? '');
        final checked = decoded['checked'];
        final buffer = StringBuffer('Clicked $targetStr <$tag>${text.isNotEmpty ? ' "$text"' : ''}.');
        if (checked != null) {
          buffer.write(' (checked: $checked)');
        }
        return buffer.toString().trim();
      } else {
        return 'Click failed: ${decoded['error']}.';
      }
    } catch (_) {
      return 'Click executed.';
    }
  }

  Future<String> _actType({String? ref, String? selector, required String text}) async {
    final targetRef = ref?.trim();
    final targetSel = selector?.trim();
    if ((targetRef == null || targetRef.isEmpty) && (targetSel == null || targetSel.isEmpty)) {
      throw ArgumentError('Either ref or selector is required to type into an element.');
    }

    final script = '''
(() => {
  ${_resolveElementJs(targetRef, targetSel)}
  if (!el) return JSON.stringify({ ok: false, error: 'Element not found' });
  try {
    el.scrollIntoView({ behavior: 'instant', block: 'center' });
    if (typeof el.focus === 'function') el.focus();

    const val = ${jsonEncode(text)};
    const tag = el.tagName.toLowerCase();

    // Auto-delegate to select logic if type is called on a <select>
    if (el instanceof HTMLSelectElement || tag === 'select') {
      const targetValLower = (val || '').toLowerCase().trim();
      let matchedIndex = -1;
      for (let i = 0; i < el.options.length; i++) {
        if (el.options[i].value === val || el.options[i].value.toLowerCase() === targetValLower) {
          matchedIndex = i; break;
        }
      }
      if (matchedIndex === -1) {
        for (let i = 0; i < el.options.length; i++) {
          if (el.options[i].text.trim().toLowerCase() === targetValLower) {
            matchedIndex = i; break;
          }
        }
      }
      if (matchedIndex === -1) {
        for (let i = 0; i < el.options.length; i++) {
          if (el.options[i].text.trim().toLowerCase().includes(targetValLower)) {
            matchedIndex = i; break;
          }
        }
      }
      if (matchedIndex !== -1) {
        el.selectedIndex = matchedIndex;
        const selectedValue = el.options[matchedIndex].value;
        const proto = window.HTMLSelectElement.prototype;
        const desc = Object.getOwnPropertyDescriptor(proto, 'value');
        if (desc && desc.set) { desc.set.call(el, selectedValue); } else { el.value = selectedValue; }
        if (el._valueTracker) { el._valueTracker.setValue(''); }
        el.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
        el.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
        return JSON.stringify({
          ok: true,
          tag: 'select',
          selected: true,
          text: el.options[matchedIndex].text.trim(),
          value: selectedValue
        });
      }
      return JSON.stringify({ ok: false, error: 'Option "' + val + '" not found in <select>' });
    }

    if (el.isContentEditable) {
      try {
        document.execCommand('selectAll', false, null);
        document.execCommand('insertText', false, val);
      } catch (_) {
        el.innerText = val;
      }
    } else if (
      el instanceof HTMLInputElement ||
      el instanceof HTMLTextAreaElement ||
      'value' in el
    ) {
      const proto = el instanceof HTMLTextAreaElement
        ? window.HTMLTextAreaElement.prototype
        : window.HTMLInputElement.prototype;
      const desc = Object.getOwnPropertyDescriptor(proto, 'value');
      if (desc && desc.set) {
        desc.set.call(el, val);
      } else {
        el.value = val;
      }

      if (el._valueTracker) {
        el._valueTracker.setValue('');
      }
    } else {
      el.value = val;
    }

    try {
      el.dispatchEvent(new InputEvent('input', {
        bubbles: true,
        composed: true,
        data: val,
        inputType: 'insertText'
      }));
    } catch (_) {
      el.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
    }
    el.dispatchEvent(new Event('change', { bubbles: true }));

    const currentVal = el.value != null ? String(el.value).slice(0, 100) : (el.innerText || '').trim().slice(0, 100);
    return JSON.stringify({ ok: true, tag: tag, value: currentVal });
  } catch (err) {
    return JSON.stringify({ ok: false, error: err.toString() });
  }
})()
''';

    final raw = await _controller!.evaluateJavascript(script);
    try {
      final decoded = jsonDecode(raw.toString()) as Map<String, dynamic>;
      if (decoded['ok'] == true) {
        final tag = decoded['tag'] ?? 'element';
        final targetStr = targetRef != null ? '[$targetRef]' : (targetSel ?? '');
        if (decoded['selected'] == true) {
          final optText = decoded['text'] ?? '';
          final optVal = decoded['value'] ?? '';
          return 'Selected "$optText" (value: "$optVal") in $targetStr <select>.';
        }
        final currentVal = decoded['value'];
        final buffer = StringBuffer('Typed "$text" into $targetStr <$tag>.');
        if (currentVal != null) {
          buffer.write(' (current value: "$currentVal")');
        }
        return buffer.toString().trim();
      } else {
        return 'Type failed: ${decoded['error']}.';
      }
    } catch (_) {
      return 'Typed text.';
    }
  }

  Future<String> _actSelect({String? ref, String? selector, required String text}) async {
    final targetRef = ref?.trim();
    final targetSel = selector?.trim();
    if ((targetRef == null || targetRef.isEmpty) && (targetSel == null || targetSel.isEmpty)) {
      throw ArgumentError('Either ref or selector is required to select an option.');
    }

    final script = '''
(() => {
  ${_resolveElementJs(targetRef, targetSel)}
  if (!el) return JSON.stringify({ ok: false, error: 'Element not found' });
  try {
    el.scrollIntoView({ behavior: 'instant', block: 'center' });
    if (typeof el.focus === 'function') el.focus();

    const targetVal = ${jsonEncode(text)};
    const targetValLower = (targetVal || '').toLowerCase().trim();

    if (!(el instanceof HTMLSelectElement) && el.tagName.toLowerCase() !== 'select') {
      return JSON.stringify({ ok: false, error: 'Element is <' + el.tagName.toLowerCase() + '>, not a <select> element' });
    }

    let matchedIndex = -1;
    for (let i = 0; i < el.options.length; i++) {
      if (el.options[i].value === targetVal || el.options[i].value.toLowerCase() === targetValLower) {
        matchedIndex = i; break;
      }
    }
    if (matchedIndex === -1) {
      for (let i = 0; i < el.options.length; i++) {
        if (el.options[i].text.trim().toLowerCase() === targetValLower) {
          matchedIndex = i; break;
        }
      }
    }
    if (matchedIndex === -1) {
      for (let i = 0; i < el.options.length; i++) {
        if (el.options[i].text.trim().toLowerCase().includes(targetValLower)) {
          matchedIndex = i; break;
        }
      }
    }

    if (matchedIndex !== -1) {
      el.selectedIndex = matchedIndex;
      const selectedValue = el.options[matchedIndex].value;
      const proto = window.HTMLSelectElement.prototype;
      const desc = Object.getOwnPropertyDescriptor(proto, 'value');
      if (desc && desc.set) { desc.set.call(el, selectedValue); } else { el.value = selectedValue; }
      if (el._valueTracker) { el._valueTracker.setValue(''); }
      el.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
      el.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
      return JSON.stringify({
        ok: true,
        tag: 'select',
        text: el.options[matchedIndex].text.trim(),
        value: selectedValue
      });
    }

    const available = Array.from(el.options).slice(0, 10).map(o => o.text.trim() || o.value).join(', ');
    return JSON.stringify({
      ok: false,
      error: 'Option "' + targetVal + '" not found in <select> (available: ' + available + ')'
    });
  } catch (err) {
    return JSON.stringify({ ok: false, error: err.toString() });
  }
})()
''';

    final raw = await _controller!.evaluateJavascript(script);
    try {
      final decoded = jsonDecode(raw.toString()) as Map<String, dynamic>;
      if (decoded['ok'] == true) {
        final optText = decoded['text'] ?? '';
        final optVal = decoded['value'] ?? '';
        final targetStr = targetRef != null ? '[$targetRef]' : (targetSel ?? '');
        return 'Selected "$optText" (value: "$optVal") in $targetStr <select>.';
      } else {
        return 'Select failed: ${decoded['error']}.';
      }
    } catch (_) {
      return 'Option selected.';
    }
  }

  Future<String> _actGet({String? ref, String? selector}) async {
    final targetRef = ref?.trim();
    final targetSel = selector?.trim();
    if ((targetRef == null || targetRef.isEmpty) && (targetSel == null || targetSel.isEmpty)) {
      throw ArgumentError('Either ref or selector is required to inspect an element.');
    }

    final script = '''
(() => {
  ${_resolveElementJs(targetRef, targetSel)}
  if (!el) return JSON.stringify({ ok: false, error: 'Element not found' });
  try {
    const tag = el.tagName.toLowerCase();
    let val = undefined;
    if (el instanceof HTMLSelectElement) {
      val = Array.from(el.selectedOptions).map(o => o.text.trim()).join(', ') || el.value;
    } else if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement || 'value' in el) {
      val = el.value;
    }
    const text = (el.innerText || el.textContent || '').trim().slice(0, 80);
    const checked = (el.type === 'checkbox' || el.type === 'radio') ? el.checked : undefined;
    const disabled = el.disabled || el.getAttribute('aria-disabled') === 'true';

    return JSON.stringify({
      ok: true,
      tag: tag,
      id: el.id || undefined,
      value: val,
      text: text || undefined,
      checked: checked,
      disabled: disabled
    });
  } catch (err) {
    return JSON.stringify({ ok: false, error: err.toString() });
  }
})()
''';

    final raw = await _controller!.evaluateJavascript(script);
    try {
      final decoded = jsonDecode(raw.toString()) as Map<String, dynamic>;
      if (decoded['ok'] == true) {
        final tag = decoded['tag'] ?? 'element';
        final domId = decoded['id'];
        final targetStr = targetRef != null ? '[$targetRef]' : (targetSel ?? '');
        final parts = <String>[];
        if (decoded['value'] != null) parts.add('value: "${decoded['value']}"');
        if (decoded['checked'] != null) parts.add('checked: ${decoded['checked']}');
        if (decoded['disabled'] == true) parts.add('disabled: true');
        if (decoded['text'] != null && decoded['text'].toString().isNotEmpty) parts.add('text: "${decoded['text']}"');
        return 'Element $targetStr <$tag${domId != null ? ' id="$domId"' : ''}>${parts.isNotEmpty ? ': ${parts.join(', ')}' : ''}.';
      } else {
        return 'Get element failed: ${decoded['error']}.';
      }
    } catch (_) {
      return 'Element inspected.';
    }
  }

  Future<String> _actScroll({required String direction}) async {
    final dir = direction.trim().toLowerCase();
    final script = '''
(() => {
  const dir = '$dir';
  if (dir === 'top') {
    window.scrollTo({ top: 0, behavior: 'instant' });
  } else if (dir === 'bottom') {
    window.scrollTo({ top: document.body.scrollHeight, behavior: 'instant' });
  } else if (dir === 'up') {
    window.scrollBy({ top: -Math.round(window.innerHeight * 0.7), behavior: 'instant' });
  } else {
    window.scrollBy({ top: Math.round(window.innerHeight * 0.7), behavior: 'instant' });
  }
  return JSON.stringify({
    ok: true,
    scrollY: Math.round(window.scrollY),
    totalH: Math.round(document.documentElement.scrollHeight || document.body.scrollHeight)
  });
})()
''';

    final raw = await _controller!.evaluateJavascript(script);
    try {
      final decoded = jsonDecode(raw.toString()) as Map<String, dynamic>;
      final y = decoded['scrollY'] ?? 0;
      final total = decoded['totalH'] ?? 0;
      return 'Scrolled $dir (current scroll: ${y}px / ${total}px).';
    } catch (_) {
      return 'Scrolled $dir.';
    }
  }

  /// Takes a screenshot of the visible browser viewport.
  Future<Uint8List?> takeScreenshot() async {
    _ensureOpenAndReady();
    return await _controller!.takeScreenshot();
  }

  void _ensureOpenAndReady() {
    if (!_isOpen) {
      throw StateError('Browser is not open. Call browser(action: "open", url: "...") first.');
    }
    if (_controller == null) {
      throw StateError('Browser controller is not ready.');
    }
  }
}

/// Token-efficient Playwright-style accessibility tree snapshot generator script.
const String _kPlaywrightSnapshotScript = r'''
(() => {
  const MAX_NODES = __MAX_NODES__;
  const TARGET_REF = __TARGET_REF__;
  const TARGET_SEL = __TARGET_SEL__;
  const MAX_TRAVERSAL = Math.max(MAX_NODES * 10, 1500);
  const TIME_BUDGET_MS = 1000;
  const startTime = Date.now();
  let nextId = 1;
  let nodeCount = 0;
  let visitedCount = 0;
  let hitBudget = false;

  function cleanText(val, max = 150) {
    if (!val) return '';
    return String(val)
      .replace(/\s+/g, ' ')
      .replace(/\u00a0/g, ' ')
      .trim()
      .slice(0, max);
  }

  function isVisible(el) {
    if (!(el instanceof Element)) return false;
    const tag = el.tagName.toLowerCase();
    if (tag === 'script' || tag === 'style' || tag === 'noscript' || tag === 'template' || tag === 'svg' || tag === 'path') {
      return false;
    }
    if (el.getAttribute('aria-hidden') === 'true') {
      return false;
    }
    const style = window.getComputedStyle(el);
    if (
      style.display === 'none' ||
      style.visibility === 'hidden' ||
      style.visibility === 'collapse' ||
      style.opacity === '0'
    ) {
      return false;
    }
    const rect = el.getBoundingClientRect();
    if (rect.width === 0 && rect.height === 0) {
      if (!el.firstElementChild) return false;
    }
    return true;
  }

  const INTERACTIVE_ROLES = new Set([
    'button', 'link', 'checkbox', 'radio', 'switch', 'tab', 'menuitem',
    'option', 'combobox', 'textbox', 'searchbox', 'slider', 'spinbutton'
  ]);

  const LANDMARK_ROLES = new Set([
    'banner', 'navigation', 'main', 'contentinfo', 'complementary',
    'region', 'search', 'form', 'dialog', 'article'
  ]);

  function getImplicitRole(el) {
    const tag = el.tagName.toLowerCase();
    switch (tag) {
      case 'a': return el.hasAttribute('href') ? 'link' : '';
      case 'button': return 'button';
      case 'input': {
        const type = (el.getAttribute('type') || 'text').toLowerCase();
        if (['button', 'submit', 'reset'].includes(type)) return 'button';
        if (type === 'checkbox') return 'checkbox';
        if (type === 'radio') return 'radio';
        if (type === 'range') return 'slider';
        if (type === 'number') return 'spinbutton';
        if (type === 'search') return 'searchbox';
        if (type === 'hidden') return '';
        return 'textbox';
      }
      case 'textarea': return 'textbox';
      case 'select': return el.hasAttribute('multiple') ? 'listbox' : 'combobox';
      case 'option': return 'option';
      case 'header': return 'banner';
      case 'nav': return 'navigation';
      case 'main': return 'main';
      case 'footer': return 'contentinfo';
      case 'aside': return 'complementary';
      case 'article': return 'article';
      case 'section': return 'region';
      case 'form': return 'form';
      case 'dialog': return 'dialog';
      case 'ul':
      case 'ol': return 'list';
      case 'li': return 'listitem';
      case 'table': return 'table';
      case 'tr': return 'row';
      case 'th': return 'columnheader';
      case 'td': return 'cell';
      case 'img': return 'img';
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6': return 'heading';
      default: return '';
    }
  }

  function getRole(el) {
    const explicit = el.getAttribute('role');
    if (explicit) return explicit.trim().toLowerCase();
    return getImplicitRole(el);
  }

  function getHeadingLevel(el) {
    const tag = el.tagName.toLowerCase();
    if (/^h[1-6]$/.test(tag)) {
      return Number(tag[1]);
    }
    const ariaLevel = el.getAttribute('aria-level');
    if (ariaLevel) {
      const num = Number(ariaLevel);
      if (!isNaN(num) && num > 0) return num;
    }
    return undefined;
  }

  function getAgentId(el) {
    let id = el.getAttribute('data-agent-id');
    if (!id) {
      id = 'e' + nextId++;
      el.setAttribute('data-agent-id', id);
    }
    return id;
  }

  function isInteractive(el, role) {
    if (INTERACTIVE_ROLES.has(role)) return true;
    const tag = el.tagName.toLowerCase();
    if (tag === 'button' || tag === 'select' || tag === 'textarea') return true;
    if (tag === 'a' && el.hasAttribute('href')) return true;
    if (tag === 'input' && (el.getAttribute('type') || '').toLowerCase() !== 'hidden') return true;
    if (el.hasAttribute('onclick') || el.tabIndex >= 0) return true;
    try {
      if (window.getComputedStyle(el).cursor === 'pointer') return true;
    } catch (_) {}
    return false;
  }

  function getAccessibleName(el, role) {
    const ariaLabel = el.getAttribute('aria-label');
    if (ariaLabel && ariaLabel.trim()) return cleanText(ariaLabel);

    const ariaLabelledby = el.getAttribute('aria-labelledby');
    if (ariaLabelledby) {
      const parts = ariaLabelledby.split(/\s+/)
        .map(id => document.getElementById(id))
        .filter(Boolean)
        .map(n => cleanText(n.innerText || n.textContent));
      const res = cleanText(parts.join(' '));
      if (res) return res;
    }

    const tag = el.tagName.toLowerCase();
    if (tag === 'img') {
      const alt = el.getAttribute('alt');
      if (alt != null) return cleanText(alt);
      const title = el.getAttribute('title');
      if (title) return cleanText(title);
      return '';
    }

    if (tag === 'input' || tag === 'textarea' || tag === 'select') {
      if (el.id) {
        try {
          const label = document.querySelector('label[for="' + CSS.escape(el.id) + '"]');
          if (label) {
            const t = cleanText(label.innerText || label.textContent);
            if (t) return t;
          }
        } catch (_) {}
      }
      const parentLabel = el.closest('label');
      if (parentLabel) {
        const t = cleanText(parentLabel.innerText || parentLabel.textContent);
        if (t) return t;
      }
      const placeholder = el.getAttribute('placeholder');
      if (placeholder) return cleanText(placeholder);
    }

    if (role === 'heading' || role === 'button' || role === 'link' || role === 'tab' || role === 'menuitem' || role === 'option') {
      if (el.children.length === 0) {
        return cleanText(el.innerText || el.textContent);
      }
      const altImg = el.querySelector('img[alt]');
      const txt = cleanText(el.innerText || el.textContent);
      if (altImg && altImg.getAttribute('alt')) {
        const alt = cleanText(altImg.getAttribute('alt'));
        return cleanText(alt + (txt ? ' ' + txt : ''));
      }
      if (txt && txt.length <= 80) return txt;
    }

    if (role === 'navigation' || role === 'region' || role === 'dialog' || role === 'form') {
      const title = el.getAttribute('title') || el.getAttribute('name');
      if (title) return cleanText(title);
    }

    const title = el.getAttribute('title');
    if (title) return cleanText(title);

    return '';
  }

  function getHref(el) {
    if (el.tagName.toLowerCase() !== 'a') return undefined;
    const href = el.getAttribute('href');
    if (!href) return undefined;
    try {
      if (href.startsWith('/') && !href.startsWith('//')) return href;
      return new URL(href, window.location.href).href;
    } catch {
      return href;
    }
  }

  function getValue(el) {
    if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement || el instanceof HTMLSelectElement) {
      const type = (el.getAttribute('type') || '').toLowerCase();
      if (type === 'password') return '[password]';
      if (type === 'checkbox' || type === 'radio') return undefined;
      if (el instanceof HTMLSelectElement) {
        const sel = Array.from(el.selectedOptions).map(o => cleanText(o.textContent)).join(', ');
        return sel ? cleanText(sel, 60) : undefined;
      }
      const val = cleanText(el.value, 60);
      return val || undefined;
    }
    return undefined;
  }

  function getClasses(el) {
    const rawClass = typeof el.className === 'string' ? el.className.trim() : (el.getAttribute('class') || '').trim();
    if (!rawClass) return undefined;
    const parts = rawClass.split(/\s+/).filter(Boolean);
    if (parts.length === 0) return undefined;
    return parts.slice(0, 3).join(' ').slice(0, 40);
  }

  function walk(el, depth = 0) {
    if (nodeCount >= MAX_NODES) return null;
    if (++visitedCount >= MAX_TRAVERSAL) {
      hitBudget = true;
      return null;
    }
    if (Date.now() - startTime > TIME_BUDGET_MS) {
      hitBudget = true;
      return null;
    }
    if (!isVisible(el)) return null;
    if (depth > 16) return null;

    const role = getRole(el) || 'generic';
    const interactive = isInteractive(el, role);
    const headingLevel = role === 'heading' ? getHeadingLevel(el) : undefined;
    const name = getAccessibleName(el, role);
    const href = getHref(el);
    const value = getValue(el);
    const domId = el.id ? el.id.trim() : undefined;
    const domClass = (interactive || domId || role !== 'generic') ? getClasses(el) : undefined;

    const isSignificant = interactive || LANDMARK_ROLES.has(role) || headingLevel != null ||
                          role === 'list' || role === 'listitem' || role === 'table' ||
                          role === 'img' || (domId != null && domId.length > 0);
    const ref = isSignificant ? getAgentId(el) : undefined;

    let cursor = false;
    if (interactive) {
      cursor = true;
    } else {
      try {
        if (window.getComputedStyle(el).cursor === 'pointer') cursor = true;
      } catch (_) {}
    }

    const disabled = el.hasAttribute('disabled') || el.getAttribute('aria-disabled') === 'true' ? true : undefined;
    const checked = el.checked === true || el.getAttribute('aria-checked') === 'true' ? true : undefined;
    const selected = el.getAttribute('aria-selected') === 'true' ? true : undefined;
    const expanded = el.getAttribute('aria-expanded') != null ? el.getAttribute('aria-expanded') === 'true' : undefined;
    const required = el.hasAttribute('required') || el.getAttribute('aria-required') === 'true' ? true : undefined;

    const children = [];

    const childNodes = Array.from(el.childNodes);
    for (const ch of childNodes) {
      if (nodeCount >= MAX_NODES) break;

      if (ch.nodeType === Node.TEXT_NODE) {
        const text = cleanText(ch.textContent);
        if (!text) continue;
        if (name && text.toLowerCase() === name.toLowerCase() && el.children.length === 0) {
          continue;
        }
        children.push({ type: 'text', text });
      } else if (ch.nodeType === Node.ELEMENT_NODE) {
        const childNode = walk(ch, depth + 1);
        if (childNode) {
          children.push(childNode);
        }
      }
    }

    // Single-child generic wrapper collapsing
    if (role === 'generic' && !name && !ref && !cursor && !domId && !href) {
      if (children.length === 0) {
        return null;
      }
      if (children.length === 1 && children[0].type !== 'text') {
        return children[0];
      }
    }

    nodeCount++;

    return {
      role,
      name: name || undefined,
      ref,
      cursor: cursor || undefined,
      level: headingLevel,
      domId,
      domClass,
      href,
      value,
      disabled,
      checked,
      selected,
      expanded,
      required,
      children: children.length > 0 ? children : undefined
    };
  }

  function serializeToLines(node, depth = 0) {
    const indent = '  '.repeat(depth);
    const role = node.role || 'generic';
    const parts = [`${indent}- ${role}`];

    if (node.name) {
      parts.push(`"${node.name.replace(/"/g, '\\"')}"`);
    }
    if (node.ref) {
      parts.push(`[ref=${node.ref}]`);
    }
    if (node.level) {
      parts.push(`[level=${node.level}]`);
    }
    if (node.domId) {
      parts.push(`[id="${node.domId}"]`);
    }
    if (node.domClass) {
      parts.push(`[class="${node.domClass}"]`);
    }
    if (node.cursor) {
      parts.push(`[cursor=pointer]`);
    }
    if (node.disabled) {
      parts.push(`[disabled]`);
    }
    if (node.checked) {
      parts.push(`[checked]`);
    }
    if (node.selected) {
      parts.push(`[selected]`);
    }
    if (node.expanded === true) {
      parts.push(`[expanded]`);
    } else if (node.expanded === false) {
      parts.push(`[collapsed]`);
    }
    if (node.required) {
      parts.push(`[required]`);
    }
    if (node.value) {
      parts.push(`[value="${node.value.replace(/"/g, '\\"')}"]`);
    }

    const hasChildren = (node.href != null) || (node.children && node.children.length > 0);
    const line = parts.join(' ') + (hasChildren ? ':' : '');
    const lines = [line];

    if (node.href) {
      lines.push(`${indent}  - /url: ${node.href}`);
    }

    if (node.children) {
      for (const ch of node.children) {
        if (ch.type === 'text') {
          lines.push(`${indent}  - text: ${ch.text}`);
        } else {
          lines.push(...serializeToLines(ch, depth + 1));
        }
      }
    }

    return lines;
  }

  let root = null;
  if (TARGET_REF) {
    root = document.querySelector('[data-agent-id="' + TARGET_REF + '"]');
    if (!root) root = document.getElementById(TARGET_REF);
    if (!root) {
      try { root = document.querySelector(TARGET_REF); } catch (_) {}
    }
  }
  if (!root && TARGET_SEL) {
    try { root = document.querySelector(TARGET_SEL); } catch (_) {}
  }
  const isScoped = !!root;
  if (!root && (TARGET_REF || TARGET_SEL)) {
    return JSON.stringify({ error: 'Target element for scoped snapshot not found (ref: ' + (TARGET_REF || '') + ', selector: ' + (TARGET_SEL || '') + ').' });
  }
  if (!root) root = document.body || document.documentElement;
  const treeRoot = root ? walk(root) : null;
  const lines = treeRoot ? serializeToLines(treeRoot) : [];

  return JSON.stringify({
    meta: {
      url: window.location.href,
      title: document.title,
      scoped: isScoped ? (TARGET_REF ? '[ref=' + TARGET_REF + ']' : TARGET_SEL) : null,
      scroll: {
        x: Math.round(window.scrollX),
        y: Math.round(window.scrollY),
        totalHeight: Math.round(document.documentElement.scrollHeight)
      }
    },
    tree: lines.join('\n'),
    stats: {
      nodeCount,
      visitedCount,
      truncated: nodeCount >= MAX_NODES || hitBudget,
      reason: nodeCount >= MAX_NODES ? 'node_cap' : (hitBudget ? 'traversal_budget' : 'none')
    }
  });
})()
''';
