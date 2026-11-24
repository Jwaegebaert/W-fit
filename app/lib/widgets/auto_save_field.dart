import 'dart:async';

import 'package:flutter/material.dart';

/// Text field that saves itself shortly after typing stops, when it loses focus and when its page closes.
class AutoSaveField extends StatefulWidget {
  const AutoSaveField({
    super.key,
    required this.label,
    required this.value,
    required this.onSave,
    this.maxLines = 1,
    this.number = false,
    this.helper,
  });

  final String label;

  /// Stored text when the field is first shown.
  final String value;
  final ValueChanged<String> onSave;
  final int maxLines;
  final bool number;
  final String? helper;

  @override
  State<AutoSaveField> createState() => _AutoSaveFieldState();
}

class _AutoSaveFieldState extends State<AutoSaveField> {
  late final _controller = TextEditingController(text: widget.value);
  late String _saved = widget.value.trim();
  Timer? _timer;

  void _typed() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 700), _flush);
  }

  void _flush() {
    _timer?.cancel();
    final text = _controller.text.trim();
    if (text == _saved) return;
    _saved = text;
    widget.onSave(text);
  }

  @override
  void dispose() {
    _flush();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
        skipTraversal: true,
        onFocusChange: (on) {
          if (!on) _flush();
        },
        child: TextField(
          controller: _controller,
          minLines: 1,
          maxLines: widget.maxLines,
          keyboardType: widget.number ? TextInputType.number : null,
          decoration: InputDecoration(labelText: widget.label, helperText: widget.helper, helperMaxLines: 2),
          onChanged: (_) => _typed(),
        ),
      );
}
