import 'dart:async';

/// A logical unit of a document: a PDF page, a presentation slide, a group
/// of Word paragraphs, or a spreadsheet row group.
class LogicalDocumentUnit {
  final String label;
  final String text;

  const LogicalDocumentUnit({required this.label, required this.text});
}

/// A document represented as units rather than raw file bytes.
class LogicalDocument {
  final String format;
  final List<LogicalDocumentUnit> units;
  final int? totalExpandedBytes;

  const LogicalDocument({
    required this.format,
    required this.units,
    this.totalExpandedBytes,
  });

  /// Approximate memory footprint in bytes.
  int get estimatedByteSize {
    if (totalExpandedBytes != null && totalExpandedBytes! > 0) {
      return totalExpandedBytes!;
    }
    var total = 0;
    for (final unit in units) {
      total += unit.label.length + unit.text.length;
    }
    return total;
  }

  /// Releases any native or package resources held by this document.
  void dispose() {}

  /// Total number of logical units in this document.
  int get unitCount => units.length;

  /// Retrieves the unit at [index]. Subclasses (such as PDF) can lazily load it.
  FutureOr<LogicalDocumentUnit> getUnit(int index) => units[index];

  Future<LogicalRead> read({required int offset, required int length}) async {
    final count = unitCount;
    if (count == 0) {
      return LogicalRead(
        format: format,
        start: 0,
        end: 0,
        total: 0,
        hasMore: false,
        output: 'No readable text was found.',
      );
    }

    if (offset < 0) {
      throw RangeError('Logical offset cannot be negative.');
    }

    if (offset >= count) {
      throw RangeError(
        'Logical offset $offset is beyond the end of the document '
        '(unit count: $count).',
      );
    }

    final maxCharacters = length.clamp(1, 256 * 1024);
    final selected = <LogicalDocumentUnit>[];
    var characters = 0;
    var end = offset;

    while (end < count) {
      final unit = await getUnit(end);
      final unitSize = unit.text.length + unit.label.length + 2;

      if (selected.isNotEmpty && characters + unitSize > maxCharacters) {
        break;
      }

      selected.add(unit);
      characters += unitSize;
      end++;
    }

    final hasMore = end < count;
    final nextOffset = hasMore && end - offset > 1 ? end - 1 : end;

    final body = selected
        .map((unit) => '${unit.label}\n${unit.text}'.trim())
        .join('\n\n');

    return LogicalRead(
      format: format,
      start: offset,
      end: end,
      total: count,
      hasMore: hasMore,
      nextOffset: nextOffset,
      output: body.isEmpty ? 'No readable text was found.' : body,
    );
  }
}

class LogicalRead {
  final String format;
  final int start;
  final int end;
  final int total;
  final bool hasMore;
  final int nextOffset;
  final String output;

  const LogicalRead({
    required this.format,
    required this.start,
    required this.end,
    required this.total,
    required this.hasMore,
    this.nextOffset = 0,
    required this.output,
  });

  String toToolOutput(String filePath) {
    final range = total == 0 ? 'none' : '$start–${end - 1}';
    return '''
File: $filePath
Format: $format
Reading logical units $range of $total.
${hasMore ? 'More content available from logical offset $nextOffset.' : 'End of document reached.'}

$output
''';
  }
}
