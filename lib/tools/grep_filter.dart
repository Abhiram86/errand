/// Utility for filtering tool text outputs by regex or case-insensitive substring.
/// Supports plain substrings as well as regular expression syntax.
class GrepFilter {
  /// Compiles [pattern] into a case-insensitive [RegExp].
  /// If [pattern] contains invalid regex syntax, falls back safely to
  /// an escaped literal match so user/model queries never crash.
  static RegExp compile(String pattern, {bool caseSensitive = false}) {
    try {
      return RegExp(pattern, caseSensitive: caseSensitive, multiLine: true);
    } catch (_) {
      return RegExp(RegExp.escape(pattern), caseSensitive: caseSensitive);
    }
  }

  /// Filters [text] lines using [pattern].
  ///
  /// - [header]: Optional header string to always preserve at the top (e.g. file info).
  /// - [withLineNumbers]: If true, prefixes matching lines with `Line <N>: `.
  /// - Returns `[No lines matched grep: "$pattern"]` if no lines match.
  static String filter(
    String text,
    String pattern, {
    String? header,
    bool withLineNumbers = false,
  }) {
    final trimmedPattern = pattern.trim();
    if (trimmedPattern.isEmpty) return text;

    final regex = compile(trimmedPattern);
    final lines = text.split('\n');
    final matches = <String>[];

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (regex.hasMatch(line)) {
        if (withLineNumbers) {
          matches.add('Line ${i + 1}: $line');
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
    }

    return buffer.toString();
  }
}
