import 'dart:collection';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'document_models.dart';

const _maxPdfBytes = 64 * 1024 * 1024;
const _maxPageCharacters = 256 * 1024;

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
  bool _isDisposed = false;

  PooledPdfDocument._(
    this._doc,
    List<LogicalDocumentUnit> units,
  ) : super(format: 'PDF', units: units);

  factory PooledPdfDocument(List<int> bytes) {
    PdfDocument doc;
    try {
      doc = PdfDocument(inputBytes: bytes);
    } catch (e) {
      throw FormatException('Failed to parse PDF: $e');
    }
    final extractor = PdfTextExtractor(doc);
    final pageCount = doc.pages.count;

    late final PooledPdfDocument instance;
    final lazyUnits = _LazyPdfUnitList(
      extractor: extractor,
      pageCount: pageCount,
      isDisposed: () => instance._isDisposed,
    );

    instance = PooledPdfDocument._(doc, lazyUnits);
    _finalizer.attach(instance, doc, detach: instance);
    return instance;
  }

  @override
  LogicalRead read({required int offset, required int length}) {
    if (_isDisposed) {
      throw StateError('Cannot read from a disposed PDF document.');
    }
    return super.read(offset: offset, length: length);
  }

  @override
  void dispose() {
    if (!_isDisposed) {
      _isDisposed = true;
      _finalizer.detach(this);
      _doc.dispose();
    }
  }
}

class _LazyPdfUnitList extends ListBase<LogicalDocumentUnit> {
  final PdfTextExtractor extractor;
  final int pageCount;
  final bool Function() isDisposed;
  static const int _maxCacheBytes = 8 * 1024 * 1024; // 8MB per PDF
  static const int _maxCacheEntries = 32;
  int _cacheBytes = 0;
  final Map<int, LogicalDocumentUnit> _cache = {};

  _LazyPdfUnitList({
    required this.extractor,
    required this.pageCount,
    required this.isDisposed,
  });

  @override
  int get length => pageCount;

  @override
  set length(int newLength) =>
      throw UnsupportedError('Cannot modify length of read-only PDF unit list.');

  @override
  LogicalDocumentUnit operator [](int index) {
    if (isDisposed()) {
      throw StateError('Cannot read from a disposed PDF document.');
    }
    RangeError.checkValidIndex(index, this, 'index', pageCount);

    final cached = _cache[index];
    if (cached != null) {
      // True LRU: update recency on hit
      _cache.remove(index);
      _cache[index] = cached;
      return cached;
    }

    String text;
    try {
      text = extractor
          .extractText(startPageIndex: index, endPageIndex: index)
          .trim();
    } catch (e, stackTrace) {
      developer.log(
        'Failed to extract text from page ${index + 1}',
        error: e,
        stackTrace: stackTrace,
        name: 'PooledPdfDocument',
      );
      text = '';
    }

    final label = 'Page ${index + 1}';
    String displayText;
    if (text.isEmpty) {
      displayText =
          '[No text found on this page; may contain scanned images or graphics.]';
    } else if (text.length > _maxPageCharacters) {
      displayText =
          '${text.substring(0, _maxPageCharacters - 17)}... [truncated]';
    } else {
      displayText = text;
    }

    final unit = LogicalDocumentUnit(label: label, text: displayText);
    final unitBytes = (unit.text.length + unit.label.length) * 2;

    while (_cache.isNotEmpty &&
        (_cache.length >= _maxCacheEntries ||
            _cacheBytes + unitBytes > _maxCacheBytes)) {
      final oldestKey = _cache.keys.first;
      final evicted = _cache.remove(oldestKey);
      if (evicted != null) {
        _cacheBytes -= (evicted.text.length + evicted.label.length) * 2;
      }
    }

    // Oversized single pages bypass the cache rather than evicting it.
    if (unitBytes > _maxCacheBytes) return unit;

    _cache[index] = unit;
    _cacheBytes += unitBytes;

    return unit;
  }

  @override
  void operator []=(int index, LogicalDocumentUnit value) =>
      throw UnsupportedError('Cannot modify read-only PDF unit list.');
}