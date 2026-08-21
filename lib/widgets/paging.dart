import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// Which end of a scrollable triggers loading more data.
enum PagingEdge {
  /// Near the top of the list (e.g. older chat messages).
  leading,

  /// Near the bottom of the list (e.g. older conversations).
  trailing,
}

/// Whether a scroll notification is close enough to [edge] to warrant
/// fetching the next page.
///
/// Uses a pixel threshold so loading starts before the user actually hits
/// the edge. Returns false for non-vertical scrolls and for lists too short
/// to scroll (the caller decides whether an initial page even exists).
bool shouldLoadMore(
  ScrollNotification notification,
  PagingEdge edge, {
  double threshold = 400,
}) {
  final metrics = notification.metrics;
  if (metrics.axis != Axis.vertical) return false;
  if (metrics.maxScrollExtent <= 0) return false;
  return switch (edge) {
    PagingEdge.leading => metrics.pixels <= threshold,
    PagingEdge.trailing =>
      metrics.pixels >= metrics.maxScrollExtent - threshold,
  };
}

/// Thin, reusable pagination engine for infinite-scroll surfaces.
///
/// Owns only the paging *state* (in-flight guard, has-more flag, dedupe);
/// the caller keeps owning the item list itself. This keeps it usable for
/// both consumers with different shapes:
///
/// - **Chat messages**: prepended pages, cursor is `sortOrder`, first page
///   comes from `loadConversation(limit:)`.
/// - **Sidebar recents**: appended pages, offset-based, first page comes
///   from a live Drift watch and must be deduped against loaded pages.
class PagedFetcher<T> {
  PagedFetcher({
    required this.fetchPage,
    required this.keyOf,
    this.pageSize = 20,
  });

  /// Fetches one page. [offset] counts items already shown by the UI; a
  /// caller with a natural cursor (e.g. `beforeSortOrder`) may ignore it
  /// and use its own.
  final Future<List<T>> Function(int offset, int limit) fetchPage;

  /// Identity used to dedupe items that are already visible (ids).
  final Object Function(T item) keyOf;

  final int pageSize;

  bool _loading = false;

  /// True while [loadMore] is in flight; use it to show a spinner and to
  /// avoid double-firing from rapid scroll events.
  bool get loading => _loading;

  /// Flips to false once a page comes back short — there is nothing left
  /// to load. Callers may also set it directly.
  bool hasMore = true;

  /// Fetches the next page and returns only the items whose keys are not
  /// in [existingKeys]. Returns an empty list when already loading or when
  /// [hasMore] is false.
  Future<List<T>> loadMore(Set<Object> existingKeys) async {
    if (_loading || !hasMore) return const [];
    _loading = true;
    try {
      final page = await fetchPage(offset, pageSize);
      _consumed += page.length;
      if (page.length < pageSize) hasMore = false;
      final known = {...existingKeys};
      return [
        for (final item in page)
          if (known.add(keyOf(item))) item,
      ];
    } finally {
      _loading = false;
    }
  }

  /// Advisory offset handed to [fetchPage]; the number of items previous
  /// calls have consumed. Callers with their own cursor can ignore it.
  int get offset => _consumed;
  int _consumed = 0;
}

/// Spinner row shown at the edge being paginated.
class LoadMoreIndicator extends StatelessWidget {
  final String? label;

  const LoadMoreIndicator({super.key, this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            if (label != null) ...[
              const SizedBox(width: 10),
              Text(
                label!,
                style: const TextStyle(color: kMuted, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
