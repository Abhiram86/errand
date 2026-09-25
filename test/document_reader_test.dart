import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:errand/internal/document_reading/document_reader.dart';
import 'package:errand/tools/file_tools.dart';

class MockDisposedDocument extends LogicalDocument {
  bool isDisposed = false;

  MockDisposedDocument({required super.format, super.units = const []});

  @override
  void dispose() {
    isDisposed = true;
  }
}

class FakeFileStat implements FileStat {
  @override
  final DateTime modified;
  @override
  final int size;
  @override
  final FileSystemEntityType type = FileSystemEntityType.file;
  @override
  final int mode = 0;
  @override
  final DateTime changed;
  @override
  final DateTime accessed;

  FakeFileStat({required this.modified, required this.size})
      : changed = modified,
        accessed = modified;

  @override
  String modeString() => 'rw-r--r--';
}

void main() {
  test('structured pagination uses logical units and overlaps boundaries', () {
    const document = LogicalDocument(
      format: 'PPTX',
      units: [
        LogicalDocumentUnit(label: 'Slide 1', text: 'one'),
        LogicalDocumentUnit(label: 'Slide 2', text: 'two'),
        LogicalDocumentUnit(label: 'Slide 3', text: 'three'),
      ],
    );

    final first = document.read(offset: 0, length: 24);

    expect(first.start, 0);
    expect(first.end, 2);
    expect(first.nextOffset, 1);
    expect(first.hasMore, isTrue);
    expect(first.output, contains('Slide 1'));
    expect(first.output, contains('Slide 2'));
  });

  group('DocumentLruCache (P12.7)', () {
    test('evicts oldest entry and disposes document when maxBytes is exceeded', () async {
      final cache = DocumentLruCache(maxBytes: 1000, maxEntries: 10);
      final mtime = DateTime.now();

      final file1 = File('/tmp/file1.pdf');
      final stat1 = FakeFileStat(modified: mtime, size: 600);
      final doc1 = MockDisposedDocument(format: 'PDF');

      final file2 = File('/tmp/file2.pdf');
      final stat2 = FakeFileStat(modified: mtime, size: 600);
      final doc2 = MockDisposedDocument(format: 'PDF');

      await cache.getOrParse(file: file1, stat: stat1, parser: (_) async => doc1);
      expect(cache.currentBytes, 600);
      expect(cache.entryCount, 1);
      expect(doc1.isDisposed, isFalse);

      await cache.getOrParse(file: file2, stat: stat2, parser: (_) async => doc2);
      expect(cache.currentBytes, 600);
      expect(cache.entryCount, 1);
      expect(doc1.isDisposed, isTrue);
      expect(doc2.isDisposed, isFalse);
    });

    test('refreshes recency on hit and evicts least-recently used entry', () async {
      final cache = DocumentLruCache(maxBytes: 10000, maxEntries: 2);
      final mtime = DateTime.now();

      final file1 = File('/tmp/a.pdf');
      final stat1 = FakeFileStat(modified: mtime, size: 100);
      final doc1 = MockDisposedDocument(format: 'PDF');

      final file2 = File('/tmp/b.pdf');
      final stat2 = FakeFileStat(modified: mtime, size: 100);
      final doc2 = MockDisposedDocument(format: 'PDF');

      final file3 = File('/tmp/c.pdf');
      final stat3 = FakeFileStat(modified: mtime, size: 100);
      final doc3 = MockDisposedDocument(format: 'PDF');

      await cache.getOrParse(file: file1, stat: stat1, parser: (_) async => doc1);
      await cache.getOrParse(file: file2, stat: stat2, parser: (_) async => doc2);

      // Access file1 again -> moves file1 to MRU, making file2 the LRU
      final hitDoc = await cache.getOrParse(file: file1, stat: stat1);
      expect(identical(hitDoc, doc1), isTrue);

      // Adding file3 should evict file2, keeping file1 and file3
      await cache.getOrParse(file: file3, stat: stat3, parser: (_) async => doc3);

      expect(doc2.isDisposed, isTrue);
      expect(doc1.isDisposed, isFalse);
      expect(doc3.isDisposed, isFalse);
      expect(cache.entryCount, 2);
    });

    test('oversized single entry bypasses cache without evicting it', () async {
      final cache = DocumentLruCache(maxBytes: 500, maxEntries: 10);
      final mtime = DateTime.now();

      final small = File('/tmp/small.pdf');
      final smallDoc = MockDisposedDocument(format: 'PDF');
      await cache.getOrParse(
        file: small,
        stat: FakeFileStat(modified: mtime, size: 200),
        parser: (_) async => smallDoc,
      );
      expect(cache.entryCount, 1);

      final huge = File('/tmp/huge.pdf');
      final hugeDoc = MockDisposedDocument(format: 'PDF');
      final result = await cache.getOrParse(
        file: huge,
        stat: FakeFileStat(modified: mtime, size: 5000),
        parser: (_) async => hugeDoc,
      );
      // Result still returned, but neither cached nor evicting the small entry.
      expect(identical(result, hugeDoc), isTrue);
      expect(cache.entryCount, 1);
      expect(cache.currentBytes, 200);
      expect(smallDoc.isDisposed, isFalse);
      expect(hugeDoc.isDisposed, isFalse);
    });

    test('deduplicates concurrent in-flight parses for the same file', () async {      final cache = DocumentLruCache(maxBytes: 10000, maxEntries: 10);
      final file = File('/tmp/concurrent.pdf');
      final stat = FakeFileStat(modified: DateTime.now(), size: 200);

      var parseCount = 0;
      Future<LogicalDocument?> slowParser(File f) async {
        parseCount++;
        await Future.delayed(const Duration(milliseconds: 20));
        return MockDisposedDocument(format: 'PDF');
      }

      final f1 = cache.getOrParse(file: file, stat: stat, parser: slowParser);
      final f2 = cache.getOrParse(file: file, stat: stat, parser: slowParser);

      final results = await Future.wait([f1, f2]);
      expect(parseCount, 1);
      expect(identical(results[0], results[1]), isTrue);
    });
  });
}
