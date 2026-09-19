import 'package:flutter/material.dart';

import '../../tools/intent_tool.dart';
import '../../types/message.dart';

class ReopenButton extends StatelessWidget {
  final ToolMessage message;

  const ReopenButton({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () async {
        final messenger = ScaffoldMessenger.of(context);
        final outcome = await replayIntentAction(message.tool.args);
        if (outcome.startsWith('ERROR')) {
          messenger.showSnackBar(
            SnackBar(
              content: Text(outcome),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      },
      style: TextButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
        minimumSize: const Size(0, 24),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(Icons.open_in_new_rounded, size: 12),
          SizedBox(width: 3),
          Text(
            'Open',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
