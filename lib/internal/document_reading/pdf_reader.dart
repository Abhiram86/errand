import 'dart:developer' as developer;
import 'dart:io';

import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'document_models.dart';

const _maxPdfBytes = 64 * 1024 * 1024;

Future<LogicalDocument> readPdfDocument(File file) async {
  final length = await file.length();
  if (length > _maxPdfBytes) {
    throw FormatException(
      'PDF is too large to inspect safely '
      '(maximum $_maxPdfBytes bytes, got $length).',
    );
  }
  final bytes = await file.readAsBytes();
  return PooledPdfDocument(bytes);
}

class PooledPdfDocument extends LogicalDocument {
  static final _finalizer = Finalizer<PdfDocument>((doc) {
    try {
      doc.dispose();
    } catch (_) {}
  });

  final PdfDocument _doc;
  final PdfTextExtractor _extractor;
  final int _pageCount;
  bool _isDisposed = false;

  PooledPdfDocument._(this._doc, this._extractor, this._pageCount)
      : super(format: 'PDF', units: const []);

  factory PooledPdfDocument(List<int> bytes) {
    PdfDocument doc;
    try {
      doc = PdfDocument(inputBytes: bytes);
    } catch (e) {
      throw FormatException('Failed to parse PDF: $e');
    }
    final instance = PooledPdfDocument._(
      doc,
      PdfTextExtractor(doc),
      doc.pages.count,
    );
    _finalizer.attach(instance, doc, detach: instance);
    return instance;
  }

  @override
  LogicalRead read({required int offset, required int length}) {
    if (_isDisposed) {
      throw StateError('Cannot read from a disposed PDF document.');
    }

    if (_pageCount == 0) {
      return const LogicalRead(
        format: 'PDF',
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
    if (offset >= _pageCount) {
      throw RangeError(
        'Logical offset $offset is beyond the end of the document '
        '(unit count: $_pageCount).',
      );
    }

    final maxCharacters = length.clamp(1, 256 * 1024);
    final selected = <LogicalDocumentUnit>[];
    var characters = 0;
    var end = offset;

    while (end < _pageCount) {
      String text;
      try {
        text = _extractor
            .extractText(startPageIndex: end, endPageIndex: end)
            .trim();
      } catch (e, stackTrace) {
        developer.log(
          'Failed to extract text from page ${end + 1}',
          error: e,
          stackTrace: stackTrace,
          name: 'PooledPdfDocument',
        );
        text = '';
      }

      final label = 'Page ${end + 1}';
      final unitSize = text.length + label.length + 2;

      // Handle massive single pages exceeding maxCharacters alone
      if (selected.isEmpty && unitSize > maxCharacters) {
        final allowedLen = (maxCharacters - label.length - 17).clamp(0, text.length);
        selected.add(LogicalDocumentUnit(
          label: label,
          text: '${text.substring(0, allowedLen)}... [truncated]',
        ));
        end++;
        break;
      }

      if (selected.isNotEmpty && characters + unitSize > maxCharacters) {
        break;
      }

      selected.add(LogicalDocumentUnit(label: label, text: text));
      characters += unitSize;
      end++;
    }

    final hasMore = end < _pageCount;
    // Overlaps the last unit by 1 so the LLM retains boundary context
    final nextOffset = hasMore && end - offset > 1 ? end - 1 : end;
    final body = selected
        .map((u) => '${u.label}\n${u.text}'.trim())
        .join('\n\n');

    return LogicalRead(
      format: 'PDF',
      start: offset,
      end: end,
      total: _pageCount,
      hasMore: hasMore,
      nextOffset: nextOffset,
      output: body.isEmpty ? 'No readable text was found.' : body,
    );
  }

  void dispose() {
    if (!_isDisposed) {
      _isDisposed = true;
      _finalizer.detach(this);
      _doc.dispose();
    }
  }
}