import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:html2md/html2md.dart' as html2md;

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
  bool _isExpanded = false;
  String? _currentUrl;
  String? _currentTitle;
  int _progress = 0;
  bool _isLoading = false;
  bool _canGoBack = false;
  bool _canGoForward = false;
  String? _targetLoadingUrl;
  String? _lastError;

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
  bool get isExpanded => _isExpanded;
  String? get currentUrl => _currentUrl;
  String? get currentTitle => _currentTitle;
  int get progress => _progress;
  bool get isLoading => _isLoading;
  bool get canGoBack => _canGoBack;
  bool get canGoForward => _canGoForward;
  bool get hasController => _controller != null;
  String? get lastError => _lastError;
  String? get targetLoadingUrl => _targetLoadingUrl;
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
    _lastError = null;
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
    if (_currentUrl != null &&
        _currentUrl != 'about:blank' &&
        _lastError != null &&
        _lastError!.startsWith('HTTP ')) {
      _lastError = null;
    }
    if (_loadCompleter != null && !_loadCompleter!.isCompleted) {
      _loadCompleter!.complete();
    }
    _targetLoadingUrl = null;
    unawaited(_updateNavState());
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

  // -- UI Visibility Toggles ------------------------------------------------

  void toggleExpand() {
    _isExpanded = !_isExpanded;
    notifyListeners();
  }

  void setExpanded(bool expanded) {
    if (_isExpanded != expanded) {
      _isExpanded = expanded;
      notifyListeners();
    }
  }

  void expand() => setExpanded(true);
  void collapse() => setExpanded(false);

  // -- Browser Actions ------------------------------------------------------

  /// Opens the browser with the given [url] and waits for the page to load.
  Future<BrowserPageInfo> open(
    String url, {
    Duration timeout = const Duration(seconds: 15),
    bool expand = true,
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

    _isOpen = true;
    if (expand) {
      _isExpanded = true;
    }
    _currentUrl = targetUrl;
    _targetLoadingUrl = targetUrl;
    _lastError = null;
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

    _isLoading = true;
    _progress = 10;
    _loadCompleter = Completer<void>();
    notifyListeners();

    if (_controllerOverride != null) {
      await _controller!.loadUrl(targetUrl);
    } else {
      try {
        await _controller!.loadUrl(targetUrl);
        await _loadCompleter!.future.timeout(timeout);
      } catch (_) {
        // Timeout is non-fatal: proceed with whatever content loaded
      }

      // Verify URL reported by controller
      final actualUrl = await _controller!.getUrl();
      if (actualUrl != null &&
          actualUrl != 'about:blank' &&
          actualUrl.isNotEmpty) {
        _currentUrl = actualUrl;
      } else if (_currentUrl == 'about:blank' || _currentUrl == null) {
        // If controller still reports about:blank, give it a brief grace period and retry load once
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

      // Brief settle delay for dynamic rendering and client hydration
      await Future.delayed(const Duration(milliseconds: 350));
    }

    _isLoading = false;
    _currentUrl = await _controller!.getUrl() ?? _currentUrl ?? targetUrl;
    _currentTitle = await _controller!.getTitle() ?? _currentTitle;
    await _updateNavState();
    notifyListeners();

    final hasLoadedPage =
        _currentUrl != null &&
        _currentUrl != 'about:blank' &&
        (_currentTitle?.trim().isNotEmpty ?? false);

    return BrowserPageInfo(
      url: _currentUrl ?? targetUrl,
      title: _currentTitle ?? '',
      status: hasLoadedPage
          ? 'loaded'
          : (_lastError != null ? 'error: $_lastError' : 'unknown'),
    );
  }

  /// Closes the browser sheet and optionally resets the page.
  Future<void> close({bool clear = false}) async {
    _isOpen = false;
    _isExpanded = false;
    if (clear && _controller != null) {
      try {
        await _controller!.loadUrl('about:blank');
        _currentUrl = null;
        _currentTitle = null;
      } catch (_) {}
    }
    notifyListeners();
  }

  /// Reloads the currently active page.
  Future<BrowserPageInfo> reload({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    _ensureOpenAndReady();

    _isLoading = true;
    _progress = 10;
    _loadCompleter = Completer<void>();
    notifyListeners();

    if (_controllerOverride != null) {
      await _controller!.reload();
    } else {
      try {
        await _controller!.reload();
        await _loadCompleter!.future.timeout(timeout);
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 300));
    }
    _isLoading = false;
    _currentUrl = await _controller!.getUrl() ?? _currentUrl;
    _currentTitle = await _controller!.getTitle() ?? _currentTitle;
    await _updateNavState();
    notifyListeners();

    return BrowserPageInfo(
      url: _currentUrl ?? '',
      title: _currentTitle ?? '',
      status: 'reloaded',
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
  /// When [fullDump] is true, returns the pure DOM HTML dump.
  Future<String> snapshot({int maxNodes = 200, bool fullDump = false}) async {
    _ensureOpenAndReady();

    if (fullDump) {
      const dumpScript = r'''
(() => {
  return document.documentElement ? document.documentElement.outerHTML : '';
})()
''';
      final raw = await _controller!.evaluateJavascript(dumpScript);
      if (raw == null || raw.toString().trim().isEmpty) {
        return 'Pure DOM dump returned empty.';
      }
      return raw.toString().trim();
    }

    final script = r'''
(() => {
  const MAX_NODES = __MAX_NODES__;
  let nextId = 1;
  let nodeCount = 0;

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

  const root = document.body || document.documentElement;
  const treeRoot = root ? walk(root) : null;
  const lines = treeRoot ? serializeToLines(treeRoot) : [];

  return JSON.stringify({
    meta: {
      url: window.location.href,
      title: document.title,
      scroll: {
        x: Math.round(window.scrollX),
        y: Math.round(window.scrollY),
        totalHeight: Math.round(document.documentElement.scrollHeight)
      }
    },
    tree: lines.join('\n'),
    stats: {
      nodeCount,
      truncated: nodeCount >= MAX_NODES
    }
  });
})()
'''.replaceFirst('__MAX_NODES__', '$maxNodes');

    final raw = await _controller!.evaluateJavascript(script);

    if (raw == null) {
      return 'Snapshot failed: no response from browser DOM.';
    }

    try {
      final decoded = jsonDecode(raw.toString()) as Map<String, dynamic>;

      final meta = decoded['meta'] as Map<String, dynamic>? ?? {};
      final stats = decoded['stats'] as Map<String, dynamic>? ?? {};

      final buffer = StringBuffer();

      buffer.writeln('Page Title: ${meta['title'] ?? ''}');
      buffer.writeln('URL: ${meta['url'] ?? ''}');

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
        buffer.writeln('[Snapshot truncated at $maxNodes nodes]');
      }

      return buffer.toString().trim();
    } catch (e) {
      return 'Snapshot parsing error: $e\nRaw: $raw';
    }
}

  /// Extracts clean Markdown text from the current page using html2md.
  /// If [selector] is provided, extracts text only from the matching container element.
  Future<String> extractText({String? selector}) async {
    _ensureOpenAndReady();

    final targetSel = selector?.trim();
    final script = '''
(() => {
  try {
    let target = null;
    ${targetSel != null && targetSel.isNotEmpty ? 'target = document.querySelector(${jsonEncode(targetSel)});' : ''}
    if (!target) target = document.body || document.documentElement;
    if (!target) return '';
    const clone = target.cloneNode(true);
    const toRemove = clone.querySelectorAll('script, style, noscript, svg, iframe, object, embed, applet');
    toRemove.forEach(el => el.remove());
    return clone.innerHTML || '';
  } catch (e) {
    return document.body ? document.body.innerHTML : '';
  }
})()
''';

    final raw = await _controller!.evaluateJavascript(script);
    if (raw == null || raw.toString().trim().isEmpty) {
      return 'Page returned empty content.';
    }

    final html = raw.toString();
    final markdown = html2md.convert(
      html,
      styleOptions: {'headingStyle': 'atx'},
    );
    if (markdown.trim().isEmpty) {
      return 'No readable text could be extracted from the page.';
    }
    return markdown.trim();
  }

  /// Evaluates arbitrary JavaScript in the page DOM and returns the result.
  Future<String> executeDomJs(String script) async {
    _ensureOpenAndReady();

    final trimmed = script.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('JavaScript script cannot be empty.');
    }

    final wrapped = '''
(() => {
  try {
    const val = (function() { $trimmed })();
    if (val === undefined) return JSON.stringify({ ok: true, result: null, type: 'undefined' });
    if (typeof val === 'object') return JSON.stringify({ ok: true, result: val, type: 'object' });
    return JSON.stringify({ ok: true, result: val, type: typeof val });
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
        if (res == null) return 'Result: null';
        if (res is String) return 'Result: "$res"';
        return 'Result: ${jsonEncode(res)}';
      }
      return 'Result: $raw';
    } catch (_) {
      return 'Result: $raw';
    }
  }

  /// Performs a high-level action (click, type, or scroll) on the page.
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
      case 'scroll':
        return await _actScroll(direction: direction ?? 'down');
      case 'back':
        await goBack();
        return 'Navigated back.';
      case 'forward':
        await goForward();
        return 'Navigated forward.';
      default:
        throw ArgumentError('Unknown act action "$action". Supported: click, type, scroll, back, forward.');
    }
  }

  Future<String> _actClick({String? ref, String? selector}) async {
    final targetRef = ref?.trim();
    final targetSel = selector?.trim();
    if ((targetRef == null || targetRef.isEmpty) && (targetSel == null || targetSel.isEmpty)) {
      throw ArgumentError('Either ref or selector is required to click an element.');
    }

    final script = '''
(() => {
  let el = null;
  ${targetRef != null && targetRef.isNotEmpty ? '''
  el = document.querySelector('[data-agent-id="$targetRef"]');
  if (!el) el = document.getElementById(${jsonEncode(targetRef)});
  if (!el) {
    try { el = document.querySelector(${jsonEncode(targetRef)}); } catch (_) {}
  }
  ''' : ''}
  if (!el && ${targetSel != null && targetSel.isNotEmpty ? 'true' : 'false'}) {
    el = document.querySelector(${jsonEncode(targetSel)});
  }
  if (!el) return JSON.stringify({ ok: false, error: 'Element not found' });
  try {
    el.scrollIntoView({ behavior: 'instant', block: 'center' });
    if (typeof el.focus === 'function') el.focus();

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
    return JSON.stringify({
      ok: true,
      tag: el.tagName.toLowerCase(),
      text: (el.innerText || el.textContent || '').trim().slice(0, 50)
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
        return 'Clicked $targetStr <$tag>${text.isNotEmpty ? ' "$text"' : ''}.';
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
  let el = null;
  ${targetRef != null && targetRef.isNotEmpty ? '''
  el = document.querySelector('[data-agent-id="$targetRef"]');
  if (!el) el = document.getElementById(${jsonEncode(targetRef)});
  if (!el) {
    try { el = document.querySelector(${jsonEncode(targetRef)}); } catch (_) {}
  }
  ''' : ''}
  if (!el && ${targetSel != null && targetSel.isNotEmpty ? 'true' : 'false'}) {
    el = document.querySelector(${jsonEncode(targetSel)});
  }
  if (!el) return JSON.stringify({ ok: false, error: 'Element not found' });
  try {
    el.scrollIntoView({ behavior: 'instant', block: 'center' });
    if (typeof el.focus === 'function') el.focus();

    const val = ${jsonEncode(text)};

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

    return JSON.stringify({ ok: true, tag: el.tagName.toLowerCase() });
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
        return 'Typed "$text" into $targetStr <$tag>.';
      } else {
        return 'Type failed: ${decoded['error']}.';
      }
    } catch (_) {
      return 'Typed text.';
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
