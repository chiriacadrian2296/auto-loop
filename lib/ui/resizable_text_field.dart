import 'package:flutter/material.dart';

import '../l10n.dart';
import 'app_theme.dart';

class ResizableTextField extends StatefulWidget {
  const ResizableTextField({
    super.key,
    required this.initialValue,
    required this.onChanged,
    required this.minHeight,
    required this.style,
    required this.decoration,
  });
  final String initialValue;
  final ValueChanged<String> onChanged;
  final double minHeight;
  final TextStyle style;
  final InputDecoration decoration;

  @override
  State<ResizableTextField> createState() => _ResizableTextFieldState();
}

class _ResizableTextFieldState extends State<ResizableTextField> {
  late final _controller = TextEditingController(text: widget.initialValue);
  late double _height = widget.minHeight;
  bool _restored = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_restored) {
      final saved = PageStorage.maybeOf(context)?.readState(context, identifier: widget.key);
      if (saved is double) _height = saved.clamp(widget.minHeight, double.infinity);
      _restored = true;
    }
  }

  @override
  void didUpdateWidget(ResizableTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialValue != widget.initialValue && _controller.text != widget.initialValue) {
      _controller.text = widget.initialValue;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: _height,
    child: Stack(
      children: [
        Positioned.fill(
          child: TextFormField(
            controller: _controller,
            expands: true,
            minLines: null,
            maxLines: null,
            textAlignVertical: TextAlignVertical.top,
            style: widget.style,
            decoration: widget.decoration.copyWith(contentPadding: const EdgeInsets.fromLTRB(12, 11, 26, 18)),
            onChanged: widget.onChanged,
          ),
        ),
        Positioned(
          right: 2,
          bottom: 2,
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeUpDown,
            child: GestureDetector(
              key: const ValueKey('resize-text-field'),
              behavior: HitTestBehavior.opaque,
              onVerticalDragUpdate: (details) {
                setState(() => _height = (_height + details.delta.dy).clamp(widget.minHeight, double.infinity));
                PageStorage.maybeOf(context)?.writeState(context, _height, identifier: widget.key);
              },
              child: Tooltip(
                message: tr('Trascina per ridimensionare', 'Drag to resize'),
                child: SizedBox(
                  width: 24,
                  height: 20,
                  child: Icon(Icons.drag_handle_rounded, size: 16, color: context.colors.muted),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
