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
  final VoidCallback? onTap;
  final Color? color;
  final Color? iconColor;

  const SheetOption({
    required this.title,
    required this.icon,
    this.type = SheetOptionType.normal,
    this.onTap,
    this.color,
    this.iconColor,
  });
}

class OptionsModalSheet extends StatelessWidget {
  final String? title;
  final String? subtitle;
  final List<SheetOption> options;
  final double maxHeightFactor;

  const OptionsModalSheet({
    super.key,
    this.title,
    this.subtitle,
    required this.options,
    this.maxHeightFactor = 0.75,
  });

  @override
  Widget build(BuildContext context) {
    final hasTitle = title != null && title!.trim().isNotEmpty;
    final hasSubtitle = subtitle != null && subtitle!.trim().isNotEmpty;
    final maxHeight = MediaQuery.sizeOf(context).height * maxHeightFactor;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color: kBorder.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              if (hasTitle) ...[
                Text(
                  title!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kText,
                    fontSize: 16,
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
                const SizedBox(height: 16),
              ],
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < options.length; i++) ...[
                        if (i > 0)
                          SizedBox(
                            height: (options[i].onTap == null &&
                                    options[i - 1].onTap == null)
                                ? 12
                                : 4,
                          ),
                        _buildOptionItem(context, options[i]),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOptionItem(BuildContext context, SheetOption option) {
    final isDestructive = option.type == SheetOptionType.destructive;
    final itemColor = isDestructive
        ? kDanger
        : (option.color ?? (option.onTap == null ? kText : kMuted));
    final itemIconColor = isDestructive
        ? kDanger
        : (option.iconColor ??
            option.color ??
            (option.onTap == null ? kBubbleUser : kMuted));

    final content = Padding(
      padding: EdgeInsets.symmetric(
        vertical: option.onTap != null ? 8 : 4,
        horizontal: option.onTap != null ? 8 : 2,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              option.icon,
              color: itemIconColor,
              size: 18,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              option.title,
              style: TextStyle(
                color: itemColor,
                fontSize: 14,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );

    if (option.onTap == null) {
      return content;
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          Navigator.of(context).pop();
          option.onTap!();
        },
        child: content,
      ),
    );
  }
}

Future<T?> showOptionsModalSheet<T>(
  BuildContext context, {
  String? title,
  String? subtitle,
  required List<SheetOption> options,
  bool isScrollControlled = false,
  double maxHeightFactor = 0.75,
}) {
  final screenHeight = MediaQuery.sizeOf(context).height;
  final maxHeight = screenHeight * maxHeightFactor;

  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: kInputBg,
    isScrollControlled: isScrollControlled,
    constraints: BoxConstraints(maxHeight: maxHeight),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(24),
      ),
    ),
    builder: (sheetContext) => OptionsModalSheet(
      title: title,
      subtitle: subtitle,
      options: options,
      maxHeightFactor: maxHeightFactor,
    ),
  );
}
