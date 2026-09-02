import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml_events.dart';

import 'document_models.dart';

const _maxPackageBytes = 64 * 1024 * 1024;
const _maxPackageEntries = 2000;
const _maxXmlPartBytes = 16 * 1024 * 1024;

// ---------------------------------------------------------------------------
// DOCX Streaming Reader
// ---------------------------------------------------------------------------
Future<LogicalDocument> readDocxDocument(File file) async {
  final package = await _StreamingOpenXmlPackage.load(file);
  final units = <LogicalDocumentUnit>[];

  // 1. Stream body text paragraph by paragraph
  final docStream = package.openPartStream('word/document.xml');
  if (docStream != null) {
    var inParagraph = false;
    var inTable = false;
    var currentParagraph = StringBuffer();
    var currentTableRows = <String>[];
    var currentCell = StringBuffer();
    var currentRowCells = <String>[];

    await docStream
        .transform(utf8.decoder)
        .transform(XmlEventDecoder())
        .forEach((events) {
      for (final event in events) {
        if (event is XmlStartElementEvent) {
          if (event.localName == 'tbl') {
            inTable = true;
          } else if (event.localName == 'p') {
            inParagraph = true;
            currentParagraph.clear();
          } else if (event.localName == 'tab') {
            (inTable ? currentCell : currentParagraph).write('\t');
          } else if (event.localName == 'br' || event.localName == 'cr') {
            (inTable ? currentCell : currentParagraph).write('\n');
          }
        } else if (event is XmlTextEvent) {
          final text = event.value;
          if (text.isNotEmpty) {
            (inTable ? currentCell : currentParagraph).write(text);
          }
        } else if (event is XmlEndElementEvent) {
          if (event.localName == 'p' && inParagraph) {
            inParagraph = false;
            final text = _cleanText(currentParagraph.toString());
            if (text.isNotEmpty && !inTable) {
              units.add(LogicalDocumentUnit(
                label: 'Paragraph ${units.length + 1}',
                text: text,
              ));
            }
          } else if (event.localName == 'tc') {
            final text = _cleanText(currentCell.toString());
            if (text.isNotEmpty) currentRowCells.add(text);
            currentCell.clear();
          } else if (event.localName == 'tr') {
            if (currentRowCells.isNotEmpty) {
              currentTableRows.add(currentRowCells.join(' | '));
              currentRowCells.clear();
            }
          } else if (event.localName == 'tbl') {
            inTable = false;
            if (currentTableRows.isNotEmpty) {
              units.add(LogicalDocumentUnit(
                label: 'Table ${units.length + 1}',
                text: currentTableRows.join('\n'),
              ));
              currentTableRows.clear();
            }
          }
        }
      }
    });
  }

  // 2. Stream headers/footers
  final headerFooterEntries = package.entryNames
      .where((name) => RegExp(r'^word/(header|footer)\d+\.xml$').hasMatch(name))
      .toList()
    ..sort();

  for (final name in headerFooterEntries) {
    final stream = package.openPartStream(name);
    if (stream == null) continue;

    final buffer = StringBuffer();
    await stream
        .transform(utf8.decoder)
        .transform(XmlEventDecoder())
        .forEach((events) {
      for (final event in events) {
        if (event is XmlTextEvent && event.value.isNotEmpty) {
          buffer.write(event.value);
        } else if (event is XmlEndElementEvent && event.localName == 'p') {
          buffer.write('\n');
        }
      }
    });

    final text = _cleanText(buffer.toString());
    if (text.isNotEmpty) {
      units.add(LogicalDocumentUnit(label: _prettyPartName(name), text: text));
    }
  }

  return LogicalDocument(format: 'DOCX', units: units);
}

// ---------------------------------------------------------------------------
// XLSX Streaming Reader
// ---------------------------------------------------------------------------
Future<LogicalDocument> readXlsxDocument(File file) async {
  final package = await _StreamingOpenXmlPackage.load(file);
  final units = <LogicalDocumentUnit>[];

  // Extract shared strings via event stream (no DOM tree)
  final sharedStrings = <String>[];
  final ssStream = package.openPartStream('xl/sharedStrings.xml');
  if (ssStream != null) {
    var inText = false;
    var currentString = StringBuffer();

    await ssStream
        .transform(utf8.decoder)
        .transform(XmlEventDecoder())
        .forEach((events) {
      for (final event in events) {
        if (event is XmlStartElementEvent && event.localName == 't') {
          inText = true;
        } else if (event is XmlTextEvent && inText) {
          currentString.write(event.value);
        } else if (event is XmlEndElementEvent) {
          if (event.localName == 't') {
            inText = false;
          } else if (event.localName == 'si') {
            sharedStrings.add(currentString.toString());
            currentString.clear();
          }
        }
      }
    });
  }

  // Find worksheets — try workbook.xml for real names, fallback to synthetic
  final sheetNames = await _readWorkbookSheetNames(package);
  final sheetEntries = package.entryNames
      .where((n) => RegExp(r'^xl/worksheets/sheet\d+\.xml$').hasMatch(n))
      .toList()
    ..sort((a, b) {
      // numeric sort so sheet10 > sheet2
      final na = int.tryParse(RegExp(r'\d+').firstMatch(a)?.group(0) ?? '0') ?? 0;
      final nb = int.tryParse(RegExp(r'\d+').firstMatch(b)?.group(0) ?? '0') ?? 0;
      return na.compareTo(nb);
    });

  var sheetIndex = 1;
  for (final sheetName in sheetEntries) {
    final stream = package.openPartStream(sheetName);
    if (stream == null) continue;

    final rows = <String>[];
    final currentRowValues = <String>[];
    String currentCellRef = '';
    String currentCellType = '';
    var inValue = false;
    var inInlineText = false;
    var currentValue = StringBuffer();

    await stream
        .transform(utf8.decoder)
        .transform(XmlEventDecoder())
        .forEach((events) {
      for (final event in events) {
        if (event is XmlStartElementEvent) {
          if (event.localName == 'c') {
            currentCellRef = '';
            currentCellType = '';
            for (final attr in event.attributes) {
              if (attr.localName == 'r') currentCellRef = attr.value;
              if (attr.localName == 't') currentCellType = attr.value;
            }
          } else if (event.localName == 'v') {
            inValue = true;
            currentValue.clear();
          } else if (event.localName == 't') {
            inInlineText = true;
            currentValue.clear();
          }
        } else if (event is XmlTextEvent) {
          if (inValue || inInlineText) {
            currentValue.write(event.value);
          }
        } else if (event is XmlEndElementEvent) {
          if (event.localName == 'v' || (event.localName == 't' && inInlineText)) {
            inValue = false;
            inInlineText = false;
            final raw = currentValue.toString().trim();
            String val = raw;
            if (currentCellType == 's') {
              final idx = int.tryParse(raw);
              if (idx != null && idx >= 0 && idx < sharedStrings.length) {
                val = sharedStrings[idx];
              }
            } else if (currentCellType == 'b') {
              val = raw == '1' ? 'TRUE' : 'FALSE';
            }
            if (val.isNotEmpty) {
              currentRowValues.add(currentCellRef.isEmpty ? val : '$currentCellRef=$val');
            }
          } else if (event.localName == 'row') {
            if (currentRowValues.isNotEmpty) {
              rows.add(currentRowValues.join(' | '));
              currentRowValues.clear();
            }
          }
        }
      }
    });

    final labelName = sheetIndex <= sheetNames.length
        ? sheetNames[sheetIndex - 1]
        : 'Sheet $sheetIndex';
    units.addAll(_chunkLines('Sheet: $labelName', rows));
    sheetIndex++;
  }

  return LogicalDocument(format: 'XLSX', units: units);
}

// ---------------------------------------------------------------------------
// PPTX Streaming Reader
// ---------------------------------------------------------------------------
Future<LogicalDocument> readPptxDocument(File file) async {
  final package = await _StreamingOpenXmlPackage.load(file);
  final units = <LogicalDocumentUnit>[];

  final slideEntries = package.entryNames
      .where((n) => RegExp(r'^ppt/slides/slide\d+\.xml$').hasMatch(n))
      .toList()
    ..sort((a, b) {
      final numA = int.tryParse(RegExp(r'\d+').firstMatch(a)?.group(0) ?? '0') ?? 0;
      final numB = int.tryParse(RegExp(r'\d+').firstMatch(b)?.group(0) ?? '0') ?? 0;
      return numA.compareTo(numB);
    });

  for (var index = 0; index < slideEntries.length; index++) {
    final stream = package.openPartStream(slideEntries[index]);
    if (stream == null) continue;

    final paragraphs = <String>[];
    var currentPara = StringBuffer();

    await stream
        .transform(utf8.decoder)
        .transform(XmlEventDecoder())
        .forEach((events) {
      for (final event in events) {
        if (event is XmlStartElementEvent && event.localName == 'p') {
          currentPara.clear();
        } else if (event is XmlTextEvent) {
          currentPara.write(event.value);
        } else if (event is XmlEndElementEvent && event.localName == 'p') {
          final text = _cleanText(currentPara.toString());
          if (text.isNotEmpty) paragraphs.add(text);
          currentPara.clear();
        }
      }
    });

    final text = paragraphs.join('\n');
    units.add(LogicalDocumentUnit(
      label: 'Slide ${index + 1}',
      text: text.isEmpty ? '[No text; slide may contain only images.]' : text,
    ));
  }

  return LogicalDocument(format: 'PPTX', units: units);
}

// ---------------------------------------------------------------------------
// Low-Memory ZIP Container Wrapper
// ---------------------------------------------------------------------------
class _StreamingOpenXmlPackage {
  final Map<String, Uint8List> _parts;

  const _StreamingOpenXmlPackage._(this._parts);

  Iterable<String> get entryNames => _parts.keys;

  /// Streams an uncompressed entry on demand, bounding peak memory usage.
  /// Backed by filtered map — media entries were skipped before decompression.
  Stream<List<int>>? openPartStream(String partName) {
    final normalized = _normalizePart(partName);
    final bytes = _parts[normalized];
    if (bytes == null) return null;
    if (bytes.length > _maxXmlPartBytes) return null;
    return Stream.value(bytes);
  }

  static Future<_StreamingOpenXmlPackage> load(File file) async {
    final compressedSize = await file.length();
    if (compressedSize > _maxPackageBytes) {
      throw FormatException(
        'Office document is too large to inspect safely '
        '(maximum $_maxPackageBytes bytes).',
      );
    }

    final input = InputFileStream(file.path);
    try {
      final archive = ZipDecoder().decodeStream(input);

      if (archive.length > _maxPackageEntries) {
        throw FormatException(
          'Office document contains too many package entries.',
        );
      }

      final parts = <String, Uint8List>{};
      var totalPartBytes = 0;

      for (final entry in archive) {
        if (!entry.isFile) continue;

        final name = _normalizePart(entry.name);
        final lower = name.toLowerCase();
        final isXml = lower.endsWith('.xml');
        final isRels = lower.endsWith('.rels');
        if (!isXml && !isRels) continue; // skip media/fonts before decompression

        final entrySize = entry.size; // uncompressed size from ZIP metadata
        if (isXml && entrySize > _maxXmlPartBytes) continue;

        final maxExpandedBytes = _maxPackageBytes * 4;
        if (entrySize > maxExpandedBytes) {
          throw FormatException(
            'Office document contains an oversized package part.',
          );
        }
        if (totalPartBytes > maxExpandedBytes - entrySize) {
          throw FormatException(
            'Office document expands beyond the safe size limit.',
          );
        }

        final content = entry.readBytes();
        if (content == null) continue;
        if (content.length > maxExpandedBytes - totalPartBytes) {
          throw FormatException(
            'Office document expands beyond the safe size limit.',
          );
        }
        totalPartBytes += content.length;
        parts[name] = content;
      }

      return _StreamingOpenXmlPackage._(parts);
    } on ArchiveException catch (e) {
      throw FormatException(
        'Office document contains an invalid ZIP archive: $e',
      );
    } finally {
      input.close();
    }
  }
}

// ---------------------------------------------------------------------------
// Workbook helpers — sheet names from xl/workbook.xml (preserves real names)
// ---------------------------------------------------------------------------
Future<List<String>> _readWorkbookSheetNames(
    _StreamingOpenXmlPackage package) async {
  final stream = package.openPartStream('xl/workbook.xml');
  if (stream == null) return [];
  final names = <String>[];
  await stream
      .transform(utf8.decoder)
      .transform(XmlEventDecoder())
      .forEach((events) {
    for (final event in events) {
      if (event is XmlStartElementEvent && event.localName == 'sheet') {
        for (final attr in event.attributes) {
          if (attr.localName == 'name') {
            names.add(attr.value);
            break;
          }
        }
      }
    }
  });
  return names;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
List<LogicalDocumentUnit> _chunkLines(String label, List<String> lines) {
  if (lines.isEmpty) return [];
  final units = <LogicalDocumentUnit>[];
  final buffer = <String>[];
  var size = 0;

  void flush() {
    if (buffer.isEmpty) return;
    units.add(LogicalDocumentUnit(
      label: '$label, rows ${units.length + 1}',
      text: buffer.join('\n'),
    ));
    buffer.clear();
    size = 0;
  }

  for (final line in lines) {
    if (buffer.isNotEmpty && size + line.length > 1800) flush();
    buffer.add(line);
    size += line.length + 1;
  }
  flush();
  return units;
}

String _normalizePart(String name) {
  final segments = <String>[];
  for (final segment in name.replaceAll('\\', '/').split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (segments.isNotEmpty) segments.removeLast();
      continue;
    }
    segments.add(segment);
  }
  return segments.join('/');
}

String _prettyPartName(String name) {
  final slash = name.lastIndexOf('/');
  final value = slash == -1 ? name : name.substring(slash);
  return value
      .replaceAll('.xml', '')
      .replaceAll('/', '')
      .replaceAll('_', ' ')
      .trim();
}

String _cleanText(String text) => text
    .replaceAll(RegExp(r'[ \t]+'), ' ')
    .replaceAll(RegExp(r'\n{3,}'), '\n\n')
    .trim();