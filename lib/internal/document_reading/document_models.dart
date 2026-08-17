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

  const LogicalDocument({required this.format, required this.units});

  LogicalRead read({required int offset, required int length}) {
    if (units.isEmpty) {
      return LogicalRead(
        format: format,
        start: 0,
        end: 0,
        total: 0,
        hasMore: false,
        output: 'No readable text was found.',
      );
    }

    if (offset >= units.length) {
      throw RangeError(
        'Logical offset $offset is beyond the end of the document '
        '(unit count: ${units.length}).',
      );
    }

    final maxCharacters = length.clamp(1, 256 * 1024);
    final selected = <LogicalDocumentUnit>[];
    var characters = 0;
    var end = offset;

    while (end < units.length) {
      final unit = units[end];
      final unitSize = unit.text.length + unit.label.length + 2;

      if (selected.isNotEmpty && characters + unitSize > maxCharacters) {
        break;
      }

      selected.add(unit);
      characters += unitSize;
      end++;
    }

    final hasMore = end < units.length;
    final nextOffset = hasMore && end - offset > 1 ? end - 1 : end;

    final body = selected
        .map((unit) => '${unit.label}\n${unit.text}'.trim())
        .join('\n\n');

    return LogicalRead(
      format: format,
      start: offset,
      end: end,
      total: units.length,
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
