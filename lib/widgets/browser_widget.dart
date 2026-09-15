import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../services/browser_service.dart';
import '../theme/app_colors.dart';

/// Embedded dark-themed browser widget that can expand to an interactive bottom
/// sheet or collapse to a sleek floating mini-bar while keeping the underlying
/// WebView state and DOM alive across turns.
class BrowserWidget extends StatefulWidget {
  final BrowserService? service;

  const BrowserWidget({super.key, this.service});

  @override
  State<BrowserWidget> createState() => _BrowserWidgetState();
}

class _BrowserWidgetState extends State<BrowserWidget> {
  BrowserService get _service => widget.service ?? BrowserService.instance;

  bool _hasEverOpened = false;

  bool get _canRenderNativeWebView {
    if (kIsWeb) return false;
    if (_service.controllerOverride != null) return false;
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

        final size = MediaQuery.sizeOf(context);
        final sheetHeight = size.height * 0.72;

        return Stack(
          fit: StackFit.expand,
          children: [
            // Dark scrim behind expanded sheet
            if (_service.isOpen && _service.isExpanded)
              Positioned.fill(
                child: GestureDetector(
                  onTap: () => _service.collapse(),
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 200),
                    opacity: _service.isExpanded ? 1.0 : 0.0,
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.52),
                    ),
                  ),
                ),
              ),

            // Collapsed mini bar floating right above the composer
            if (_service.isOpen && !_service.isExpanded)
              Positioned(
                left: 12,
                right: 12,
                bottom: 76,
                child: _buildCollapsedBar(context),
              ),

            // Expanded interactive sheet (kept in tree so WebView controller stays alive)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: sheetHeight,
              child: AnimatedSlide(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
                offset: (_service.isOpen && _service.isExpanded)
                    ? Offset.zero
                    : const Offset(0, 1.2),
                child: Offstage(
                  offstage: !_service.isOpen,
                  child: _buildExpandedSheet(context),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Compact mini dock shown when the browser is open but collapsed.
  Widget _buildCollapsedBar(BuildContext context) {
    final title = _service.currentTitle?.trim();
    final url = _service.currentUrl?.trim();
    final displayText = (title != null && title.isNotEmpty)
        ? title
        : ((url != null && url.isNotEmpty) ? url : 'Browser');

    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF181D26),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kBorder),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 14,
              offset: const Offset(0, 4),
            ),
          ],
        ),
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
            const SizedBox(width: 10),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _service.expand(),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: kText,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
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
                        ),
                      ),
                  ],
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.refresh_rounded, size: 18),
              onPressed: () => _service.reload(),
              color: kMuted,
              visualDensity: VisualDensity.compact,
              tooltip: 'Reload page',
            ),
            IconButton(
              icon: const Icon(Icons.open_in_full_rounded, size: 16),
              onPressed: () => _service.expand(),
              color: kText,
              visualDensity: VisualDensity.compact,
              tooltip: 'Expand browser',
            ),
            IconButton(
              key: const ValueKey('browser_collapsed_close_button'),
              icon: const Icon(Icons.close_rounded, size: 18),
              onPressed: () => _service.close(),
              color: kMuted,
              visualDensity: VisualDensity.compact,
              tooltip: 'Close mini browser',
            ),
          ],
        ),
      ),
    );
  }

  /// Full interactive sheet with navigation header, progress bar, and WebView.
  Widget _buildExpandedSheet(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF13171F),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        border: Border(
          top: BorderSide(color: kBorder.withValues(alpha: 0.9)),
          left: BorderSide(color: kBorder.withValues(alpha: 0.9)),
          right: BorderSide(color: kBorder.withValues(alpha: 0.9)),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.65),
            blurRadius: 24,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Column(
        children: [
          // Drag handle
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: (details) {
              if (details.primaryDelta != null && details.primaryDelta! > 6) {
                _service.collapse();
              }
            },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.only(top: 8, bottom: 6),
              alignment: Alignment.center,
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: kMuted.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),

          // Navigation bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 17),
                  onPressed: _service.canGoBack ? () => _service.goBack() : null,
                  color: _service.canGoBack ? kText : kMuted.withValues(alpha: 0.35),
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Go back',
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_forward_ios_rounded, size: 17),
                  onPressed:
                      _service.canGoForward ? () => _service.goForward() : null,
                  color:
                      _service.canGoForward ? kText : kMuted.withValues(alpha: 0.35),
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Go forward',
                ),
                IconButton(
                  icon: Icon(
                    _service.isLoading
                        ? Icons.close_rounded
                        : Icons.refresh_rounded,
                    size: 19,
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
                    height: 36,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: kInputBg,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: kBorder),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _service.currentUrl?.startsWith('https') == true
                              ? Icons.lock_outline_rounded
                              : Icons.public_rounded,
                          size: 14,
                          color: kMuted,
                        ),
                        const SizedBox(width: 8),
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
                  icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 24),
                  onPressed: () => _service.collapse(),
                  color: kText,
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Collapse sheet',
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, size: 20),
                  onPressed: () => _service.close(),
                  color: kMuted,
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Close browser',
                ),
              ],
            ),
          ),

          // Progress indicator bar
          SizedBox(
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
          ),

          // WebView viewport
          Expanded(
            child: ColoredBox(
              color: Colors.white,
              child: Stack(
                children: [
                  _buildWebView(),
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
          mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
          allowContentAccess: true,
          allowFileAccess: true,
          cacheEnabled: true,
          safeBrowsingEnabled: false,
        ),
        onWebViewCreated: (controller) {
          _service.attachInAppController(controller);
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
