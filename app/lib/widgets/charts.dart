import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

/// A minimal, theme-aware line chart. [labels] are shown under the first, middle and last point.
class TrendLineChart extends StatelessWidget {
  const TrendLineChart({
    super.key,
    required this.values,
    required this.labels,
    this.height = 180,
    this.color,
    this.unit = '',
    this.minYZero = false,
  });

  final List<double> values;
  final List<String> labels;
  final double height;
  final Color? color;
  final String unit;
  final bool minYZero;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = color ?? t.colorScheme.primary;
    if (values.isEmpty) return SizedBox(height: height, child: const Center(child: Text('No data yet')));
    final maxV = values.reduce((a, b) => a > b ? a : b);
    final minV = values.reduce((a, b) => a < b ? a : b);
    final pad = (maxV - minV).abs() < 0.001 ? (maxV == 0 ? 1 : maxV * 0.1) : (maxV - minV) * 0.15;
    final last = values.length - 1;
    final labelIdx = {0, last ~/ 2, last};

    return SizedBox(
      height: height,
      child: LineChart(
        LineChartData(
          minY: minYZero ? 0 : minV - pad,
          maxY: maxV + pad,
          gridData: FlGridData(
            drawVerticalLine: false,
            getDrawingHorizontalLine: (_) => FlLine(color: t.colorScheme.outlineVariant.withValues(alpha: 0.4), strokeWidth: 1),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 40,
                getTitlesWidget: (v, meta) => v == meta.max || v == meta.min
                    ? const SizedBox.shrink()
                    : Text(_compact(v), style: t.textTheme.labelSmall),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: 1,
                reservedSize: 24,
                getTitlesWidget: (v, meta) {
                  final i = v.toInt();
                  if (v != i || !labelIdx.contains(i) || i >= labels.length) return const SizedBox.shrink();
                  return Padding(padding: const EdgeInsets.only(top: 6), child: Text(labels[i], style: t.textTheme.labelSmall));
                },
              ),
            ),
          ),
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipItems: (spots) => [
                for (final s in spots)
                  LineTooltipItem(
                    '${labels[s.x.toInt()]}\n${_compact(s.y)}$unit',
                    TextStyle(color: t.colorScheme.onInverseSurface, fontWeight: FontWeight.w600),
                  ),
              ],
              getTooltipColor: (_) => t.colorScheme.inverseSurface,
            ),
          ),
          lineBarsData: [
            LineChartBarData(
              spots: [for (var i = 0; i < values.length; i++) FlSpot(i.toDouble(), values[i])],
              isCurved: true,
              preventCurveOverShooting: true,
              color: c,
              barWidth: 3,
              dotData: FlDotData(show: values.length <= 12),
              belowBarData: BarAreaData(
                show: true,
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [c.withValues(alpha: 0.25), c.withValues(alpha: 0.0)],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Weekly bar chart with an optional target line.
class WeeklyBarChart extends StatelessWidget {
  const WeeklyBarChart({super.key, required this.values, required this.labels, this.target, this.height = 160});

  final List<double> values;
  final List<String> labels;
  final double? target;
  final double height;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final maxV = [...values, target ?? 0].fold<double>(0, (a, b) => a > b ? a : b);
    return SizedBox(
      height: height,
      child: BarChart(
        BarChartData(
          maxY: maxV == 0 ? 1 : maxV * 1.2,
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(show: false),
          extraLinesData: target == null
              ? null
              : ExtraLinesData(horizontalLines: [
                  HorizontalLine(y: target!, color: t.colorScheme.tertiary, strokeWidth: 1.5, dashArray: [6, 4]),
                ]),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            leftTitles: const AxisTitles(),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 22,
                getTitlesWidget: (v, meta) {
                  final i = v.toInt();
                  if (i % 2 != (values.length - 1) % 2 || i >= labels.length) return const SizedBox.shrink();
                  return Padding(padding: const EdgeInsets.only(top: 4), child: Text(labels[i], style: t.textTheme.labelSmall));
                },
              ),
            ),
          ),
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipColor: (_) => t.colorScheme.inverseSurface,
              getTooltipItem: (g, _, rod, _) => BarTooltipItem(
                '${labels[g.x]}: ${_compact(rod.toY)}',
                TextStyle(color: t.colorScheme.onInverseSurface),
              ),
            ),
          ),
          barGroups: [
            for (var i = 0; i < values.length; i++)
              BarChartGroupData(x: i, barRods: [
                BarChartRodData(
                  toY: values[i],
                  width: 14,
                  borderRadius: BorderRadius.circular(6),
                  color: target != null && values[i] >= target! ? t.colorScheme.primary : t.colorScheme.primary.withValues(alpha: 0.45),
                ),
              ]),
          ],
        ),
      ),
    );
  }
}

String _compact(double v) {
  if (v.abs() >= 10000) return '${(v / 1000).toStringAsFixed(0)}k';
  if (v.abs() >= 1000) return '${(v / 1000).toStringAsFixed(1)}k';
  return v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
}
