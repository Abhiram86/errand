import 'package:flutter/material.dart';

import '../models/app_update_info.dart';
import '../services/app_info_service.dart';
import '../services/update_service.dart';
import '../theme/app_colors.dart';
import 'options_modal_sheet.dart';

/// Checks and displays release notes on first launch after an update or when forced.
Future<void> showReleaseNotesSheet(
  BuildContext context, {
  bool force = false,
}) async {
  try {
    List<String>? notes;
    String? versionName;
    if (force) {
      final cached = await UpdateService.instance.loadPersistedInfo();
      final platformInfo = await AppInfoService.instance.getAppInfo();
      versionName = platformInfo.versionName;
      String? body;
      if (cached != null &&
          AppUpdateInfo.compareSemver(
                cached.latestVersion,
                platformInfo.versionName,
              ) ==
              0) {
        body = cached.releaseNotes;
      }
      if (body == null || body.trim().isEmpty) {
        body = await UpdateService.instance.fetchReleaseNotes(
          platformInfo.versionName,
        );
      }
      if (body != null && body.trim().isNotEmpty) {
        notes = UpdateService.parseReleaseNotes(body);
      }
      notes ??= const [
        'Fixed OTA state after installation so the old install prompt does not return',
        'Update dismissal now lasts for the current app session',
        'Added a manual check for the latest release in the sidebar',
        'Added feedback for unavailable APKs and failed update attempts',
      ];
    } else {
      notes = await UpdateService.instance.checkFirstLaunchAfterUpdate();
      if (notes != null && notes.isNotEmpty) {
        final platformInfo = await AppInfoService.instance.getAppInfo();
        versionName = platformInfo.versionName;
      }
    }
    if (!context.mounted || notes == null || notes.isEmpty) return;

    await showOptionsModalSheet<void>(
      context,
      title: 'Release Notes',
      subtitle: versionName != null && versionName.isNotEmpty
          ? 'Version $versionName'
          : null,
      isScrollControlled: true,
      options: notes
          .map(
            (note) => SheetOption(
              title: note,
              icon: Icons.check_circle_outline_rounded,
              iconColor: kBubbleUser,
              onTap: null,
            ),
          )
          .toList(),
    );
  } catch (_) {}
}
