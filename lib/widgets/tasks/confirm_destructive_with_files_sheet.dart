import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../services/task_scheduler_service.dart';
import '../../theme/app_colors.dart';
import '../../utils/format.dart';
import '../../screens/task_file_preview_screen.dart';

/// A file plus its size, measured once up front.
///
/// The sizes are resolved by the caller before showing the dialog. Resolving
/// them inside the list's `itemBuilder` meant two synchronous `stat` syscalls
/// per row, on the UI isolate, re-running on every checkbox toggle because
/// toggling rebuilds the dialog.
typedef SizedFile = ({File file, int bytes, String displayPath});

/// Builds the `[SizedFile, …]` list for [files], best-effort.
///
/// A file that cannot be stat'ed (already deleted, permission denied) still
/// appears in the list with size 0 rather than vanishing — the point of the
/// dialog is to show the user exactly what they are about to delete.
List<SizedFile> measureFiles(Iterable<File> files) {
  final result = <SizedFile>[];
  for (final f in files) {
    var bytes = 0;
    try {
      if (f.existsSync()) bytes = f.lengthSync();
    } catch (_) {}
    result.add((
      file: f,
      bytes: bytes,
      displayPath: TaskSchedulerService.toScratchRelative(f.path),
    ));
  }
  return result;
}

/// Total byte size across [files], skipping any that cannot be stat'ed.
int totalBytesOf(Iterable<SizedFile> files) =>
    files.fold<int>(0, (sum, f) => sum + f.bytes);

/// Confirmation dialog for a destructive action that also owns report files.
///
/// Shared by "Delete Task?" and "Clear Logs & Files?" — the two were
/// byte-identical ~140-line dialogs differing only in their strings and the
/// styling of each file row. Keeping one implementation means the two flows
/// cannot drift apart, and it hoists the per-row disk IO out of `build`.
///
/// [deleteFiles] is returned as the second element of the result so the caller
/// can act on the user's choice. The checkbox defaults to on when there are
/// files to delete, matching the previous behaviour.
Future<({bool confirmed, bool deleteFiles})?> showDestructiveWithFilesDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  required List<SizedFile> files,
  required String checkboxLabel,
  double listMaxHeight = 160,
  IconData Function(String displayPath)? iconForPath,
  bool tapToPreview = false,
}) {
  var deleteFiles = files.isNotEmpty;
  var filesExpanded = false;

  return showDialog<({bool confirmed, bool deleteFiles})>(
    context: context,
    builder: (dialogCtx) {
      return StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1E222B),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            title: Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  message,
                  style: const TextStyle(color: Color(0xFFC9D1D9), fontSize: 14),
                ),
                if (files.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF161B22),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF30363D)),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Checkbox(
                              value: deleteFiles,
                              onChanged: (val) =>
                                  setDialogState(() => deleteFiles = val ?? false),
                              activeColor: kBubbleUser,
                            ),
                            Expanded(
                              child: InkWell(
                                onTap: () => setDialogState(
                                  () => deleteFiles = !deleteFiles,
                                ),
                                borderRadius: BorderRadius.circular(4),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 4),
                                  child: Text(
                                    checkboxLabel,
                                    style: const TextStyle(
                                      color: Color(0xFFE6EDF3),
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            InkWell(
                              onTap: () =>
                                  setDialogState(() => filesExpanded = !filesExpanded),
                              borderRadius: BorderRadius.circular(12),
                              child: Padding(
                                padding: const EdgeInsets.all(6),
                                child: Icon(
                                  filesExpanded
                                      ? Icons.expand_less_rounded
                                      : Icons.expand_more_rounded,
                                  color: const Color(0xFF8B949E),
                                  size: 18,
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (filesExpanded) ...[
                          const Divider(height: 1, color: Color(0xFF30363D)),
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight: listMaxHeight,
                            ),
                            child: Scrollbar(
                              child: ListView.separated(
                                shrinkWrap: true,
                                padding: const EdgeInsets.symmetric(vertical: 4),
                                itemCount: files.length,
                                separatorBuilder: (_, _) => const Divider(
                                  height: 1,
                                  color: Color(0xFF21262D),
                                ),
                                itemBuilder: (context, index) {
                                  final entry = files[index];
                                  final label = tapToPreview
                                      ? entry.displayPath
                                      : p.basename(entry.file.path);
                                  final sizeText =
                                      entry.bytes > 0 ? formatBytes(entry.bytes) : '';
                                  final row = Row(
                                    children: [
                                      if (iconForPath != null) ...[
                                        Icon(
                                          iconForPath(entry.displayPath),
                                          color: const Color(0xFF58A6FF),
                                          size: 14,
                                        ),
                                        const SizedBox(width: 8),
                                      ],
                                      Expanded(
                                        child: Text(
                                          label,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: tapToPreview
                                                ? const Color(0xFF58A6FF)
                                                : const Color(0xFF8B949E),
                                            fontSize: tapToPreview ? 12 : 11,
                                            fontFamily: tapToPreview
                                                ? null
                                                : 'monospace',
                                            decoration: tapToPreview
                                                ? TextDecoration.underline
                                                : null,
                                            decorationColor: const Color(0xFF58A6FF),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      if (sizeText.isNotEmpty)
                                        Text(
                                          sizeText,
                                          style: const TextStyle(
                                            color: Color(0xFF8B949E),
                                            fontSize: 11,
                                          ),
                                        ),
                                    ],
                                  );
                                  if (!tapToPreview) {
                                    return Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 3,
                                      ),
                                      child: row,
                                    );
                                  }
                                  return InkWell(
                                    onTap: () => TaskFilePreviewScreen.show(
                                      dialogCtx,
                                      filePath: entry.file.path,
                                      title: p.basename(entry.file.path),
                                    ),
                                    borderRadius: BorderRadius.circular(4),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 6,
                                        horizontal: 4,
                                      ),
                                      child: row,
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogCtx).pop(null),
                child: const Text(
                  'Cancel',
                  style: TextStyle(color: Color(0xFF8B949E)),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogCtx).pop((
                  confirmed: true,
                  deleteFiles: deleteFiles,
                )),
                child: Text(
                  confirmLabel,
                  style: const TextStyle(
                    color: kDanger,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          );
        },
      );
    },
  );
}
