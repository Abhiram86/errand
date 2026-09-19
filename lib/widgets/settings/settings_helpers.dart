import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

InputDecoration settingsInputDecoration({required String hint}) {
  return InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(color: kSendDisabled, fontSize: 14),
    filled: true,
    fillColor: kInputBg,
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: kBorder),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: kBorder),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: kBubbleUser),
    ),
  );
}

Widget settingsStatusChip({required bool configured, String? label}) {
  final text = label ?? (configured ? 'configured' : 'not set');
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: configured ? kBubbleAssistant : kInputBg,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: kBorder),
    ),
    child: Text(
      text,
      style: TextStyle(
        color: configured ? kText : kMuted,
        fontSize: 10,
      ),
    ),
  );
}
