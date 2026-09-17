import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

enum SheetOptionType {
  normal,
  destructive,
}

class SheetOption {
  final String title;
  final IconData icon;
  final SheetOptionType type;
  final VoidCallback onTap;
  final Color? color;
  final Color? iconColor;

  const SheetOption({
    required this.title,
    required this.icon,
    this.type = SheetOptionType.normal,
    required this.onTap,
    this.color,
    this.iconColor,
  });
}

class OptionsModalSheet extends StatelessWidget {
  final String? title;
  final String? subtitle;
  final List<SheetOption> options;

  const OptionsModalSheet({
    super.key,
    this.title,
    this.subtitle,
    required this.options,
  });

  @override
  Widget build(BuildContext context) {
    final hasTitle = title != null && title!.trim().isNotEmpty;
    final hasSubtitle = subtitle != null && subtitle!.trim().isNotEmpty;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, hasTitle ? 18 : 14, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (hasTitle) ...[
              Text(
                title!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: kText,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (hasSubtitle) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle!,
                  style: const TextStyle(
                    color: kMuted,
                    fontSize: 13,
                  ),
                ),
              ],
              const SizedBox(height: 8),
            ],
            ...options.map(
              (option) {
                final isDestructive = option.type == SheetOptionType.destructive;
                final itemColor = isDestructive
                    ? kDanger
                    : (option.color ?? kMuted);
                final itemIconColor = isDestructive
                    ? kDanger
                    : (option.iconColor ?? option.color ?? kMuted);

                return ListTile(
                  dense: true,
                  visualDensity: const VisualDensity(vertical: -3),
                  contentPadding: EdgeInsets.zero,
                  minVerticalPadding: 0,
                  leading: Icon(
                    option.icon,
                    color: itemIconColor,
                    size: 18,
                  ),
                  title: Text(
                    option.title,
                    style: TextStyle(
                      color: itemColor,
                      fontSize: 14,
                    ),
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  onTap: () {
                    Navigator.of(context).pop();
                    option.onTap();
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

Future<T?> showOptionsModalSheet<T>(
  BuildContext context, {
  String? title,
  String? subtitle,
  required List<SheetOption> options,
}) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: kInputBg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(24),
      ),
    ),
    builder: (sheetContext) => OptionsModalSheet(
      title: title,
      subtitle: subtitle,
      options: options,
    ),
  );
}
