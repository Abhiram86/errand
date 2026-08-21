import 'dart:io';

import 'document_models.dart';
import 'open_xml_reader.dart';
import 'pdf_reader.dart';

export 'document_models.dart';

/// Returns a structured reader result for formats that should not be decoded
/// as arbitrary UTF-8 bytes. Returns null for ordinary text files so the
/// caller can keep the existing byte-range behavior.
Future<LogicalRead?> readStructuredFile(
  File file, {
  required int offset,
  required int length,
}) async {
  final document = await readStructuredDocument(file);
  return document?.read(offset: offset, length: length);
}

/// Loads a structured document once so callers can paginate the returned
/// logical units without reparsing the file for every read.
Future<LogicalDocument?> readStructuredDocument(File file) async {
  final extension = _extension(file.path);

  switch (extension) {
    case 'pdf':
      return readPdfDocument(file);

    case 'docx':
    case 'docm':
      return readDocxDocument(file);

    case 'xlsx':
    case 'xlsm':
      return readXlsxDocument(file);

    case 'pptx':
    case 'pptm':
      return readPptxDocument(file);

    case 'ppt':
    case 'doc':
    case 'xls':
      throw FormatException(
        'Legacy $extension files are binary Office formats and cannot be '
        'read as structured text. DOCX/XLSX/PPTX are supported; convert '
        'this file first or open it with a compatible office app.',
      );

    case 'jpg':
    case 'jpeg':
    case 'png':
    case 'gif':
    case 'webp':
    case 'heic':
    case 'heif':
      throw FormatException(
        'Image files are not text documents. Use the vision reader for '
        'image understanding.',
      );

    default:
      return null;
  }
}

String _extension(String filePath) {
  final lastDot = filePath.lastIndexOf('.');

  if (lastDot == -1 || lastDot == filePath.length - 1) {
    return '';
  }

  return filePath.substring(lastDot + 1).toLowerCase();
}
