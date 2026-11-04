import 'package:flutter/material.dart';

import '../core/theme.dart';

/// The W-fit logo glyph: a "W" drawn as two rising strokes.
/// Two-tone by default (theme aware); pass [color] for a single-colour mark.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 32, this.color, this.semanticLabel = 'W-fit'});

  final double size;
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final first = color ?? (dark ? const Color(0xFF3CC7AE) : BrandColors.tealDeep);
    final second = color ?? (dark ? const Color(0xFF7FE6D2) : BrandColors.tealBright);
    final mark = SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _MarkPainter(first, second)),
    );
    final label = semanticLabel;
    return label == null ? ExcludeSemantics(child: mark) : Semantics(label: label, image: true, child: mark);
  }
}

/// Mark + "W-fit" logotype, sized by [height].
class BrandWordmark extends StatelessWidget {
  const BrandWordmark({super.key, this.height = 28, this.color});

  final double height;

  /// Optional single colour for both mark and text (e.g. on a coloured background).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.titleLarge?.copyWith(
      fontSize: height * 0.8,
      height: 1,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.04 * height,
      color: color ?? theme.colorScheme.onSurface,
    );
    return Semantics(
      label: 'W-fit',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          BrandMark(size: height, color: color, semanticLabel: null),
          SizedBox(width: height * 0.3),
          Text.rich(
            TextSpan(text: 'W-', children: [
              TextSpan(text: 'fit', style: TextStyle(color: color ?? theme.colorScheme.primary)),
            ]),
            style: style,
          ),
        ],
      ),
    );
  }
}

// Geometry on a 64-unit grid; keep in sync with assets/brand/source/generate_brand.js.
const _points = [Offset(9, 22), Offset(20.5, 48), Offset(32, 30), Offset(43.5, 48), Offset(55, 16)];
const _stroke = 8.0;
const _seamX = 32.0;

class _MarkPainter extends CustomPainter {
  const _MarkPainter(this.first, this.second);

  final Color first;
  final Color second;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide / 64;
    canvas.translate((size.width - 64 * s) / 2, (size.height - 64 * s) / 2);
    canvas.scale(s);
    final path = Path()..moveTo(_points.first.dx, _points.first.dy);
    for (final p in _points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    Paint paint(Color c) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    canvas.drawPath(path, paint(second));
    if (first != second) {
      canvas.save();
      canvas.clipRect(const Rect.fromLTWH(0, 0, _seamX, 64));
      canvas.drawPath(path, paint(first));
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.first != first || old.second != second;
}
