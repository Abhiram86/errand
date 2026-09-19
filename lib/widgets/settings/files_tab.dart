import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import '../../theme/app_colors.dart';

class FilesTab extends StatelessWidget {
  final List<String> localAttached;
  final bool picking;
  final VoidCallback onPickFiles;
  final ValueChanged<String> onDetachFile;

  const FilesTab({
    super.key,
    required this.localAttached,
    required this.picking,
    required this.onPickFiles,
    required this.onDetachFile,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              'Attached files (${localAttached.length})',
              style: const TextStyle(
                color: kText,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            FilledButton.tonal(
              onPressed: picking ? null : onPickFiles,
              style: FilledButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                minimumSize: const Size(0, 36),
              ),
              child: picking
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Attach', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'Visible to the model via attached_files / read. Paths outside /storage/emulated/0 are allowed for picked files.',
          style: TextStyle(color: kMuted, fontSize: 11),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: localAttached.isEmpty
              ? const Center(
                  child: Text(
                    'No files attached in this conversation.',
                    style: TextStyle(color: kMuted, fontSize: 12),
                  ),
                )
              : ListView.separated(
                  itemCount: localAttached.length,
                  separatorBuilder: (_, _) =>
                      const Divider(color: kBorder, height: 1),
                  itemBuilder: (context, i) {
                    final uri = localAttached[i];
                    return ListTile(
                      dense: true,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 4),
                      leading: const Icon(
                        Icons.insert_drive_file_outlined,
                        size: 18,
                        color: kMuted,
                      ),
                      title: Text(
                        path.basename(uri),
                        style: const TextStyle(color: kText, fontSize: 12),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        uri,
                        style:
                            const TextStyle(color: kMuted, fontSize: 10),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.close_rounded,
                            size: 16, color: kMuted),
                        onPressed: () => onDetachFile(uri),
                        tooltip: 'Remove',
                        visualDensity: VisualDensity.compact,
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
