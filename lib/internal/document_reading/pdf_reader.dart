import 'dart:io';

import 'package:read_pdf_text/read_pdf_text.dart';

import 'document_reader.dart';

Future<LogicalDocument> readPdfDocument(File file) async {
  final pages = await ReadPdfText.getPDFtextPaginated(file.path);

  return LogicalDocument(
    format: 'PDF',
    units: [
      for (var i = 0; i < pages.length; i++)
        LogicalDocumentUnit(label: 'Page ${i + 1}', text: pages[i].trim()),
    ],
  );
}
