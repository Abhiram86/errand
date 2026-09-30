/// Shared formatting helpers.
///
/// These were previously duplicated: `_formatBytes` existed byte-identically in
/// three files and `_formatSize` was a fourth variant in file_tools. They now
/// live here so the units and rounding cannot drift apart.
library;

/// Formats a byte count for display: `512 B`, `1.5 KB`, `2.3 MB`.
///
/// ```dart
/// formatBytes(1536); // '1.5 KB'
/// ```
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
