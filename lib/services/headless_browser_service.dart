import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'browser_service.dart';

/// Function signature for creating [HeadlessInAppWebView] instances.
/// Allows injecting mock or test implementations without requiring native platform views.
typedef HeadlessWebViewCreator = HeadlessInAppWebView Function({
  required Size initialSize,
  required InAppWebViewSettings initialSettings,
  void Function(InAppWebViewController controller)? onWebViewCreated,
  void Function(InAppWebViewController controller, WebUri? url)? onLoadStart,
  void Function(InAppWebViewController controller, WebUri? url)? onLoadStop,
  void Function(InAppWebViewController controller, WebResourceRequest request, WebResourceError error)? onReceivedError,
  void Function(InAppWebViewController controller, WebResourceRequest request, WebResourceResponse errorResponse)? onReceivedHttpError,
  void Function(InAppWebViewController controller, int progress)? onProgressChanged,
  void Function(InAppWebViewController controller, String? title)? onTitleChanged,
});

/// A headless variant of [BrowserService] that operates completely offscreen using
/// [HeadlessInAppWebView].
///
/// Designed for autonomous background scheduler runs, keeping full 1-to-1 feature parity
/// (`open`, `close`, `reload`, `snapshot`, `extract_text`, `execute_dom_js`, `act`, `screenshot`)
/// without mounting widgets into the Flutter chat widget tree or displaying dock bars / popups.
class HeadlessBrowserService extends BrowserService {
  HeadlessInAppWebView? _headlessWebView;
  final Size initialSize;
  final HeadlessWebViewCreator? webViewCreator;

  HeadlessBrowserService({
    super.controllerOverride,
    this.initialSize = const Size(1280, 800),
    this.webViewCreator,
  }) {
    setDisplayMode(BrowserDisplayMode.fullScreen);
  }

  /// Whether the offscreen headless web view has been instantiated.
  bool get hasHeadlessView => _headlessWebView != null;

  @override
  Future<BrowserPageInfo> open(
    String url, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (controllerOverride == null && _headlessWebView == null) {
      _initHeadlessView();
      await _headlessWebView!.run();
    }
    return super.open(url, timeout: timeout);
  }

  void _initHeadlessView() {
    final settings = InAppWebViewSettings(
      isInspectable: kDebugMode,
      javaScriptEnabled: true,
      domStorageEnabled: true,
      databaseEnabled: true,
      supportZoom: true,
      useWideViewPort: true,
      loadWithOverviewMode: true,
      mediaPlaybackRequiresUserGesture: false,
      transparentBackground: true,
      useHybridComposition: true,
      mixedContentMode: MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
      allowContentAccess: false,
      allowFileAccess: false,
      cacheEnabled: true,
      safeBrowsingEnabled: true,
      userAgent: currentUserAgent,
    );

    final creator = webViewCreator;
    if (creator != null) {
      _headlessWebView = creator(
        initialSize: initialSize,
        initialSettings: settings,
        onWebViewCreated: (controller) => attachInAppController(controller),
        onLoadStart: (controller, url) => onLoadStart(url?.toString() ?? ''),
        onLoadStop: (controller, url) => onLoadStop(url?.toString() ?? ''),
        onReceivedError: (controller, request, error) {
          final isMainFrame = request.isForMainFrame ??
              (request.url.toString() == currentUrl ||
                  request.url.toString() == targetLoadingUrl);
          if (!isMainFrame) return;
          onLoadError(request.url.toString(), error.description);
        },
        onReceivedHttpError: (controller, request, errorResponse) {
          final isMainFrame = request.isForMainFrame ??
              (request.url.toString() == currentUrl ||
                  request.url.toString() == targetLoadingUrl);
          if (!isMainFrame) return;
          onLoadError(
            request.url.toString(),
            'HTTP ${errorResponse.statusCode}',
          );
        },
        onProgressChanged: (controller, progress) => onProgressChanged(progress),
        onTitleChanged: (controller, title) => onTitleChanged(title ?? ''),
      );
    } else {
      _headlessWebView = HeadlessInAppWebView(
        initialSize: initialSize,
        initialSettings: settings,
        onWebViewCreated: (controller) => attachInAppController(controller),
        onLoadStart: (controller, url) => onLoadStart(url?.toString() ?? ''),
        onLoadStop: (controller, url) => onLoadStop(url?.toString() ?? ''),
        onReceivedError: (controller, request, error) {
          final isMainFrame = request.isForMainFrame ??
              (request.url.toString() == currentUrl ||
                  request.url.toString() == targetLoadingUrl);
          if (!isMainFrame) return;
          onLoadError(request.url.toString(), error.description);
        },
        onReceivedHttpError: (controller, request, errorResponse) {
          final isMainFrame = request.isForMainFrame ??
              (request.url.toString() == currentUrl ||
                  request.url.toString() == targetLoadingUrl);
          if (!isMainFrame) return;
          onLoadError(
            request.url.toString(),
            'HTTP ${errorResponse.statusCode}',
          );
        },
        onProgressChanged: (controller, progress) => onProgressChanged(progress),
        onTitleChanged: (controller, title) => onTitleChanged(title ?? ''),
      );
    }
  }

  @override
  Future<void> close({bool clear = false}) async {
    await super.close(clear: clear);
    if (clear) {
      await disposeHeadlessView();
    }
  }

  /// Explicitly terminates and disposes the native offscreen web view.
  Future<void> disposeHeadlessView() async {
    if (_headlessWebView != null) {
      try {
        await _headlessWebView!.dispose();
      } catch (_) {}
      _headlessWebView = null;
    }
    setController(null);
  }

  @override
  void dispose() {
    unawaited(disposeHeadlessView());
    super.dispose();
  }
}
