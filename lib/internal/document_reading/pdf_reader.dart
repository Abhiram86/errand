import 'dart:collection';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/services.dart';

import 'document_models.dart';

const _kDefaultChannel = MethodChannel('pdf_reader');
const _maxPdfBytes = 64 * 1024 * 1024;
const _maxPageCharacters = 256 * 1024;

/// Historical Finalizer token type, removed along with the [Finalizer] itself.
///
/// A Dart `Finalizer` callback runs on a non-root-isolate finalizer thread with
/// no `BinaryMessenger` binding, so `invokeMethod` was a no-op or threw and the
/// native `PDDocument` (a memory-mapped file handle, up to 64MB) leaked for the
/// process lifetime. Cleanup is now deterministic instead of GC-dependent:
/// `dispose()` is the only path that closes a document, the native plugin caps
/// its open set with bounded eviction, and `closeAll()` runs on engine teardown.


/// Reads a PDF document using native PdfBox via platform channel on Android,
/// or using pure-Dart stream text extraction on desktop / non-Android platforms.
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

  try {
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
  } on MissingPluginException {
    // Platform channel missing (e.g. desktop runner without native PdfBox handler)
    return _readPdfDesktopFallback(file, length);
  } catch (e) {
    if (!Platform.isAndroid) {
      return _readPdfDesktopFallback(file, length);
    }
    rethrow;
  }
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
      // The only path that actually closes the native handle. Deterministic,
      // not GC-dependent — see [_PdfFinalizerToken].
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

Future<LogicalDocument> _readPdfDesktopFallback(File file, int fileBytes) async {
  try {
    final bytes = await file.readAsBytes();
    final units = _extractSimplePdfUnits(bytes);
    if (units.isNotEmpty) {
      return LogicalDocument(
        format: 'PDF',
        units: units,
        totalExpandedBytes: fileBytes,
      );
    }
  } catch (e) {
    developer.log(
      'Fallback PDF text extraction failed for "${file.path}"',
      error: e,
      name: 'readPdfDocument',
    );
  }

  throw FormatException(
    'Native PDF reading via PdfBox is only supported on Android. '
    'On ${Platform.operatingSystem}, pure-Dart text extraction found no readable text '
    '(file may contain scanned images, graphics, or unsupported encodings).',
  );
}

List<LogicalDocumentUnit> _extractSimplePdfUnits(Uint8List bytes) {
  final rawString = latin1.decode(bytes);
  final streamRegex = RegExp(r'stream[\r\n]+([\s\S]*?)[\r\n]+endstream');
  final matches = streamRegex.allMatches(rawString);
  final units = <LogicalDocumentUnit>[];

  var pageNum = 1;
  for (final match in matches) {
    final streamStart = match.start +
        rawString.substring(match.start, match.end).indexOf('stream') +
        6;
    var actualStart = streamStart;
    if (actualStart < bytes.length && bytes[actualStart] == 13) actualStart++;
    if (actualStart < bytes.length && bytes[actualStart] == 10) actualStart++;

    final endStreamPos = match.end - 9;
    var actualEnd = endStreamPos;
    while (actualEnd > actualStart &&
        (bytes[actualEnd - 1] == 13 || bytes[actualEnd - 1] == 10)) {
      actualEnd--;
    }
    if (actualEnd <= actualStart) continue;

    final streamData = bytes.sublist(actualStart, actualEnd);
    final dictStart = match.start > 300 ? match.start - 300 : 0;
    final dictBefore = rawString.substring(dictStart, match.start);
    final isFlate = dictBefore.contains('/FlateDecode');

    List<int>? uncompressed;
    if (isFlate) {
      try {
        uncompressed = zlib.decode(streamData);
      } catch (_) {
        try {
          uncompressed = ZLibCodec(raw: true).decode(streamData);
        } catch (_) {}
      }
    } else {
      uncompressed = streamData;
    }

    if (uncompressed != null) {
      final streamStr = latin1.decode(uncompressed);
      final sb = StringBuffer();
      _extractTextFromStreamString(streamStr, sb);
      final text = sb.toString().trim();
      if (text.isNotEmpty) {
        units.add(LogicalDocumentUnit(
          label: 'Page $pageNum',
          text: text,
        ));
        pageNum++;
      }
    }
  }

  return units;
}

void _extractTextFromStreamString(String content, StringBuffer out) {
  final btEtRegex = RegExp(r'BT([\s\S]*?)ET');
  for (final block in btEtRegex.allMatches(content)) {
    final blockText = block.group(1) ?? '';
    final tjRegex = RegExp(r'\((.*?)\)\s*Tj');
    for (final m in tjRegex.allMatches(blockText)) {
      final t = m.group(1);
      if (t != null && t.isNotEmpty) {
        out.write(_unescapePdfString(t));
        out.write(' ');
      }
    }
    final tjArrayRegex = RegExp(r'\[(.*?)\]\s*TJ');
    for (final m in tjArrayRegex.allMatches(blockText)) {
      final inner = m.group(1) ?? '';
      final strInArray = RegExp(r'\((.*?)\)');
      for (final sm in strInArray.allMatches(inner)) {
        final t = sm.group(1);
        if (t != null && t.isNotEmpty) {
          out.write(_unescapePdfString(t));
        }
      }
      out.write(' ');
    }
    final hexRegex = RegExp(r'<([0-9a-fA-F\s]+)>\s*Tj');
    for (final m in hexRegex.allMatches(blockText)) {
      final hex = (m.group(1) ?? '').replaceAll(RegExp(r'\s'), '');
      final chars = <int>[];
      for (var i = 0; i < hex.length - 1; i += 2) {
        final byte = int.tryParse(hex.substring(i, i + 2), radix: 16);
        if (byte != null && byte >= 32 && byte <= 126) {
          chars.add(byte);
        }
      }
      if (chars.isNotEmpty) {
        out.write(String.fromCharCodes(chars));
        out.write(' ');
      }
    }
    out.writeln();
  }
}

String _unescapePdfString(String s) {
  return s
      .replaceAll(r'\(', '(')
      .replaceAll(r'\)', ')')
      .replaceAll(r'\\', r'\')
      .replaceAll(r'\n', '\n')
      .replaceAll(r'\r', '\r')
      .replaceAll(r'\t', '\t');
}