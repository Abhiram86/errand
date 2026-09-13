import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import '../theme/app_colors.dart';

/// Renders a banner showing pending file attachments with options to detach them.
class PendingAttachmentsBanner extends StatelessWidget {
  final List<String> uris;
  final ValueChanged<String> onDetach;

  const PendingAttachmentsBanner({
    super.key,
    required this.uris,
    required this.onDetach,
  });

  @override
  Widget build(BuildContext context) {
    if (uris.isEmpty) return const SizedBox.shrink();

    return Material(
      color: kInputBg,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
        decoration: BoxDecoration(
          color: kDarkBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kBorder),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.attach_file_rounded, size: 13, color: kMuted),
                const SizedBox(width: 6),
                const Text(
                  'Attached — will send with next message',
                  style: TextStyle(color: kMuted, fontSize: 11),
                ),
                const Spacer(),
                Text(
                  '${uris.length}',
                  style: const TextStyle(color: kMuted, fontSize: 11),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < uris.length; i++)
              Padding(
                padding: EdgeInsets.only(bottom: i == uris.length - 1 ? 0 : 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${i + 1}. ${path.basename(uris[i])}',
                        style: const TextStyle(color: kText, fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    InkWell(
                      onTap: () => onDetach(uris[i]),
                      borderRadius: BorderRadius.circular(10),
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(Icons.close_rounded, size: 14, color: kMuted),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
