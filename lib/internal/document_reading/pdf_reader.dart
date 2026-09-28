import 'dart:collection';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/services.dart';

import 'document_models.dart';

const _kDefaultChannel = MethodChannel('pdf_reader');
const _maxPdfBytes = 64 * 1024 * 1024;
const _maxPageCharacters = 256 * 1024;

/// Reads a PDF document using native PdfBox via platform channel.
///
/// Keeps the native `PDDocument` alive on Android and fetches pages
/// on-demand, caching up to 32 pages (8MB) in Dart memory.
Future<LogicalDocument> readPdfDocument(
  File file, {
  MethodChannel? channel,
}) async {
  final length = await file.length();
  if (length > _maxPdfBytes) {
    throw FormatException(
      'PDF is too large to inspect safely '
      '(maximum $_maxPdfBytes bytes, got $length).',
    );
  }

  final effectiveChannel = channel ?? _kDefaultChannel;
  final result = await effectiveChannel.invokeMapMethod<String, dynamic>(
    'openPdf',
    {'path': file.path},
  );

  if (result == null) {
    throw const FormatException('Failed to open PDF document.');
  }

  final docId = result['docId'] as String;
  final pageCount = (result['pageCount'] as num).toInt();

  return PooledPdfDocument(
    docId: docId,
    pageCount: pageCount,
    channel: effectiveChannel,
    fileBytes: length,
  );
}

class PooledPdfDocument extends LogicalDocument {
  final String docId;
  final int pageCount;
  final MethodChannel channel;
  bool _isDisposed = false;

  final Map<int, LogicalDocumentUnit> _cache = {};
  int _cacheBytes = 0;
  static const int _maxCacheBytes = 8 * 1024 * 1024; // 8MB per PDF
  static const int _maxCacheEntries = 32;

  PooledPdfDocument({
    required this.docId,
    required this.pageCount,
    required this.channel,
    int? fileBytes,
  }) : super(
          format: 'PDF',
          units: _PlaceholderPdfUnitList(pageCount),
          totalExpandedBytes: fileBytes,
        );

  @override
  int get unitCount => pageCount;

  @override
  Future<LogicalDocumentUnit> getUnit(int index) async {
    if (_isDisposed) {
      throw StateError('Cannot read from a disposed PDF document.');
    }
    if (index < 0 || index >= pageCount) {
      throw RangeError.range(index, 0, pageCount - 1, 'index');
    }

    final cached = _cache[index];
    if (cached != null) {
      // True LRU: update recency on hit
      _cache.remove(index);
      _cache[index] = cached;
      return cached;
    }

    String text;
    try {
      final rawText = await channel.invokeMethod<String>('extractPage', {
        'docId': docId,
        'pageIndex': index,
      });
      text = rawText?.trim() ?? '';
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

    if (unitBytes <= _maxCacheBytes) {
      _cache[index] = unit;
      _cacheBytes += unitBytes;
    }

    return unit;
  }

  @override
  Future<LogicalRead> read({required int offset, required int length}) {
    if (_isDisposed) {
      throw StateError('Cannot read from a disposed PDF document.');
    }
    return super.read(offset: offset, length: length);
  }

  @override
  void dispose() {
    if (!_isDisposed) {
      _isDisposed = true;
      _cache.clear();
      _cacheBytes = 0;
      channel.invokeMethod('closePdf', {'docId': docId}).catchError((_) {});
    }
  }
}

class _PlaceholderPdfUnitList extends ListBase<LogicalDocumentUnit> {
  final int pageCount;

  _PlaceholderPdfUnitList(this.pageCount);

  @override
  int get length => pageCount;

  @override
  set length(int newLength) =>
      throw UnsupportedError('Cannot modify length of read-only PDF unit list.');

  @override
  LogicalDocumentUnit operator [](int index) {
    RangeError.checkValidIndex(index, this, 'index', pageCount);
    return LogicalDocumentUnit(
      label: 'Page ${index + 1}',
      text: '',
    );
  }

  @override
  void operator []=(int index, LogicalDocumentUnit value) =>
      throw UnsupportedError('Cannot modify read-only PDF unit list.');
}