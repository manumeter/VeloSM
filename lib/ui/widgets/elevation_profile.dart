import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Elevation chart over distance, with optional markers (e.g. current
/// position, overnight stops).
class ElevationProfile extends StatelessWidget {
  /// (distance in m, elevation in m)
  final List<(double, double)> data;
  final double? marker;
  final List<double> dividers;
  final double height;

  const ElevationProfile({
    super.key,
    required this.data,
    this.marker,
    this.dividers = const [],
    this.height = 140,
  });

  @override
  Widget build(BuildContext context) {
    if (data.length < 2) {
      return SizedBox(
        height: height,
        child: const Center(child: Text('No elevation data for this section.')),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: _ProfilePainter(
          data,
          marker,
          dividers,
          fill: scheme.primary.withValues(alpha: 0.25),
          line: scheme.primary,
          text: Theme.of(context).textTheme.bodySmall!,
          markerColor: scheme.error,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _ProfilePainter extends CustomPainter {
  final List<(double, double)> data;
  final double? marker;
  final List<double> dividers;
  final Color fill, line, markerColor;
  final TextStyle text;

  _ProfilePainter(this.data, this.marker, this.dividers,
      {required this.fill, required this.line, required this.text, required this.markerColor});

  @override
  void paint(Canvas canvas, Size size) {
    const left = 40.0, bottom = 18.0, top = 6.0;
    final w = size.width - left - 4;
    final h = size.height - bottom - top;
    final d0 = data.first.$1, d1 = data.last.$1;
    var eMin = data.map((e) => e.$2).reduce(math.min);
    var eMax = data.map((e) => e.$2).reduce(math.max);
    if (eMax - eMin < 50) {
      final mid = (eMax + eMin) / 2;
      eMin = mid - 25;
      eMax = mid + 25;
    }
    double x(double d) => left + (d - d0) / (d1 - d0) * w;
    double y(double e) => top + h - (e - eMin) / (eMax - eMin) * h;

    final path = Path()..moveTo(x(data.first.$1), y(data.first.$2));
    for (final p in data.skip(1)) {
      path.lineTo(x(p.$1), y(p.$2));
    }
    final area = Path.from(path)
      ..lineTo(x(d1), top + h)
      ..lineTo(x(d0), top + h)
      ..close();
    canvas.drawPath(area, Paint()..color = fill);
    canvas.drawPath(
        path,
        Paint()
          ..color = line
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);

    final grid = Paint()
      ..color = text.color!.withValues(alpha: 0.3)
      ..strokeWidth = 1;
    for (final d in dividers) {
      if (d <= d0 || d >= d1) continue;
      canvas.drawLine(Offset(x(d), top), Offset(x(d), top + h), grid);
    }
    void label(String s, Offset o, {bool right = false}) {
      final tp = TextPainter(text: TextSpan(text: s, style: text), textDirection: TextDirection.ltr)
        ..layout();
      tp.paint(canvas, right ? o - Offset(tp.width, 0) : o);
    }

    label('${eMax.round()} m', Offset(left - 4, top - 2), right: true);
    label('${eMin.round()} m', Offset(left - 4, top + h - 12), right: true);
    label('${(d0 / 1000).toStringAsFixed(0)} km', Offset(left, top + h + 2));
    label('${(d1 / 1000).toStringAsFixed(0)} km', Offset(size.width - 4, top + h + 2), right: true);

    if (marker != null && marker! >= d0 && marker! <= d1) {
      final mx = x(marker!);
      canvas.drawLine(
          Offset(mx, top),
          Offset(mx, top + h),
          Paint()
            ..color = markerColor
            ..strokeWidth = 2);
    }
  }

  @override
  bool shouldRepaint(_ProfilePainter old) =>
      old.data != data || old.marker != marker || old.dividers != dividers;
}
