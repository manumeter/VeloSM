import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../models/poi.dart';
import '../models/tour.dart';
import 'geo.dart';

/// A point on the route, as found by [RouteTrack.match].
class RouteMatch {
  /// Index of the segment start point in [RouteTrack.points].
  final int segment;

  /// Fraction along the segment.
  final double t;

  /// Distance from the route start in meters.
  final double along;

  /// Distance between the query point and the route in meters.
  final double offset;

  const RouteMatch(this.segment, this.t, this.along, this.offset);
}

/// A turn hint positioned on the flattened route.
class RouteHint {
  final double along;
  final int command;
  final int exit;

  const RouteHint(this.along, this.command, this.exit);
}

/// The whole tour flattened into one polyline, with cumulative distances
/// and a grid index so that GPS fixes and POIs can be matched quickly even
/// for routes with hundreds of thousands of points.
class RouteTrack {
  final List<LatLng> points;

  /// Elevation per point (NaN where unknown).
  final List<double> elevations;

  /// Cumulative distance from the start, per point.
  final List<double> cumulative;

  /// Index into [points] where each leg starts.
  final List<int> legStarts;
  final List<RouteHint> hints;

  static const double _cellDeg = 0.02;
  static const double _maxSegment = 1000;
  final Map<int, List<int>> _grid = {};

  RouteTrack._(this.points, this.elevations, this.cumulative, this.legStarts,
      this.hints) {
    for (var i = 0; i + 1 < points.length; i++) {
      final a = points[i], b = points[i + 1];
      final y0 = _cy(math.min(a.latitude, b.latitude));
      final y1 = _cy(math.max(a.latitude, b.latitude));
      final x0 = _cx(math.min(a.longitude, b.longitude));
      final x1 = _cx(math.max(a.longitude, b.longitude));
      for (var y = y0; y <= y1; y++) {
        for (var x = x0; x <= x1; x++) {
          (_grid[_key(x, y)] ??= []).add(i);
        }
      }
    }
  }

  /// Builds the track from the tour's legs (missing legs become straight
  /// lines). Long segments are densified so the grid stays effective.
  factory RouteTrack.fromTour(Tour tour) {
    final legs = <Leg>[
      for (var i = 0; i < tour.legs.length; i++)
        tour.legs[i] ??
            Leg.straight(tour.waypoints[i].position, tour.waypoints[i + 1].position),
    ];
    return RouteTrack.fromLegs(legs);
  }

  factory RouteTrack.fromLegs(List<Leg> legs) {
    final pts = <LatLng>[];
    final ele = <double>[];
    final cum = <double>[];
    final starts = <int>[];
    final hintRefs = <(int, TurnHint)>[];
    for (final leg in legs) {
      if (leg.points.isEmpty) continue;
      final skipFirst = pts.isNotEmpty && haversine(pts.last, leg.points.first) < 1;
      starts.add(skipFirst ? pts.length - 1 : pts.length);
      final indexMap = List<int>.filled(leg.points.length, 0);
      for (var i = 0; i < leg.points.length; i++) {
        if (i == 0 && skipFirst) {
          indexMap[0] = pts.length - 1;
          continue;
        }
        final p = leg.points[i];
        final e = leg.hasElevation ? leg.elevations[i] : double.nan;
        if (pts.isNotEmpty) {
          final d = haversine(pts.last, p);
          if (d > _maxSegment) {
            final n = (d / _maxSegment).ceil();
            final a = pts.last, ea = ele.last, ca = cum.last;
            for (var k = 1; k < n; k++) {
              pts.add(lerpLatLng(a, p, k / n));
              ele.add(ea.isNaN || e.isNaN ? double.nan : ea + (e - ea) * k / n);
              cum.add(ca + d * k / n);
            }
          }
          cum.add(cum.last + haversine(pts.last, p));
        } else {
          cum.add(0);
        }
        pts.add(p);
        ele.add(e);
        indexMap[i] = pts.length - 1;
      }
      for (final h in leg.hints) {
        if (h.index >= 0 && h.index < indexMap.length) {
          hintRefs.add((indexMap[h.index], h));
        }
      }
    }
    final hints = [
      for (final (idx, h) in hintRefs) RouteHint(cum[idx], h.command, h.exit),
    ];
    return RouteTrack._(pts, ele, cum, starts, hints);
  }

  double get length => cumulative.isEmpty ? 0 : cumulative.last;

  bool get isEmpty => points.length < 2;

  static int _cx(double lon) => ((lon + 180) / _cellDeg).floor();
  static int _cy(double lat) => ((lat + 90) / _cellDeg).floor();
  static int _key(int x, int y) => y * 20000 + x;

  /// Position at distance [along] from the start.
  LatLng pointAt(double along) {
    if (points.isEmpty) throw StateError('empty track');
    final i = _indexAt(along);
    if (i >= points.length - 1) return points.last;
    final segLen = cumulative[i + 1] - cumulative[i];
    final t = segLen <= 0 ? 0.0 : (along - cumulative[i]) / segLen;
    return lerpLatLng(points[i], points[i + 1], t.clamp(0, 1));
  }

  /// Elevation at [along], or NaN.
  double elevationAt(double along) {
    final i = _indexAt(along);
    return elevations[math.min(i, elevations.length - 1)];
  }

  /// Index of the segment containing [along].
  int _indexAt(double along) {
    var lo = 0, hi = cumulative.length - 1;
    if (along <= 0) return 0;
    if (along >= cumulative[hi]) return hi;
    while (lo < hi - 1) {
      final mid = (lo + hi) >> 1;
      if (cumulative[mid] <= along) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  RouteMatch _projectSegment(LatLng p, int i) {
    final pr = projectOnSegment(p, points[i], points[i + 1]);
    final along = cumulative[i] + (cumulative[i + 1] - cumulative[i]) * pr.t;
    return RouteMatch(i, pr.t, along, pr.distance);
  }

  Iterable<int> _segmentsNear(LatLng p, double radius) sync* {
    final dLat = radius / earthRadiusM * 180 / math.pi;
    final dLon = dLat / math.max(0.01, math.cos(p.latitude * math.pi / 180));
    final y0 = _cy(p.latitude - dLat), y1 = _cy(p.latitude + dLat);
    final x0 = _cx(p.longitude - dLon), x1 = _cx(p.longitude + dLon);
    final seen = <int>{};
    for (var y = y0; y <= y1; y++) {
      for (var x = x0; x <= x1; x++) {
        final cell = _grid[_key(x, y)];
        if (cell == null) continue;
        for (final s in cell) {
          if (seen.add(s)) yield s;
        }
      }
    }
  }

  /// Closest route point to [p] within [radius] meters, or null.
  RouteMatch? nearest(LatLng p, {double radius = 2000}) {
    RouteMatch? best;
    for (final s in _segmentsNear(p, radius)) {
      final m = _projectSegment(p, s);
      if (m.offset <= radius && (best == null || m.offset < best.offset)) {
        best = m;
      }
    }
    return best;
  }

  /// All distinct passes of the route near [p] (a route that visits the same
  /// town twice yields two matches), each the closest point of its pass.
  List<RouteMatch> passesNear(LatLng p, double radius) {
    final candidates = <RouteMatch>[
      for (final s in _segmentsNear(p, radius)) _projectSegment(p, s),
    ]..retainWhere((m) => m.offset <= radius);
    if (candidates.isEmpty) return const [];
    candidates.sort((a, b) => a.along.compareTo(b.along));
    // Segments belong to the same pass when they are contiguous along the
    // route (gap smaller than the corridor could explain).
    final gap = math.max(4 * radius, 2000.0);
    final out = <RouteMatch>[];
    var best = candidates.first;
    var lastAlong = best.along;
    for (final m in candidates.skip(1)) {
      if (m.along - lastAlong > gap) {
        out.add(best);
        best = m;
      } else if (m.offset < best.offset) {
        best = m;
      }
      lastAlong = m.along;
    }
    out.add(best);
    return out;
  }

  /// Matches a GPS fix, preferring the stretch around the previous match so
  /// that overlapping out-and-back sections don't make the position jump.
  RouteMatch? match(LatLng p, {RouteMatch? previous, double radius = 3000}) {
    if (isEmpty) return null;
    if (previous != null) {
      RouteMatch? local;
      final from = math.max(0, previous.segment - 20);
      final to = math.min(points.length - 2, previous.segment + 400);
      for (var i = from; i <= to; i++) {
        final m = _projectSegment(p, i);
        if (local == null || m.offset < local.offset) local = m;
      }
      if (local != null && local.offset < 60) return local;
    }
    return nearest(p, radius: radius);
  }

  /// Positions [pois] along the route. Each POI yields one entry per pass of
  /// the route within its category radius (scaled by [radiusFactor]).
  List<PoiOnRoute> placePois(Iterable<Poi> pois, {double radiusFactor = 1}) {
    final out = <PoiOnRoute>[];
    for (final poi in pois) {
      final r = poi.cat.radius * radiusFactor;
      for (final m in passesNear(poi.position, r)) {
        out.add(PoiOnRoute(poi, m.along, m.offset));
      }
    }
    out.sort((a, b) => a.along.compareTo(b.along));
    return out;
  }

  /// The next turn hint after [along], if any.
  RouteHint? nextHint(double along) {
    var lo = 0, hi = hints.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (hints[mid].along <= along + 5) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo < hints.length ? hints[lo] : null;
  }

  /// Remaining ascent between two distances.
  double ascentBetween(double from, double to) {
    final i0 = _indexAt(from), i1 = _indexAt(to);
    if (i1 <= i0) return 0;
    return elevationGain(elevations.sublist(i0, i1 + 1)).ascent;
  }

  /// Splits the route into consecutive windows of [chunkLength] meters and
  /// returns the bounding box of each (used for POI downloads).
  List<GeoBounds> chunkBounds(double chunkLength) {
    final out = <GeoBounds>[];
    if (isEmpty) return out;
    GeoBounds? cur;
    var chunkEnd = chunkLength;
    for (var i = 0; i < points.length; i++) {
      cur == null ? cur = GeoBounds.of([points[i]]) : cur.extend(points[i]);
      if (cumulative[i] >= chunkEnd && i < points.length - 1) {
        out.add(cur);
        cur = GeoBounds.of([points[i]]);
        while (chunkEnd <= cumulative[i]) {
          chunkEnd += chunkLength;
        }
      }
    }
    if (cur != null) out.add(cur);
    return out;
  }

  /// Downsampled (distance, elevation) series for profile charts.
  List<(double, double)> profile({double from = 0, double? to, int samples = 400}) {
    final end = to ?? length;
    if (end <= from) return const [];
    final out = <(double, double)>[];
    for (var k = 0; k <= samples; k++) {
      final d = from + (end - from) * k / samples;
      final e = elevationAt(d);
      if (!e.isNaN) out.add((d, e));
    }
    return out;
  }
}

/// Ramer–Douglas–Peucker simplification (iterative; safe for huge tracks).
/// Returns the indices of the points to keep.
List<int> simplifyIndices(List<LatLng> pts, double tolerance) {
  final n = pts.length;
  if (n < 3) return List.generate(n, (i) => i);
  final keep = List<bool>.filled(n, false);
  keep[0] = keep[n - 1] = true;
  final stack = <(int, int)>[(0, n - 1)];
  while (stack.isNotEmpty) {
    final (a, b) = stack.removeLast();
    var maxD = -1.0;
    var idx = -1;
    for (var i = a + 1; i < b; i++) {
      final d = projectOnSegment(pts[i], pts[a], pts[b]).distance;
      if (d > maxD) {
        maxD = d;
        idx = i;
      }
    }
    if (idx >= 0 && maxD > tolerance) {
      keep[idx] = true;
      stack.add((a, idx));
      stack.add((idx, b));
    }
  }
  return [for (var i = 0; i < n; i++) if (keep[i]) i];
}
