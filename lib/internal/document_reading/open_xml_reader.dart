import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml_events.dart';

import 'document_models.dart';

const _maxPackageBytes = 64 * 1024 * 1024;
const _maxPackageEntries = 2000;

// ---------------------------------------------------------------------------
// DOCX Streaming Reader
// ---------------------------------------------------------------------------
Future<LogicalDocument> readDocxDocument(File file) async {
  final package = await _StreamingOpenXmlPackage.load(file);
  final units = <LogicalDocumentUnit>[];

  // 1. Stream body text paragraph by paragraph and tables
  final docStream = package.openPartStream('word/document.xml');
  if (docStream != null) {
    var tableDepth = 0;
    var inText = false;
    final currentParagraph = StringBuffer();
    final currentTableRows = <String>[];
    final currentCell = StringBuffer();
    final currentRowCells = <String>[];
    var tableIndex = 1;

    // Buffer for grouping paragraphs into reasonable logical units
    final paraBuffer = <String>[];
    var paraBufferSize = 0;
    var paraStartNumber = 1;
    var totalParaCount = 0;

    void flushParagraphs() {
      if (paraBuffer.isEmpty) return;
      final endNumber = totalParaCount;
      final label = paraBuffer.length == 1
          ? 'Paragraph $paraStartNumber'
          : 'Paragraphs $paraStartNumber–$endNumber';
      units.add(LogicalDocumentUnit(
        label: label,
        text: paraBuffer.join('\n\n'),
      ));
      paraBuffer.clear();
      paraBufferSize = 0;
      paraStartNumber = totalParaCount + 1;
    }

    await docStream
        .transform(utf8.decoder)
        .transform(XmlEventDecoder())
        .forEach((events) {
      for (final event in events) {
        if (event is XmlStartElementEvent) {
          if (event.localName == 'tbl') {
            tableDepth++;
          } else if (event.localName == 'p') {
            if (tableDepth > 0 && currentCell.isNotEmpty) {
              currentCell.write(' ');
            } else {
              currentParagraph.clear();
            }
          } else if (event.localName == 't') {
            inText = true;
          } else if (event.localName == 'tab') {
            (tableDepth > 0 ? currentCell : currentParagraph).write('\t');
          } else if (event.localName == 'br' || event.localName == 'cr') {
            (tableDepth > 0 ? currentCell : currentParagraph).write('\n');
          }
        } else if (event is XmlTextEvent) {
          if (inText) {
            (tableDepth > 0 ? currentCell : currentParagraph).write(event.value);
          }
        } else if (event is XmlEndElementEvent) {
          if (event.localName == 't') {
            inText = false;
          } else if (event.localName == 'p') {
            if (tableDepth == 0) {
              final text = _cleanText(currentParagraph.toString());
              if (text.isNotEmpty) {
                totalParaCount++;
                if (paraBuffer.isNotEmpty &&
                    paraBufferSize + text.length > 1800) {
                  flushParagraphs();
                }
                paraBuffer.add(text);
                paraBufferSize += text.length + 2;
              }
              currentParagraph.clear();
            }
          } else if (event.localName == 'tc') {
            final text = _cleanText(currentCell.toString());
            currentRowCells.add(text.isEmpty ? '-' : text);
            currentCell.clear();
          } else if (event.localName == 'tr') {
            if (currentRowCells.isNotEmpty) {
              currentTableRows.add(currentRowCells.join(' | '));
              currentRowCells.clear();
            }
          } else if (event.localName == 'tbl') {
            tableDepth--;
            if (tableDepth <= 0) {
              tableDepth = 0;
              if (currentTableRows.isNotEmpty) {
                flushParagraphs();
                units.add(LogicalDocumentUnit(
                  label: 'Table ${tableIndex++}',
                  text: currentTableRows.join('\n'),
                ));
                currentTableRows.clear();
              }
            }
          }
        }
      }
    });

    flushParagraphs();
  }

  // 2. Stream headers/footers
  final headerFooterEntries = package.entryNames
      .where((name) =>
          RegExp(r'^word/(header|footer)\d+\.xml$', caseSensitive: false)
              .hasMatch(name))
      .toList()
    ..sort();

  for (final name in headerFooterEntries) {
    final stream = package.openPartStream(name);
    if (stream == null) continue;

    final buffer = StringBuffer();
    var inText = false;
    await stream
        .transform(utf8.decoder)
        .transform(XmlEventDecoder())
        .forEach((events) {
      for (final event in events) {
        if (event is XmlStartElementEvent) {
          if (event.localName == 't') {
            inText = true;
          } else if (event.localName == 'br' || event.localName == 'cr') {
            buffer.write('\n');
          } else if (event.localName == 'tab') {
            buffer.write('\t');
          }
        } else if (event is XmlTextEvent) {
          if (inText) {
            buffer.write(event.value);
          }
        } else if (event is XmlEndElementEvent) {
          if (event.localName == 't') {
            inText = false;
          } else if (event.localName == 'p') {
            buffer.write('\n');
          }
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

  // Find worksheets via workbook relationships, falling back to synthetic enumeration
  var sheetInfos = await _readWorkbookSheets(package);
  if (sheetInfos.isEmpty) {
    final sheetEntries = package.entryNames
        .where((n) => RegExp(r'^xl/worksheets/sheet\d+\.xml$', caseSensitive: false).hasMatch(n))
        .toList()
      ..sort((a, b) {
        final na = int.tryParse(RegExp(r'\d+').firstMatch(a)?.group(0) ?? '0') ?? 0;
        final nb = int.tryParse(RegExp(r'\d+').firstMatch(b)?.group(0) ?? '0') ?? 0;
        return na.compareTo(nb);
      });
    sheetInfos = [
      for (var i = 0; i < sheetEntries.length; i++)
        _SheetInfo(name: 'Sheet ${i + 1}', partPath: sheetEntries[i]),
    ];
  }

  for (final sheet in sheetInfos) {
    final stream = package.openPartStream(sheet.partPath);
    if (stream == null) continue;

    final rows = <String>[];
    final currentRowValues = <String>[];
    String currentCellRef = '';
    String currentCellType = '';
    var inValue = false;
    var inInlineText = false;
    var currentValue = StringBuffer();
    var inlineCellBuffer = StringBuffer();

    await stream
        .transform(utf8.decoder)
        .transform(XmlEventDecoder())
        .forEach((events) {
      for (final event in events) {
        if (event is XmlStartElementEvent) {
          if (event.localName == 'c') {
            currentCellRef = '';
            currentCellType = '';
            inlineCellBuffer.clear();
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
          if (event.localName == 't' && inInlineText) {
            inInlineText = false;
            inlineCellBuffer.write(currentValue.toString());
          } else if (event.localName == 'v') {
            inValue = false;
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
          } else if (event.localName == 'c') {
            if (currentCellType == 'inlineStr') {
              final val = inlineCellBuffer.toString().trim();
              if (val.isNotEmpty) {
                currentRowValues.add(currentCellRef.isEmpty ? val : '$currentCellRef=$val');
              }
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

    units.addAll(_chunkLines('Sheet: ${sheet.name}', rows));
  }

  return LogicalDocument(format: 'XLSX', units: units);
}

// ---------------------------------------------------------------------------
// PPTX Streaming Reader
// ---------------------------------------------------------------------------
Future<LogicalDocument> readPptxDocument(File file) async {
  final package = await _StreamingOpenXmlPackage.load(file);
  final units = <LogicalDocumentUnit>[];

  // 1. Resolve slide order from presentation.xml and its relationships.
  final orderedSlidePaths = await _readPptxSlideOrder(package);
  final List<String> slideEntries;
  if (orderedSlidePaths.isNotEmpty) {
    slideEntries = orderedSlidePaths;
  } else {
    slideEntries = package.entryNames
        .where((n) => RegExp(r'^ppt/slides/slide\d+\.xml$', caseSensitive: false).hasMatch(n))
        .toList()
      ..sort((a, b) {
        final numA = int.tryParse(RegExp(r'\d+').firstMatch(a)?.group(0) ?? '0') ?? 0;
        final numB = int.tryParse(RegExp(r'\d+').firstMatch(b)?.group(0) ?? '0') ?? 0;
        return numA.compareTo(numB);
      });
  }

  for (var index = 0; index < slideEntries.length; index++) {
    final stream = package.openPartStream(slideEntries[index]);
    if (stream == null) continue;

    final paragraphs = <String>[];
    var currentPara = StringBuffer();
    var inText = false;

    await stream
        .transform(utf8.decoder)
        .transform(XmlEventDecoder())
        .forEach((events) {
      for (final event in events) {
        if (event is XmlStartElementEvent) {
          if (event.localName == 'p') {
            currentPara.clear();
          } else if (event.localName == 't') {
            inText = true;
          } else if (event.localName == 'br' || event.localName == 'cr') {
            currentPara.write('\n');
          } else if (event.localName == 'tab') {
            currentPara.write('\t');
          }
        } else if (event is XmlTextEvent) {
          if (inText) {
            currentPara.write(event.value);
          }
        } else if (event is XmlEndElementEvent) {
          if (event.localName == 't') {
            inText = false;
          } else if (event.localName == 'p') {
            final text = _cleanText(currentPara.toString());
            if (text.isNotEmpty) paragraphs.add(text);
            currentPara.clear();
          }
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
  final List<String> entryNames;

  const _StreamingOpenXmlPackage._(this._parts, this.entryNames);

  /// Streams an uncompressed entry on demand, matching part names case-insensitively.
  Stream<List<int>>? openPartStream(String partName) {
    final normalized = _normalizePart(partName).toLowerCase();
    final bytes = _parts[normalized];
    if (bytes == null) return null;
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
      final names = <String>[];
      var totalPartBytes = 0;
      final maxExpandedBytes = _maxPackageBytes * 4;

      for (final entry in archive) {
        if (!entry.isFile) continue;

        final name = _normalizePart(entry.name);
        final lower = name.toLowerCase();
        final isXml = lower.endsWith('.xml');
        final isRels = lower.endsWith('.rels');
        if (!isXml && !isRels) continue; // skip media/fonts before decompression

        final entrySize = entry.size;
        if (entrySize > maxExpandedBytes) {
          throw FormatException(
            'Office document part "$name" expands beyond the safe size limit.',
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
        parts[lower] = content;
        names.add(name);
      }

      return _StreamingOpenXmlPackage._(parts, names);
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
// PPTX presentation helpers — slide order via ppt/presentation.xml and rels
// ---------------------------------------------------------------------------
Future<List<String>> _readPptxSlideOrder(_StreamingOpenXmlPackage package) async {
  final presStream = package.openPartStream('ppt/presentation.xml');
  if (presStream == null) return const [];

  final slideRIds = <String>[];
  await presStream
      .transform(utf8.decoder)
      .transform(XmlEventDecoder())
      .forEach((events) {
    for (final event in events) {
      if (event is XmlStartElementEvent && event.localName == 'sldId') {
        for (final attr in event.attributes) {
          if (attr.localName == 'id' &&
              (attr.namespacePrefix == 'r' || attr.name == 'r:id')) {
            slideRIds.add(attr.value);
            break;
          }
        }
      }
    }
  });

  if (slideRIds.isEmpty) return const [];

  final relsStream = package.openPartStream('ppt/_rels/presentation.xml.rels');
  if (relsStream == null) return const [];

  final relMap = <String, String>{};
  await relsStream
      .transform(utf8.decoder)
      .transform(XmlEventDecoder())
      .forEach((events) {
    for (final event in events) {
      if (event is XmlStartElementEvent && event.localName == 'Relationship') {
        String? id;
        String? target;
        for (final attr in event.attributes) {
          if (attr.localName == 'Id') id = attr.value;
          if (attr.localName == 'Target') target = attr.value;
        }
        if (id != null && target != null) {
          relMap[id] = target;
        }
      }
    }
  });

  final result = <String>[];
  for (final rId in slideRIds) {
    final target = relMap[rId];
    if (target != null) {
      result.add(_normalizePart('ppt/$target'));
    }
  }
  return result;
}

// ---------------------------------------------------------------------------
// Workbook helpers — sheets from xl/workbook.xml mapped via relationships
// ---------------------------------------------------------------------------
class _SheetInfo {
  final String name;
  final String partPath;
  const _SheetInfo({required this.name, required this.partPath});
}

Future<List<_SheetInfo>> _readWorkbookSheets(
    _StreamingOpenXmlPackage package) async {
  final wbStream = package.openPartStream('xl/workbook.xml');
  if (wbStream == null) return const [];

  final rawSheets = <({String name, String rId})>[];
  await wbStream
      .transform(utf8.decoder)
      .transform(XmlEventDecoder())
      .forEach((events) {
    for (final event in events) {
      if (event is XmlStartElementEvent && event.localName == 'sheet') {
        String? name;
        String? rId;
        for (final attr in event.attributes) {
          if (attr.localName == 'name') name = attr.value;
          if (attr.localName == 'id' &&
              (attr.namespacePrefix == 'r' || attr.name == 'r:id')) {
            rId = attr.value;
          }
        }
        if (name != null && rId != null) {
          rawSheets.add((name: name, rId: rId));
        }
      }
    }
  });

  if (rawSheets.isEmpty) return const [];

  final relsStream = package.openPartStream('xl/_rels/workbook.xml.rels');
  final relMap = <String, String>{};
  if (relsStream != null) {
    await relsStream
        .transform(utf8.decoder)
        .transform(XmlEventDecoder())
        .forEach((events) {
      for (final event in events) {
        if (event is XmlStartElementEvent && event.localName == 'Relationship') {
          String? id;
          String? target;
          for (final attr in event.attributes) {
            if (attr.localName == 'Id') id = attr.value;
            if (attr.localName == 'Target') target = attr.value;
          }
          if (id != null && target != null) {
            relMap[id] = target;
          }
        }
      }
    });
  }

  final results = <_SheetInfo>[];
  for (final sheet in rawSheets) {
    final target = relMap[sheet.rId];
    if (target != null) {
      results.add(_SheetInfo(
        name: sheet.name,
        partPath: _normalizePart('xl/$target'),
      ));
    }
  }
  return results;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
List<LogicalDocumentUnit> _chunkLines(String label, List<String> lines) {
  if (lines.isEmpty) return [];
  final units = <LogicalDocumentUnit>[];
  final buffer = <String>[];
  var size = 0;
  var startRow = 1;

  void flush() {
    if (buffer.isEmpty) return;
    final endRow = startRow + buffer.length - 1;
    final rangeLabel = buffer.length == 1
        ? '$label, row $startRow'
        : '$label, rows $startRow–$endRow';
    units.add(LogicalDocumentUnit(
      label: rangeLabel,
      text: buffer.join('\n'),
    ));
    buffer.clear();
    size = 0;
    startRow = endRow + 1;
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
  final value = slash == -1 ? name : name.substring(slash + 1);
  final base = value.replaceAll(RegExp(r'\.xml$', caseSensitive: false), '');
  final match = RegExp(r'^([a-zA-Z]+)(\d*)$').firstMatch(base);
  if (match != null) {
    final word = match.group(1)!;
    final num = match.group(2) ?? '';
    final capitalized = word[0].toUpperCase() + word.substring(1);
    return num.isEmpty ? capitalized : '$capitalized $num';
  }
  return base.replaceAll('_', ' ').trim();
}

String _cleanText(String text) => text
    .replaceAll(RegExp(r'[ \t]+'), ' ')
    .replaceAll(RegExp(r'\n{3,}'), '\n\n')
    .trim();