import 'package:flutter_test/flutter_test.dart';
import 'package:errand/internal/document_reading/document_reader.dart';

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
}
