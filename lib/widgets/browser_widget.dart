import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../services/browser_service.dart';
import '../services/intent_service.dart';
import '../theme/app_colors.dart';

/// Spacer widget that reserves height in [ChatScreen]'s message column
/// above the composer when the browser is docked in [BrowserDisplayMode.closed]
/// or [BrowserDisplayMode.preview] mode.
class BrowserDockSpacer extends StatelessWidget {
  final BrowserService? service;
  final bool? isComposerFocused;

  const BrowserDockSpacer({super.key, this.service, this.isComposerFocused});

  @override
  Widget build(BuildContext context) {
    final browser = service ?? BrowserService.instance;
    return ListenableBuilder(
      listenable: browser,
      builder: (context, _) {
        double targetHeight = 0.0;
        final composerFocused = isComposerFocused ?? false;

        if (browser.isOpen) {
          final isCompact = browser.displayMode == BrowserDisplayMode.closed ||
              (browser.displayMode == BrowserDisplayMode.preview && composerFocused);
          if (isCompact) {
            targetHeight = 54.0;
          } else if (browser.displayMode == BrowserDisplayMode.preview) {
            final screenHeight = MediaQuery.sizeOf(context).height;
            final previewHeight = (screenHeight * 0.42).clamp(280.0, 420.0);
            targetHeight = previewHeight + 6;
          }
        }
        return AnimatedContainer(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeInOutCubicEmphasized,
          height: targetHeight,
        );
      },
    );
  }
}

/// Embedded dark-themed browser widget supporting 3 user-controlled display modes:
/// 1. `closed`: slim dock bar sitting directly above the composer ("Browser full closed").
/// 2. `preview`: live preview card sitting directly above the composer ("Browser preview").
/// 3. `fullScreen`: full-screen overlay covering the entire viewport ("Browser full screen").
///
/// WebView state and DOM controller are kept alive seamlessly across all transitions.
class BrowserWidget extends StatefulWidget {
  final BrowserService? service;
  final GlobalKey? composerKey;
  final bool? isComposerFocused;
  final VoidCallback? onUnfocusComposer;

  const BrowserWidget({
    super.key,
    this.service,
    this.composerKey,
    this.isComposerFocused,
    this.onUnfocusComposer,
  });

  @override
  State<BrowserWidget> createState() => _BrowserWidgetState();
}

class _BrowserWidgetState extends State<BrowserWidget> {
  BrowserService get _service => widget.service ?? BrowserService.instance;
  final GlobalKey _webViewKey = GlobalKey();

  bool _hasEverOpened = false;

  void _unfocusComposerIfNeeded() {
    if (widget.isComposerFocused == true) {
      widget.onUnfocusComposer?.call();
      FocusScope.of(context).unfocus();
    }
  }

  bool get _canRenderNativeWebView {
    if (kIsWeb) return false;
    if (_service.controllerOverride != null) return false;
    if (InAppWebViewPlatform.instance == null) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _service,
      builder: (context, _) {
        if (_service.isOpen) {
          _hasEverOpened = true;
        }

        // If never opened and not open now, do not mount anything
        if (!_hasEverOpened && !_service.isOpen) {
          return const SizedBox.shrink();
        }

        final isOpen = _service.isOpen;
        final mode = _service.displayMode;
        final isFullScreen = mode == BrowserDisplayMode.fullScreen;
        final isClosed = mode == BrowserDisplayMode.closed;

        final isComposerFocused = widget.isComposerFocused ?? false;
        final isCompact = isClosed || (mode == BrowserDisplayMode.preview && isComposerFocused);

        final size = MediaQuery.sizeOf(context);
        final previewHeight = (size.height * 0.42).clamp(280.0, 420.0);

        double composerH = 68.0;
        if (widget.composerKey?.currentContext?.findRenderObject() is RenderBox) {
          final box = widget.composerKey!.currentContext!.findRenderObject() as RenderBox;
          if (box.hasSize && box.size.height > 0) {
            composerH = box.size.height;
          }
        }
        final bottomOffset = MediaQuery.paddingOf(context).bottom +
            composerH +
            4.0;

        final double targetHeight = isFullScreen
            ? size.height
            : (isCompact ? 50.0 : previewHeight);
        final double targetLeft = isFullScreen ? 0.0 : 10.0;
        final double targetRight = isFullScreen ? 0.0 : 10.0;
        final double targetBottom = isFullScreen ? 0.0 : bottomOffset;
        final double targetRadius = isFullScreen ? 0.0 : (isCompact ? 12.0 : 14.0);

        return Stack(
          fit: StackFit.expand,
          children: [
            if (isOpen)
              AnimatedPositioned(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeInOutCubicEmphasized,
                left: targetLeft,
                right: targetRight,
                bottom: targetBottom,
                height: targetHeight,
                child: Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: (_) => _unfocusComposerIfNeeded(),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 280),
                    curve: Curves.easeInOutCubicEmphasized,
                    decoration: BoxDecoration(
                      color: isFullScreen
                          ? const Color(0xFF13171F)
                          : (isClosed ? const Color(0xFF181D26) : const Color(0xFF13171F)),
                      borderRadius: BorderRadius.circular(targetRadius),
                      border: isFullScreen ? null : Border.all(color: kBorder),
                      boxShadow: isFullScreen
                          ? null
                          : [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: isClosed ? 0.45 : 0.6),
                                blurRadius: isClosed ? 12 : 16,
                                offset: Offset(0, isClosed ? 3 : 4),
                              ),
                            ],
                    ),
                    clipBehavior: isFullScreen ? Clip.none : Clip.antiAlias,
                    child: isCompact
                        ? _buildClosedDockBar(context)
                        : _buildActiveBrowser(
                            context,
                            isFullScreen: isFullScreen,
                            contentHeight: isFullScreen ? size.height : (previewHeight - 2.0),
                          ),
                  ),
                ),
              ),

            // When closed or compact, keep the WebView alive offstage so DOM & agent actions work
            if (!isOpen || isCompact)
              Positioned(
                width: 1,
                height: 1,
                bottom: 0,
                child: Offstage(
                  offstage: true,
                  child: _buildPersistentWebView(),
                ),
              ),
          ],
        );
      },
    );
  }

  /// Compact slim dock bar shown when browser is in [BrowserDisplayMode.closed] mode.
  Widget _buildClosedDockBar(BuildContext context) {
    final title = _service.currentTitle?.trim();
    final url = _service.currentUrl?.trim();
    final displayText = (title != null && title.isNotEmpty)
        ? title
        : ((url != null && url.isNotEmpty) ? url : 'Browser full closed');

    return Material(
      color: Colors.transparent,
      child: OverflowBox(
        alignment: Alignment.topCenter,
        minHeight: 48.0,
        maxHeight: 48.0,
        child: SizedBox(
          height: 48.0,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Row(
              children: [
                if (_service.isLoading)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: kBubbleUser,
                    ),
                  )
                else
                  const Icon(
                    Icons.public_rounded,
                    size: 18,
                    color: kBubbleUser,
                  ),
                const SizedBox(width: 8),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      _unfocusComposerIfNeeded();
                      _service.setPreview();
                    },
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          displayText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: kText,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            height: 1.2,
                          ),
                        ),
                        if (url != null && title != null && title.isNotEmpty)
                          Text(
                            url,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: kMuted,
                              fontSize: 11,
                              fontFamily: 'monospace',
                              height: 1.1,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  key: const ValueKey('browser_reload_button'),
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  onPressed: () => _service.reload(),
                  color: kMuted,
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Reload page',
                ),
                IconButton(
                  key: const ValueKey('browser_preview_button'),
                  icon: const Icon(Icons.picture_in_picture_alt_rounded, size: 17),
                  onPressed: () {
                    _unfocusComposerIfNeeded();
                    _service.setPreview();
                  },
                  color: kText,
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Open preview',
                ),
                IconButton(
                  key: const ValueKey('browser_fullscreen_button'),
                  icon: const Icon(Icons.open_in_full_rounded, size: 16),
                  onPressed: () {
                    _unfocusComposerIfNeeded();
                    _service.setFullScreen();
                  },
                  color: kText,
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Open full screen',
                ),
                IconButton(
                  key: const ValueKey('browser_collapsed_close_button'),
                  icon: const Icon(Icons.close_rounded, size: 18),
                  onPressed: () => _service.close(),
                  color: kMuted,
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Close browser',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Interactive browser container used for both [preview] card and [fullScreen] overlay.
  Widget _buildActiveBrowser(
    BuildContext context, {
    required bool isFullScreen,
    required double contentHeight,
  }) {
    return Material(
      color: Colors.transparent,
      child: OverflowBox(
        alignment: Alignment.topCenter,
        minHeight: contentHeight,
        maxHeight: contentHeight,
        child: SizedBox(
          height: contentHeight,
          child: Column(
            children: [
              _buildToolbar(context, isFullScreen: isFullScreen),
              _buildProgressBar(),
              Expanded(
                child: ColoredBox(
                  color: Colors.white,
                  child: Stack(
                    children: [
                      _buildPersistentWebView(),
                      if (_service.isLoading)
                        Positioned.fill(
                          child: Container(
                            color: const Color(0xFF13171F).withValues(alpha: 0.85),
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const SizedBox(
                                    width: 28,
                                    height: 28,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.5,
                                      color: kBubbleUser,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    _service.currentUrl ?? 'Loading...',
                                    style: const TextStyle(
                                      color: kMuted,
                                      fontSize: 12,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Top navigation toolbar with URL bar and display mode action buttons.
  Widget _buildToolbar(BuildContext context, {required bool isFullScreen}) {
    final toolbarContent = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 16),
            onPressed: _service.canGoBack ? () => _service.goBack() : null,
            color: _service.canGoBack ? kText : kMuted.withValues(alpha: 0.35),
            visualDensity: VisualDensity.compact,
            tooltip: 'Go back',
          ),
          IconButton(
            icon: const Icon(Icons.arrow_forward_ios_rounded, size: 16),
            onPressed: _service.canGoForward ? () => _service.goForward() : null,
            color: _service.canGoForward ? kText : kMuted.withValues(alpha: 0.35),
            visualDensity: VisualDensity.compact,
            tooltip: 'Go forward',
          ),
          IconButton(
            key: const ValueKey('browser_reload_button'),
            icon: Icon(
              _service.isLoading ? Icons.close_rounded : Icons.refresh_rounded,
              size: 18,
            ),
            onPressed: () {
              if (_service.isLoading) {
                _service.stopLoading();
              } else {
                _service.reload();
              }
            },
            color: kText,
            visualDensity: VisualDensity.compact,
            tooltip: _service.isLoading ? 'Stop' : 'Reload',
          ),
          const SizedBox(width: 4),
          // Address bar
          Expanded(
            child: Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: kInputBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: kBorder),
              ),
              child: Row(
                children: [
                  Icon(
                    _service.currentUrl?.startsWith('https') == true
                        ? Icons.lock_outline_rounded
                        : Icons.public_rounded,
                    size: 13,
                    color: kMuted,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _service.currentUrl ?? 'about:blank',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: kText,
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            key: const ValueKey('browser_open_external_button'),
            icon: const Icon(Icons.open_in_browser_rounded, size: 18),
            onPressed: () {
              final url = _service.currentUrl;
              if (url != null && url.isNotEmpty && url != 'about:blank') {
                IntentService().launchAction('open_url', data: url);
              }
            },
            color: kMuted,
            visualDensity: VisualDensity.compact,
            tooltip: 'Open in external browser',
          ),
          if (isFullScreen) ...[
            IconButton(
              key: const ValueKey('browser_restore_button'),
              icon: const Icon(Icons.close_fullscreen_rounded, size: 18),
              onPressed: () => _service.setPreview(),
              color: kText,
              visualDensity: VisualDensity.compact,
              tooltip: 'Exit full screen',
            ),
            IconButton(
              key: const ValueKey('browser_minimize_button'),
              icon: const Icon(Icons.unfold_less_rounded, size: 18),
              onPressed: () => _service.setClosed(),
              color: kMuted,
              visualDensity: VisualDensity.compact,
              tooltip: 'Minimize to dock',
            ),
          ] else ...[
            IconButton(
              key: const ValueKey('browser_fullscreen_button'),
              icon: const Icon(Icons.open_in_full_rounded, size: 16),
              onPressed: () => _service.setFullScreen(),
              color: kText,
              visualDensity: VisualDensity.compact,
              tooltip: 'Open full screen',
            ),
            IconButton(
              key: const ValueKey('browser_minimize_button'),
              icon: const Icon(Icons.unfold_less_rounded, size: 18),
              onPressed: () => _service.setClosed(),
              color: kText,
              visualDensity: VisualDensity.compact,
              tooltip: 'Minimize to dock',
            ),
          ],
          IconButton(
            key: const ValueKey('browser_close_button'),
            icon: const Icon(Icons.close_rounded, size: 18),
            onPressed: () => _service.close(),
            color: kMuted,
            visualDensity: VisualDensity.compact,
            tooltip: 'Close browser',
          ),
        ],
      ),
    );

    if (isFullScreen) {
      return SafeArea(
        bottom: false,
        child: toolbarContent,
      );
    }
    return toolbarContent;
  }

  /// Slim progress line indicator shown during page loads.
  Widget _buildProgressBar() {
    return SizedBox(
      height: 2,
      child: _service.isLoading
          ? LinearProgressIndicator(
              value: _service.progress > 0 && _service.progress < 100
                  ? _service.progress / 100.0
                  : null,
              minHeight: 2,
              backgroundColor: Colors.transparent,
              color: kBubbleUser,
            )
          : const SizedBox.shrink(),
    );
  }

  Widget _buildPersistentWebView() {
    return KeyedSubtree(
      key: _webViewKey,
      child: _buildWebView(),
    );
  }

  /// Builds the real [InAppWebView] on mobile platforms or a clean placeholder
  /// during tests / headless execution.
  Widget _buildWebView() {
    if (_canRenderNativeWebView) {
      final initialUrl = _service.currentUrl;
      final hasInitialUrl = initialUrl != null &&
          initialUrl.isNotEmpty &&
          initialUrl != 'about:blank';

      return InAppWebView(
        initialUrlRequest:
            hasInitialUrl ? URLRequest(url: WebUri(initialUrl)) : null,
        initialSettings: InAppWebViewSettings(
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
          supportMultipleWindows: true,
          javaScriptCanOpenWindowsAutomatically: true,
          userAgent: _service.currentUserAgent,
        ),
        onWebViewCreated: (controller) async {
          _service.attachInAppController(controller);
          try {
            final defaultUa = await InAppWebViewController.getDefaultUserAgent();
            if (defaultUa.isNotEmpty) {
              final sanitized = BrowserService.sanitizeUserAgent(defaultUa);
              _service.setCurrentUserAgent(sanitized);
              if (sanitized != BrowserService.defaultCleanUserAgent) {
                await controller.setSettings(
                  settings: InAppWebViewSettings(userAgent: sanitized),
                );
              }
            }
          } catch (_) {}
        },
        onCreateWindow: (controller, createWindowAction) async {
          final windowId = createWindowAction.windowId;
          if (!mounted) return false;

          await showDialog<void>(
            context: context,
            barrierDismissible: true,
            builder: (dialogContext) => OAuthPopupDialog(
              windowId: windowId,
              initialUrlRequest: createWindowAction.request,
            ),
          );
          return true;
        },
        onLoadStart: (controller, url) {
          _service.onLoadStart(url?.toString() ?? '');
        },
        onLoadStop: (controller, url) {
          _service.onLoadStop(url?.toString() ?? '');
        },
        onReceivedError: (controller, request, error) {
          final isMainFrame = request.isForMainFrame ??
              (request.url.toString() == _service.currentUrl ||
                  request.url.toString() == _service.targetLoadingUrl);
          if (!isMainFrame) return;
          _service.onLoadError(request.url.toString(), error.description);
        },
        onReceivedHttpError: (controller, request, errorResponse) {
          final isMainFrame = request.isForMainFrame ??
              (request.url.toString() == _service.currentUrl ||
                  request.url.toString() == _service.targetLoadingUrl);
          if (!isMainFrame) return;
          _service.onLoadError(
            request.url.toString(),
            'HTTP ${errorResponse.statusCode}',
          );
        },
        onProgressChanged: (controller, progress) {
          _service.onProgressChanged(progress);
        },
        onTitleChanged: (controller, title) {
          _service.onTitleChanged(title ?? '');
        },
      );
    }

    return Container(
      key: const ValueKey('browser_test_placeholder'),
      color: const Color(0xFF0D1016),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.web_asset_rounded,
            size: 48,
            color: kMuted.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 12),
          Text(
            _service.currentTitle?.isNotEmpty == true
                ? _service.currentTitle!
                : (_service.currentUrl ?? 'Embedded Browser'),
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: kText,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (_service.currentUrl != null) ...[
            const SizedBox(height: 6),
            Text(
              _service.currentUrl!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: kMuted,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ],
          if (_service.isLoading) ...[
            const SizedBox(height: 16),
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: kBubbleUser,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// In-app popup dialog hosted in a sleek modal card for OAuth authentication,
/// Google/GitHub sign-in popups, and multi-window child pages (`window.open`).
class OAuthPopupDialog extends StatefulWidget {
  final int windowId;
  final URLRequest? initialUrlRequest;

  const OAuthPopupDialog({
    super.key,
    required this.windowId,
    this.initialUrlRequest,
  });

  @override
  State<OAuthPopupDialog> createState() => _OAuthPopupDialogState();
}

class _OAuthPopupDialogState extends State<OAuthPopupDialog> {
  String _title = 'Authentication';
  String? _currentUrl;
  bool _isLoading = false;
  int _progress = 0;

  bool get _canRenderNativeWebView {
    if (kIsWeb) return false;
    if (InAppWebViewPlatform.instance == null) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.sizeOf(context);
    final dialogWidth = (mediaQuery.width * 0.94).clamp(320.0, 560.0);
    final dialogHeight = (mediaQuery.height * 0.85).clamp(440.0, 750.0);

    return Dialog(
      backgroundColor: kDarkBg,
      insetPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 20),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: kBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: Column(
          children: [
            Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              color: kInputBg,
              child: Row(
                children: [
                  const Icon(Icons.security_rounded, size: 18, color: kBubbleUser),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: kText,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (_currentUrl != null &&
                      _currentUrl!.isNotEmpty &&
                      _currentUrl != 'about:blank')
                    IconButton(
                      icon: const Icon(Icons.open_in_browser_rounded, size: 18),
                      color: kMuted,
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Open in external browser',
                      onPressed: () {
                        IntentService().launchAction('open_url', data: _currentUrl);
                      },
                    ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 18),
                    color: kMuted,
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            if (_isLoading && _progress > 0 && _progress < 100)
              SizedBox(
                height: 2,
                child: LinearProgressIndicator(
                  value: _progress / 100.0,
                  backgroundColor: Colors.transparent,
                  color: kBubbleUser,
                ),
              ),
            Expanded(
              child: ColoredBox(
                color: Colors.white,
                child: _canRenderNativeWebView
                    ? InAppWebView(
                        windowId: widget.windowId,
                        initialUrlRequest: widget.initialUrlRequest,
                        initialSettings: InAppWebViewSettings(
                          isInspectable: kDebugMode,
                          javaScriptEnabled: true,
                          domStorageEnabled: true,
                          databaseEnabled: true,
                          supportMultipleWindows: true,
                          javaScriptCanOpenWindowsAutomatically: true,
                          useHybridComposition: true,
                          userAgent: BrowserService.defaultCleanUserAgent,
                          mixedContentMode:
                              MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
                          allowContentAccess: false,
                          allowFileAccess: false,
                          cacheEnabled: true,
                          safeBrowsingEnabled: true,
                        ),
                        onCloseWindow: (controller) {
                          if (mounted) {
                            Navigator.of(context).pop();
                          }
                        },
                        onTitleChanged: (controller, title) {
                          if (mounted && title != null && title.isNotEmpty) {
                            setState(() => _title = title);
                          }
                        },
                        onLoadStart: (controller, url) {
                          if (mounted) {
                            setState(() {
                              _isLoading = true;
                              _currentUrl = url?.toString();
                            });
                          }
                        },
                        onLoadStop: (controller, url) {
                          if (mounted) {
                            setState(() {
                              _isLoading = false;
                              _currentUrl = url?.toString();
                            });
                          }
                        },
                        onProgressChanged: (controller, progress) {
                          if (mounted) {
                            setState(() => _progress = progress);
                          }
                        },
                      )
                    : Container(
                        key: const ValueKey('oauth_popup_test_placeholder'),
                        color: const Color(0xFF0D1016),
                        alignment: Alignment.center,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.security_rounded,
                              size: 40,
                              color: kBubbleUser,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              _title,
                              style: const TextStyle(
                                color: kText,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
