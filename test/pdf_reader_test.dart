import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:errand/internal/document_reading/pdf_reader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('pdf_reader');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      switch (call.method) {
        case 'openPdf':
          final path = call.arguments['path'] as String;
          if (path.contains('non_existent')) {
            throw PlatformException(code: 'FILE_NOT_FOUND');
          }
          if (path.contains('blank')) {
            return {'docId': 'blank_doc', 'pageCount': 1};
          }
          return {'docId': 'test_doc', 'pageCount': 2};

        case 'extractPage':
          final docId = call.arguments['docId'] as String;
          final pageIndex = call.arguments['pageIndex'] as int;
          if (docId == 'blank_doc') {
            return '';
          }
          if (pageIndex == 0) {
            return List.filled(50, 'Hello PDF world.').join(' ');
          }
          if (pageIndex == 1) {
            return 'Second page content here.';
          }
          return '';

        case 'closePdf':
          return true;

        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('reads PDF pages, provides true units length, and paginates without page truncation', () async {
    final tempDir = await Directory.systemTemp.createTemp('pdf_test');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final file = File('${tempDir.path}/test.pdf');
    await file.writeAsString('dummy pdf bytes');

    final document = await readPdfDocument(file);

    // Units length should reflect actual page count
    expect(document.units.length, 2);
    expect(document.unitCount, 2);

    // Read with default budget 512
    final read1 = await document.read(offset: 0, length: 512);
    expect(read1.start, 0);
    expect(read1.end, 1);
    expect(read1.hasMore, isTrue);
    expect(read1.nextOffset, 1);
    expect(read1.output, contains('Hello PDF world.'));
    // Page 1 should NOT be truncated with ... [truncated]
    expect(read1.output, isNot(contains('... [truncated]')));

    // Read page 2
    final read2 = await document.read(offset: read1.nextOffset, length: 512);
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
    final tempDir = await Directory.systemTemp.createTemp('pdf_blank_test');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final file = File('${tempDir.path}/blank.pdf');
    await file.writeAsString('dummy blank pdf');

    final document = await readPdfDocument(file);
    expect(document.units.length, 1);

    final read = await document.read(offset: 0, length: 512);
    expect(read.output, contains('scanned images'));
    document.dispose();
  });
}
