import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../../services/intent_service.dart';
import '../../theme/app_colors.dart';

Widget buildClampedTable(
  BuildContext context,
  List<CustomTableRow> tableRows,
  TextStyle textStyle,
  GptMarkdownConfig config,
) {
  return ClampedTableView(
    tableRows: tableRows,
    textStyle: textStyle,
    config: config,
  );
}

/// Cheap heuristic: only cells containing likely inline markup pay for a
/// nested GptMarkdown parse; everything else renders as plain Text.
bool looksLikeMarkdown(String text) {
  if (text.contains('**') ||
      text.contains('__') ||
      text.contains('`') ||
      text.contains('~~') ||
      text.contains('[') ||
      text.contains('](')) {
    return true;
  }
  // Single-emphasis markers are easy to false-positive on (e.g. "a*b"),
  // so require a plausible open/close pair.
  final singleStar = RegExp(r'\*[^*\n]+\*');
  final singleUnderscore = RegExp(r'_[^_\n]+_');
  return singleStar.hasMatch(text) || singleUnderscore.hasMatch(text);
}

class ClampedTableView extends StatefulWidget {
  final List<CustomTableRow> tableRows;
  final TextStyle textStyle;
  final GptMarkdownConfig config;

  const ClampedTableView({
    super.key,
    required this.tableRows,
    required this.textStyle,
    required this.config,
  });

  @override
  State<ClampedTableView> createState() => _ClampedTableViewState();
}

class _ClampedTableViewState extends State<ClampedTableView> {
  late final ScrollController _scrollController;
  bool _copied = false;
  Timer? _copyResetTimer;

  /// Upper bound on clipboard payload to avoid UI jank and
  /// TransactionTooLarge binder failures on huge LLM tables.
  static const int _maxCopyChars = 200000;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
  }

  @override
  void dispose() {
    _copyResetTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _copyTable() async {
    final rows = widget.tableRows;
    if (rows.isEmpty) return;

    final maxCols = rows.fold<int>(
      0,
      (max, row) => row.fields.length > max ? row.fields.length : max,
    );
    if (maxCols == 0) return;

    // 1. Plain text / TSV: Tab-delimited cells, newline-delimited rows.
    // Excel, Apple Notes, Google Docs, Notion reliably paste TSV into tables.
    // Newlines collapse to spaces (spreadsheet-friendly single-line cells).
    final tsvLines = <String>[];
    // 2. Rich HTML table with a single <thead> + single <tbody>.
    // Newlines become <br/> for fidelity. Raw markdown is preserved as-is.
    final htmlBuffer = StringBuffer();
    htmlBuffer.write('<table border="1" cellpadding="4" cellspacing="0">');

    var truncated = false;
    var charBudget = _maxCopyChars;

    void appendTsv(String line) {
      if (truncated) return;
      if (line.length > charBudget) {
        tsvLines.add('${line.substring(0, charBudget)}…');
        truncated = true;
      } else {
        tsvLines.add(line);
        charBudget -= line.length + 1;
      }
    }

    final headHtml = StringBuffer();
    final bodyHtml = StringBuffer();
    var bodyStarted = false;

    for (final row in rows) {
      final cellValues = List.generate(maxCols, (colIdx) {
        if (colIdx < row.fields.length) {
          return row.fields[colIdx].data.trim();
        }
        return '';
      });

      // TSV row
      appendTsv(cellValues.map((v) => v.replaceAll('\t', ' ').replaceAll('\n', ' ')).join('\t'));

      // HTML row: header rows before the first body row go to <thead>;
      // later header rows render as <th> inside <tbody> (valid HTML).
      String htmlRow(String tag, StringBuffer target) {
        final before = target.length;
        target.write('<tr>');
        for (final val in cellValues) {
          final escaped = val
              .replaceAll('&', '&amp;')
              .replaceAll('<', '&lt;')
              .replaceAll('>', '&gt;')
              .replaceAll('"', '&quot;')
              .replaceAll('\n', '<br/>');
          target.write('<$tag>$escaped</$tag>');
        }
        target.write('</tr>');
        return target.toString().substring(before);
      }

      if (row.isHeader && !bodyStarted) {
        htmlRow('th', headHtml);
      } else {
        bodyStarted = true;
        htmlRow(row.isHeader ? 'th' : 'td', bodyHtml);
      }
    }

    if (headHtml.isNotEmpty) htmlBuffer.write('<thead>$headHtml</thead>');
    if (bodyHtml.isNotEmpty) htmlBuffer.write('<tbody>$bodyHtml</tbody>');
    htmlBuffer.write('</table>');

    var tsvText = tsvLines.join('\n');
    var htmlText = htmlBuffer.toString();
    if (htmlText.length > _maxCopyChars) {
      htmlText = '${htmlText.substring(0, _maxCopyChars)}…';
      truncated = true;
    }

    // Copy via native Android ClipData (supports HTML + text simultaneously).
    // Falls back to Flutter's Clipboard.setData if running elsewhere or if failed.
    bool richCopied = false;
    try {
      richCopied = await IntentService().copyRichText(text: tsvText, html: htmlText);
    } catch (_) {}

    if (!richCopied) {
      await Clipboard.setData(ClipboardData(text: tsvText));
    }

    if (mounted) {
      _copyResetTimer?.cancel();
      setState(() => _copied = true);
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            richCopied
                ? (truncated
                    ? 'Table copied (truncated to clipboard size limit)'
                    : 'Table copied to clipboard (ready for Notion, Notes & Docs)')
                : 'Table copied as plain text',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
      _copyResetTimer = Timer(const Duration(milliseconds: 1800), () {
        if (mounted) setState(() => _copied = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.tableRows.isEmpty) return const SizedBox.shrink();

    final maxCols = widget.tableRows.fold<int>(
      0,
      (max, row) => row.fields.length > max ? row.fields.length : max,
    );
    if (maxCols == 0) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Stack(
        children: [
          Scrollbar(
            controller: _scrollController,
            thumbVisibility: true,
            child: SingleChildScrollView(
              controller: _scrollController,
              scrollDirection: Axis.horizontal,
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: kBorder, width: 0.8),
                  borderRadius: BorderRadius.circular(8),
                ),
                clipBehavior: Clip.antiAlias,
                child: Table(
                  defaultColumnWidth: const IntrinsicColumnWidth(),
                  defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                  border: TableBorder(
                    horizontalInside: BorderSide(
                      color: kBorder.withValues(alpha: 0.5),
                      width: 0.5,
                    ),
                    verticalInside: BorderSide(
                      color: kBorder.withValues(alpha: 0.5),
                      width: 0.5,
                    ),
                  ),
                  children: widget.tableRows.map((row) {
                    return TableRow(
                      decoration: row.isHeader
                          ? const BoxDecoration(color: kInputBg)
                          : null,
                      children: List.generate(maxCols, (colIdx) {
                        final field =
                            colIdx < row.fields.length ? row.fields[colIdx] : null;
                        final text = field?.data.trim() ?? '';
                        final align = field?.alignment ?? TextAlign.left;

                        final cellStyle = widget.textStyle.copyWith(
                          fontWeight:
                              row.isHeader ? FontWeight.w600 : FontWeight.normal,
                          fontSize: 13,
                          height: 1.35,
                          color: row.isHeader
                              ? kText
                              : kText.withValues(alpha: 0.9),
                        );

                        Widget cellContent;
                        if (text.isEmpty) {
                          cellContent = const SizedBox(height: 20);
                        } else if (looksLikeMarkdown(text)) {
                          // Inline markdown (bold, italic, code, links) renders
                          // via a nested GptMarkdown only when the cell actually
                          // contains markup; plain cells stay cheap Text.
                          cellContent = GptMarkdown(
                            text,
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                            textAlign: align,
                            style: cellStyle,
                          );
                        } else {
                          cellContent = Text(
                            text,
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                            textAlign: align,
                            style: cellStyle,
                          );
                        }

                        final cellWidget = Container(
                          constraints: const BoxConstraints(
                            minWidth: 64,
                            maxWidth: 220,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          child: cellContent,
                        );

                        if (text.isNotEmpty) {
                          return Tooltip(
                            message: text.length > 300
                                ? '${text.substring(0, 300)}…'
                                : text,
                            waitDuration: const Duration(milliseconds: 600),
                            child: cellWidget,
                          );
                        }
                        return cellWidget;
                      }),
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
          // Viewport-pinned floating copy button: stays in top-right of visible container
          Positioned(
            top: 6,
            right: 6,
            child: Material(
              color: Colors.transparent,
              child: Tooltip(
                message: 'Copy table (rich text + TSV)',
                waitDuration: const Duration(milliseconds: 600),
                child: InkWell(
                  onTap: _copyTable,
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                  decoration: BoxDecoration(
                    color: kDarkBg.withValues(alpha: 0.88),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: _copied
                          ? Colors.greenAccent.withValues(alpha: 0.6)
                          : kBorder.withValues(alpha: 0.8),
                      width: 0.8,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 4,
                        offset: const Offset(0, 1),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _copied ? Icons.check_rounded : Icons.copy_rounded,
                        size: 13,
                        color: _copied ? Colors.greenAccent : kMuted,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _copied ? 'Copied' : 'Copy table',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: _copied ? Colors.greenAccent : kText,
                        ),
                      ),
                    ],
                  ),
                ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
