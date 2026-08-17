import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handy_flutter/internal/document_reading/open_xml_reader.dart';

void main() {
  test('reads DOCX paragraphs and tables', () async {
    final file = await _writePackage({
      'word/document.xml': '''
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            <w:p><w:r><w:t>Hello document</w:t></w:r></w:p>
            <w:tbl>
              <w:tr><w:tc><w:p><w:r><w:t>Name</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Value</w:t></w:r></w:p></w:tc></w:tr>
            </w:tbl>
          </w:body>
        </w:document>
      ''',
    }, suffix: '.docx');

    final document = await readDocxDocument(file);

    expect(document.units, hasLength(2));
    expect(document.units[0].text, 'Hello document');
    expect(document.units[1].text, 'Name | Value');
  });

  test(
    'reads XLSX workbook relationships, shared strings, and cells',
    () async {
      final file = await _writePackage({
        'xl/workbook.xml': '''
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets><sheet name="Sales" r:id="rId1"/></sheets>
        </workbook>
      ''',
        'xl/_rels/workbook.xml.rels': '''
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Target="worksheets/sheet1.xml"/>
        </Relationships>
      ''',
        'xl/sharedStrings.xml': '''
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <si><t>Widget</t></si>
        </sst>
      ''',
        'xl/worksheets/sheet1.xml': '''
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1"><v>42</v></c></row></sheetData>
        </worksheet>
      ''',
      }, suffix: '.xlsx');

      final document = await readXlsxDocument(file);

      expect(document.units, hasLength(1));
      expect(document.units.single.text, contains('A1=Widget'));
      expect(document.units.single.text, contains('B1=42'));
    },
  );

  test('reads PPTX slide order and text runs', () async {
    final file = await _writePackage({
      'ppt/presentation.xml': '''
        <p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <p:sldIdLst><p:sldId id="256" r:id="rId1"/></p:sldIdLst>
        </p:presentation>
      ''',
      'ppt/_rels/presentation.xml.rels': '''
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Target="slides/slide1.xml"/>
        </Relationships>
      ''',
      'ppt/slides/slide1.xml': '''
        <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
          <p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>Quarterly</a:t></a:r><a:r><a:t> results</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld>
        </p:sld>
      ''',
    }, suffix: '.pptx');

    final document = await readPptxDocument(file);

    expect(document.units, hasLength(1));
    expect(document.units.single.label, 'Slide 1');
    expect(document.units.single.text, 'Quarterly results');
  });
}

Future<File> _writePackage(
  Map<String, String> parts, {
  required String suffix,
}) async {
  final directory = await Directory.systemTemp.createTemp('handy_reader_test');
  addTearDown(() => directory.delete(recursive: true));

  final archive = Archive();
  for (final entry in parts.entries) {
    archive.addFile(ArchiveFile.string(entry.key, entry.value));
  }

  final file = File('${directory.path}/fixture$suffix');
  await file.writeAsBytes(ZipEncoder().encodeBytes(archive));
  return file;
}
