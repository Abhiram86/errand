import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:errand/internal/document_reading/pdf_reader.dart';

void main() {
  test('reads PDF pages, provides true units length, and paginates without page truncation', () async {
    final pdfDoc = PdfDocument();
    final font = PdfStandardFont(PdfFontFamily.helvetica, 12);

    // Create a page with ~1500 chars (exceeding default length 512)
    final page1 = pdfDoc.pages.add();
    final longText = List.filled(50, 'Hello PDF world.').join(' ');
    page1.graphics.drawString(longText, font);

    // Page 2
    final page2 = pdfDoc.pages.add();
    page2.graphics.drawString('Second page content here.', font);

    final bytes = await pdfDoc.save();
    pdfDoc.dispose();

    final tempDir = await Directory.systemTemp.createTemp('pdf_test');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final file = File('${tempDir.path}/test.pdf');
    await file.writeAsBytes(bytes);

    final document = await readPdfDocument(file);

    // Units length should reflect actual page count
    expect(document.units.length, 2);

    // Read with default budget 512
    final read1 = document.read(offset: 0, length: 512);
    expect(read1.start, 0);
    expect(read1.end, 1);
    expect(read1.hasMore, isTrue);
    expect(read1.nextOffset, 1);
    expect(read1.output, contains('Hello PDF world.'));
    // Page 1 should NOT be truncated with ... [truncated]
    expect(read1.output, isNot(contains('... [truncated]')));

    // Read page 2
    final read2 = document.read(offset: read1.nextOffset, length: 512);
    expect(read2.start, 1);
    expect(read2.end, 2);
    expect(read2.hasMore, isFalse);
    expect(read2.output, contains('Second page content here.'));

    document.dispose();
    expect(
      () => document.read(offset: 0, length: 512),
      throwsStateError,
    );
  });

  test('handles empty / scanned pages with informative notice', () async {
    final pdfDoc = PdfDocument();
    pdfDoc.pages.add(); // blank page

    final bytes = await pdfDoc.save();
    pdfDoc.dispose();

    final tempDir = await Directory.systemTemp.createTemp('pdf_blank_test');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final file = File('${tempDir.path}/blank.pdf');
    await file.writeAsBytes(bytes);

    final document = await readPdfDocument(file);
    expect(document.units.length, 1);

    final read = document.read(offset: 0, length: 512);
    expect(read.output, contains('scanned images'));
    document.dispose();
  });
}
