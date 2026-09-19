import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

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

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
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
      child: Scrollbar(
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
    );
  }
}
