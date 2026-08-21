import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'document_models.dart';

const _maxPackageBytes = 64 * 1024 * 1024;
const _maxPackageEntries = 2000;
const _maxXmlPartBytes = 16 * 1024 * 1024;

const _wordNamespace =
    'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
const _drawingNamespace =
    'http://schemas.openxmlformats.org/drawingml/2006/main';
const _spreadsheetNamespace =
    'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
const _officeRelationshipsNamespace =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const _packageRelationshipsNamespace =
    'http://schemas.openxmlformats.org/package/2006/relationships';

Future<LogicalDocument> readDocxDocument(File file) async {
  final package = await _OpenXmlPackage.load(file);
  final units = <LogicalDocumentUnit>[];

  final documentXml = package.xml('word/document.xml');
  if (documentXml != null) {
    final body = documentXml.findAllElements(
      'body',
      namespaceUri: _wordNamespace,
    );
    if (body.isNotEmpty) {
      for (final child in body.first.children.whereType<XmlElement>()) {
        if (child.localName == 'p' && child.namespaceUri == _wordNamespace) {
          final text = _wordParagraphText(child);
          if (text.isNotEmpty) {
            units.add(
              LogicalDocumentUnit(
                label: 'Paragraph ${units.length + 1}',
                text: text,
              ),
            );
          }
        } else if (child.localName == 'tbl' &&
            child.namespaceUri == _wordNamespace) {
          final rows = _wordTableRows(child);
          if (rows.isNotEmpty) {
            units.add(
              LogicalDocumentUnit(
                label: 'Table ${units.length + 1}',
                text: rows.join('\n'),
              ),
            );
          }
        }
      }
    }
  }

  for (final entry
      in package.names
          .where(
            (name) => RegExp(r'^word/(header|footer)\d+\.xml$').hasMatch(name),
          )
          .toList()
        ..sort()) {
    final xml = package.xml(entry);
    if (xml == null) continue;
    final text = _wordDocumentText(xml);
    if (text.isNotEmpty) {
      units.add(LogicalDocumentUnit(label: _prettyPartName(entry), text: text));
    }
  }

  return LogicalDocument(format: 'DOCX', units: units);
}

Future<LogicalDocument> readXlsxDocument(File file) async {
  final package = await _OpenXmlPackage.load(file);
  final workbook = package.xml('xl/workbook.xml');
  if (workbook == null) {
    return const LogicalDocument(format: 'XLSX', units: []);
  }

  final sharedStrings = _readSharedStrings(package.xml('xl/sharedStrings.xml'));
  final relationships = _readRelationships(
    package.xml('xl/_rels/workbook.xml.rels'),
  );
  final units = <LogicalDocumentUnit>[];

  for (final sheet in workbook.findAllElements(
    'sheet',
    namespaceUri: _spreadsheetNamespace,
  )) {
    final name = sheet.getAttribute('name') ?? 'Sheet ${units.length + 1}';
    final relationshipId = sheet.getAttribute(
      'id',
      namespaceUri: _officeRelationshipsNamespace,
    );
    final target = relationshipId == null
        ? null
        : relationships[relationshipId];
    final worksheetName = _resolvePart('xl/workbook.xml', target);
    final worksheet = worksheetName == null ? null : package.xml(worksheetName);
    if (worksheet == null) continue;

    final rows = <String>[];
    for (final row in worksheet.findAllElements(
      'row',
      namespaceUri: _spreadsheetNamespace,
    )) {
      final values = <String>[];
      for (final cell in row.findAllElements(
        'c',
        namespaceUri: _spreadsheetNamespace,
      )) {
        final reference = cell.getAttribute('r') ?? '';
        final type = cell.getAttribute('t');
        final value = _cellValue(cell, type, sharedStrings);
        if (value.isNotEmpty) {
          values.add(reference.isEmpty ? value : '$reference=$value');
        }
      }
      if (values.isNotEmpty) rows.add(values.join(' | '));
    }

    units.addAll(_chunkLines('Sheet: $name', rows));
  }

  return LogicalDocument(format: 'XLSX', units: units);
}

Future<LogicalDocument> readPptxDocument(File file) async {
  final package = await _OpenXmlPackage.load(file);
  final presentation = package.xml('ppt/presentation.xml');
  final relationships = _readRelationships(
    package.xml('ppt/_rels/presentation.xml.rels'),
  );
  if (presentation == null) {
    return const LogicalDocument(format: 'PPTX', units: []);
  }

  final units = <LogicalDocumentUnit>[];
  final slideIds = presentation.descendants
      .whereType<XmlElement>()
      .where((element) => element.localName == 'sldId')
      .toList();
  for (var index = 0; index < slideIds.length; index++) {
    final relationshipId = slideIds
        .elementAt(index)
        .getAttribute('id', namespaceUri: _officeRelationshipsNamespace);
    final target = relationshipId == null
        ? null
        : relationships[relationshipId];
    final slideName = _resolvePart('ppt/presentation.xml', target);
    final slide = slideName == null ? null : package.xml(slideName);
    if (slide == null) continue;

    final paragraphs = slide
        .findAllElements('p', namespaceUri: _drawingNamespace)
        .map(_drawingParagraphText)
        .where((text) => text.isNotEmpty)
        .toList();

    final text = paragraphs.join('\n');
    units.add(
      LogicalDocumentUnit(
        label: 'Slide ${index + 1}',
        text: text.isEmpty ? '[No text; slide may contain only images.]' : text,
      ),
    );
  }

  return LogicalDocument(format: 'PPTX', units: units);
}

class _OpenXmlPackage {
  final Map<String, Uint8List> _parts;

  const _OpenXmlPackage(this._parts);

  Iterable<String> get names => _parts.keys;

  XmlDocument? xml(String name) {
    final bytes = _parts[_normalizePart(name)];

    if (bytes == null || bytes.length > _maxXmlPartBytes) {
      return null;
    }

    try {
      return XmlDocument.parse(
        utf8.decode(bytes, allowMalformed: true),
      );
    } on XmlException {
      return null;
    }
  }

  static Future<_OpenXmlPackage> load(File file) async {
    final compressedSize = await file.length();

    if (compressedSize > _maxPackageBytes) {
      throw FormatException(
        'Office document is too large to inspect safely '
        '(maximum $_maxPackageBytes bytes).',
      );
    }

    final input = InputFileStream(file.path);

    try {
      // IMPORTANT:
      // Do not use verify: true here. CRC verification causes archive
      // entries to be decompressed before we perform our size checks.
      //
      // decodeStream() uses the file-backed input and ArchiveFile keeps
      // ZIP content lazy until readBytes()/content is requested.
      final archive = ZipDecoder().decodeStream(input);

      if (archive.length > _maxPackageEntries) {
        throw FormatException(
          'Office document contains too many package entries.',
        );
      }

      final parts = <String, Uint8List>{};

      var totalPartBytes = 0;

      for (final entry in archive) {
        if (!entry.isFile) {
          continue;
        }

        final name = _normalizePart(entry.name);
        // OPT-04: Office packages can contain large media (ppt/media/*,
        // word/media/*, xl/media/*, embedded fonts). We only need XML
        // parts and relationships — skip everything else before
        // decompression to keep peak heap ~ bounded by XML size, not
        // by 20 MB images/embedded binaries that were previously cached.
        final lower = name.toLowerCase();
        final isXml = lower.endsWith('.xml');
        final isRels = lower.endsWith('.rels');
        if (!isXml && !isRels) {
          continue;
        }

        // entry.size is the uncompressed size from the ZIP metadata.
        //
        // This check happens BEFORE readBytes(), so an oversized entry
        // is never decompressed into a large Uint8List.
        final entrySize = entry.size;

        if (isXml && entrySize > _maxXmlPartBytes) {
          continue;
        }

        // Do the arithmetic without allowing integer overflow.
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

        // Only now do we request decompression.
        final content = entry.readBytes();

        if (content == null) {
          continue;
        }

        // Defend against malformed ZIP metadata. The actual decompressed
        // content must not exceed the declared/remaining budget.
        if (content.length > maxExpandedBytes - totalPartBytes) {
          throw FormatException(
            'Office document expands beyond the safe size limit.',
          );
        }

        // Keep the actual size rather than trusting ZIP metadata.
        totalPartBytes += content.length;

        parts[name] = content;
      }

      return _OpenXmlPackage(parts);
    } on ArchiveException catch (e) {
      throw FormatException(
        'Office document contains an invalid ZIP archive: $e',
      );
    } finally {
      input.close();
    }
  }
}

String _wordParagraphText(XmlElement paragraph) {
  final buffer = StringBuffer();
  for (final node in paragraph.descendants) {
    if (node is! XmlElement || node.namespaceUri != _wordNamespace) continue;
    if (node.localName == 't') buffer.write(node.innerText);
    if (node.localName == 'tab') buffer.write('\t');
    if (node.localName == 'br' || node.localName == 'cr') buffer.write('\n');
  }
  return _cleanText(buffer.toString());
}

List<String> _wordTableRows(XmlElement table) {
  return table
      .findAllElements('tr', namespaceUri: _wordNamespace)
      .map(
        (row) => row
            .findAllElements('tc', namespaceUri: _wordNamespace)
            .map((cell) => _wordDocumentText(cell))
            .where((text) => text.isNotEmpty)
            .join(' | '),
      )
      .where((row) => row.isNotEmpty)
      .toList();
}

String _wordDocumentText(XmlNode node) {
  final buffer = StringBuffer();
  for (final paragraph in node.findAllElements(
    'p',
    namespaceUri: _wordNamespace,
  )) {
    final text = _wordParagraphText(paragraph);
    if (text.isNotEmpty) buffer.writeln(text);
  }
  return _cleanText(buffer.toString());
}

String _drawingParagraphText(XmlElement paragraph) => _cleanText(
  paragraph
      .findAllElements('t', namespaceUri: _drawingNamespace)
      .map((element) => element.innerText)
      .join(),
);

Map<String, String> _readRelationships(XmlDocument? document) {
  if (document == null) return {};
  return {
    for (final relationship in document.findAllElements(
      'Relationship',
      namespaceUri: _packageRelationshipsNamespace,
    ))
      if (relationship.getAttribute('Id') != null &&
          relationship.getAttribute('Target') != null)
        relationship.getAttribute('Id')!: relationship.getAttribute('Target')!,
  };
}

String? _resolvePart(String source, String? target) {
  if (target == null || target.isEmpty) return null;
  final normalizedTarget = target.replaceAll('\\', '/');
  if (normalizedTarget.startsWith('/')) {
    return _normalizePart(normalizedTarget.substring(1));
  }

  final slash = source.lastIndexOf('/');
  final directory = slash == -1 ? '' : source.substring(0, slash + 1);
  return _normalizePart('$directory$normalizedTarget');
}

List<String> _readSharedStrings(XmlDocument? document) {
  if (document == null) return [];
  return [
    for (final item in document.findAllElements(
      'si',
      namespaceUri: _spreadsheetNamespace,
    ))
      item
          .findAllElements('t', namespaceUri: _spreadsheetNamespace)
          .map((text) => text.innerText)
          .join(),
  ];
}

String _cellValue(XmlElement cell, String? type, List<String> sharedStrings) {
  final formula = cell
      .getElement('f', namespaceUri: _spreadsheetNamespace)
      ?.innerText
      .trim();
  final rawValue =
      cell
          .getElement('v', namespaceUri: _spreadsheetNamespace)
          ?.innerText
          .trim() ??
      '';

  if (type == 's') {
    final index = int.tryParse(rawValue);
    return index != null && index >= 0 && index < sharedStrings.length
        ? sharedStrings[index]
        : rawValue;
  }
  if (type == 'inlineStr') {
    return cell
        .findAllElements('t', namespaceUri: _spreadsheetNamespace)
        .map((text) => text.innerText)
        .join();
  }
  if (type == 'b') return rawValue == '1' ? 'TRUE' : 'FALSE';
  if (formula != null && formula.isNotEmpty) {
    return rawValue.isEmpty ? '=$formula' : '=$formula (value: $rawValue)';
  }
  return rawValue;
}

List<LogicalDocumentUnit> _chunkLines(String label, List<String> lines) {
  if (lines.isEmpty) return [];
  final units = <LogicalDocumentUnit>[];
  final buffer = <String>[];
  var size = 0;

  void flush() {
    if (buffer.isEmpty) return;
    units.add(
      LogicalDocumentUnit(
        label: '$label, rows ${units.length + 1}',
        text: buffer.join('\n'),
      ),
    );
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
