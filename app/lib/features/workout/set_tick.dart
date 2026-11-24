import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Logs or un-logs something: an outlined circle until it is done, then filled.
class SetTick extends StatelessWidget {
  const SetTick({super.key, required this.label, required this.done, required this.onPressed});

  /// What a tap does, for the tooltip and screen readers.
  final String label;
  final bool done;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return SizedBox(
      width: Gap.tap,
      child: IconButton(
        tooltip: label,
        style: IconButton.styleFrom(
          backgroundColor: done ? s.primary : Colors.transparent,
          foregroundColor: done ? s.onPrimary : s.primary,
          side: done ? null : BorderSide(color: s.outline, width: 1.5),
        ),
        onPressed: onPressed,
        icon: const Icon(Icons.check),
      ),
    );
  }
}
