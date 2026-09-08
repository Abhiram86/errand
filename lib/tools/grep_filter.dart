/// Utility for filtering tool text outputs by regex or case-insensitive substring.
/// Supports plain substrings as well as regular expression syntax.
class GrepFilter {
  static const int kMaxPatternLength = 200;
  static const int kMaxMatches = 200;

  /// Compiles [pattern] into a case-insensitive [RegExp].
  /// If [pattern] contains invalid regex syntax, falls back safely to
  /// an escaped literal match so user/model queries never crash.
  /// Overlong patterns fall back to literal to avoid ReDoS on the UI isolate.
  static RegExp compile(String pattern, {bool caseSensitive = false}) {
    var effective = pattern;
    if (effective.length > kMaxPatternLength) {
      return RegExp(RegExp.escape(effective),
          caseSensitive: caseSensitive, multiLine: true);
    }
    // Cheap ReDoS guard: nested quantifiers like (a+)+ are the classic
    // catastrophic-backtracking shape. Fall back to literal for those.
    if (RegExp(r'\([^)]*[+*][^)]*\)[+*]').hasMatch(effective)) {
      return RegExp(RegExp.escape(effective),
          caseSensitive: caseSensitive, multiLine: true);
    }
    try {
      return RegExp(pattern, caseSensitive: caseSensitive, multiLine: true);
    } catch (_) {
      return RegExp(RegExp.escape(pattern),
          caseSensitive: caseSensitive, multiLine: true);
    }
  }

  /// Filters [text] lines using [pattern].
  ///
  /// - [header]: Optional header string to always preserve at the top (e.g. file info).
  /// - [withLineNumbers]: If true, prefixes matching lines with `Line <N>: `.
  /// - [startLine]: 1-based number of the first line in [text] within the
  ///   original source (for windowed reads with offset>0). Defaults to 1.
  /// - Returns `[No lines matched grep: "$pattern"]` if no lines match.
  static String filter(
    String text,
    String pattern, {
    String? header,
    bool withLineNumbers = false,
    int startLine = 1,
  }) {
    final trimmedPattern = pattern.trim();
    if (trimmedPattern.isEmpty) return text;

    final regex = compile(trimmedPattern);
    final lines = text.split('\n');
    final matches = <String>[];
    var truncated = false;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (regex.hasMatch(line)) {
        if (matches.length >= kMaxMatches) {
          truncated = true;
          break;
        }
        if (withLineNumbers) {
          matches.add('Line ${startLine + i}: $line');
        } else {
          matches.add(line);
        }
      }
    }

    final buffer = StringBuffer();
    if (header != null && header.isNotEmpty) {
      buffer.writeln(header);
    }

    if (matches.isEmpty) {
      buffer.write('[No lines matched grep: "$trimmedPattern"]');
    } else {
      buffer.write(matches.join('\n'));
      if (truncated) {
        buffer.write('\n[... more than $kMaxMatches matches; refine grep or paginate ...]');
      }
    }

    return buffer.toString();
  }
}
