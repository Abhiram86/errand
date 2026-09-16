import 'package:flutter/material.dart';

import '../models/app_update_info.dart';
import '../theme/app_colors.dart';

/// Floating pill widget centered below the model picker notifying user of an available OTA update.
class UpdateToast extends StatelessWidget {
  final AppUpdateInfo updateInfo;
  final bool isBusy;
  final double? downloadProgress;
  final VoidCallback onInstall;
  final VoidCallback onDismiss;

  const UpdateToast({
    super.key,
    required this.updateInfo,
    required this.isBusy,
    this.downloadProgress,
    required this.onInstall,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final isDownloading = downloadProgress != null;
    final isCached = updateInfo.isCachedApkValid;
    final version = updateInfo.latestVersion;

    final String statusText;
    if (isDownloading) {
      final pct = ((downloadProgress ?? 0.0) * 100).toInt();
      statusText = 'Downloading … $pct%';
    } else if (isCached) {
      statusText = 'Update ready • v$version';
    } else {
      statusText = 'New update • v$version';
    }

    return Center(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
        margin: const EdgeInsets.only(top: 2, bottom: 6),
        padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
        decoration: BoxDecoration(
          color: const Color(0xFF1E212B),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isCached
                ? Colors.green.withValues(alpha: 0.5)
                : kBorder.withValues(alpha: 0.9),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isDownloading)
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  value: downloadProgress,
                  strokeWidth: 2,
                  color: kBubbleUser,
                ),
              )
            else
              Icon(
                isCached
                    ? Icons.download_done_rounded
                    : Icons.system_update_rounded,
                size: 16,
                color: isCached ? Colors.greenAccent : kText,
              ),
            const SizedBox(width: 8),
            Text(
              statusText,
              style: const TextStyle(
                color: kText,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(width: 10),
            // Install button: disabled when chat is busy or already downloading
            FilledButton(
              onPressed: (isBusy || isDownloading) ? null : onInstall,
              style: FilledButton.styleFrom(
                backgroundColor: kBubbleUser,
                disabledBackgroundColor: kBubbleAssistant,
                foregroundColor: Colors.white,
                disabledForegroundColor: kMuted,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: Text(
                isCached ? 'Install' : 'Update',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              onPressed: onDismiss,
              tooltip: 'Dismiss update',
              icon: const Icon(Icons.close_rounded, size: 16, color: kMuted),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }
}
