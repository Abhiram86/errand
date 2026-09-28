import 'dart:convert';
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

  test('desktop fallback extracts text from uncompressed and FlateDecode streams when channel is missing', () async {
    final tempDir = await Directory.systemTemp.createTemp('pdf_desktop_test');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final file = File('${tempDir.path}/desktop.pdf');

    // Create a PDF with uncompressed stream
    final pdfContent = '''
%PDF-1.4
1 0 obj
<< /Length 60 >>
stream
BT
/F1 12 Tf
(Fallback text from pure Dart reader) Tj
[( Array) 10 ( text)] TJ
ET
endstream
endobj
trailer
<< /Root 1 0 R >>
%%EOF
''';
    await file.writeAsString(pdfContent);

    // Call with a dummy channel that throws MissingPluginException to trigger fallback
    const missingChannel = MethodChannel('missing_channel');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(missingChannel, (MethodCall call) async {
      throw MissingPluginException();
    });

    final document = await readPdfDocument(file, channel: missingChannel);
    expect(document.units, isNotEmpty);

    final read = await document.read(offset: 0, length: 512);
    expect(read.output, contains('Fallback text from pure Dart reader'));
    expect(read.output, contains('Array text'));
    document.dispose();
  });

  test('desktop fallback throws FormatException when PDF has no readable text stream', () async {
    final tempDir = await Directory.systemTemp.createTemp('pdf_empty_stream');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final file = File('${tempDir.path}/empty.pdf');
    await file.writeAsString('%PDF-1.4\n1 0 obj\n<<>>\nendobj\n%%EOF');

    const missingChannel = MethodChannel('missing_empty_channel');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(missingChannel, (MethodCall call) async {
      throw MissingPluginException();
    });

    expect(
      () => readPdfDocument(file, channel: missingChannel),
      throwsA(isA<FormatException>()),
    );
  });

  test('PooledPdfDocument dispose invokes closePdf method on channel', () async {
    var closeCalled = false;
    const testChannel = MethodChannel('test_close_channel');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(testChannel, (MethodCall call) async {
      if (call.method == 'openPdf') {
        return {'docId': 'close_doc_1', 'pageCount': 1};
      }
      if (call.method == 'closePdf') {
        closeCalled = true;
        return true;
      }
      return null;
    });

    final tempDir = await Directory.systemTemp.createTemp('pdf_close_test');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final file = File('${tempDir.path}/close_test.pdf');
    await file.writeAsString('pdf data');

    final doc = await readPdfDocument(file, channel: testChannel);
    expect(closeCalled, isFalse);
    doc.dispose();
    expect(closeCalled, isTrue);
  });

  test('desktop fallback extracts text from compressed FlateDecode stream', () async {
    final tempDir = await Directory.systemTemp.createTemp('pdf_flate_test');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final file = File('${tempDir.path}/flate.pdf');

    final streamContent = 'BT (Compressed Flate Text Here) Tj ET';
    final compressed = zlib.encode(utf8.encode(streamContent));
    final header = utf8.encode('1 0 obj\n<< /Length ${compressed.length} /Filter /FlateDecode >>\nstream\n');
    final footer = utf8.encode('\nendstream\nendobj\n');
    final fullBytes = <int>[...header, ...compressed, ...footer];

    await file.writeAsBytes(fullBytes);

    const missingChannel = MethodChannel('missing_flate_channel');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(missingChannel, (MethodCall call) async {
      throw MissingPluginException();
    });

    final doc = await readPdfDocument(file, channel: missingChannel);
    final read = await doc.read(offset: 0, length: 512);
    expect(read.output, contains('Compressed Flate Text Here'));
    doc.dispose();
  });
}
