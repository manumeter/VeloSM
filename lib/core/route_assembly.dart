import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'geo.dart';

/// A chain of continuous line pieces (gaps between pieces are allowed).
typedef Unit = List<List<LatLng>>;

/// Assembles the member geometry of (super-)route relations into ordered,
/// continuous pieces. Real OSM data is messy, so besides chaining head to
/// tail this
///  * orients every sub-route as a whole (some are mapped backwards),
///  * drops small disconnected fragments (< 1 km),
///  * reorders members by proximity when their listed order has larger gaps.
class RouteAssembly {
  /// Pieces whose ends are closer than this are merged into one line.
  static const double mergeDistance = 50;

  /// Clusters of touching pieces shorter than this are treated as fragments.
  static const double fragmentLength = 1000;

  static Unit reversed(Unit u) => [for (final p in u.reversed) p.reversed.toList()];

  static double length(Unit u) {
    var d = 0.0;
    for (final p in u) {
      for (var i = 1; i < p.length; i++) {
        d += haversine(p[i - 1], p[i]);
      }
    }
    return d;
  }

  static double gap(Unit a, Unit b) {
    final ae = [a.first.first, a.last.last], be = [b.first.first, b.last.last];
    return [for (final x in ae) for (final y in be) haversine(x, y)].reduce(math.min);
  }

  /// Joins [units] in order (ways of one linear section), only orienting.
  static Unit chain(List<Unit> units) => _merge(oriented([for (final u in units) if (u.isNotEmpty) u]));

  /// Joins the members of a route relation, with fragment removal and
  /// proximity reordering.
  static Unit joinRoute(List<Unit> units) {
    var list = [for (final u in units) if (u.isNotEmpty) u];
    if (list.length > 1) {
      list = dropFragments(list);
      final listed = oriented(list);
      final greedy = greedyOrder(list);
      return _merge(totalGap(greedy) < totalGap(listed) ? greedy : listed);
    }
    return _merge(oriented(list));
  }

  /// Concatenates oriented units, merging pieces that touch.
  static Unit _merge(List<Unit> oriented) {
    final out = <List<LatLng>>[];
    for (final u in oriented) {
      for (final p in u) {
        if (out.isNotEmpty && haversine(out.last.last, p.first) < mergeDistance) {
          out.last.addAll(haversine(out.last.last, p.first) < 1 ? p.skip(1) : p);
        } else {
          out.add([...p]);
        }
      }
    }
    return out;
  }

  /// Orients each unit so that it starts where the previous one ended.
  static List<Unit> oriented(List<Unit> list) {
    final out = <Unit>[];
    for (var i = 0; i < list.length; i++) {
      var u = list[i];
      if (out.isEmpty) {
        if (i + 1 < list.length) {
          final next = list[i + 1];
          double near(LatLng p) =>
              math.min(haversine(p, next.first.first), haversine(p, next.last.last));
          if (near(u.first.first) < near(u.last.last)) u = reversed(u);
        }
      } else {
        final end = out.last.last.last;
        if (haversine(end, u.last.last) < haversine(end, u.first.first)) u = reversed(u);
      }
      out.add(u);
    }
    return out;
  }

  static double totalGap(List<Unit> oriented) {
    var g = 0.0;
    for (var i = 1; i < oriented.length; i++) {
      g += haversine(oriented[i - 1].last.last, oriented[i].first.first);
    }
    return g;
  }

  /// Starts with the first member and repeatedly appends the closest unused
  /// unit, oriented towards the current end.
  static List<Unit> greedyOrder(List<Unit> list) {
    final out = [oriented(list.take(2).toList()).first];
    final rest = list.sublist(1);
    while (rest.isNotEmpty) {
      final end = out.last.last.last;
      var best = 0;
      var bestGap = double.infinity;
      var reverse = false;
      for (var k = 0; k < rest.length; k++) {
        final dHead = haversine(end, rest[k].first.first);
        final dTail = haversine(end, rest[k].last.last);
        if (dHead < bestGap) {
          bestGap = dHead;
          best = k;
          reverse = false;
        }
        if (dTail < bestGap) {
          bestGap = dTail;
          best = k;
          reverse = true;
        }
      }
      final u = rest.removeAt(best);
      out.add(reverse ? reversed(u) : u);
    }
    return out;
  }

  /// Removes clusters of touching units whose total length is below
  /// [fragmentLength], unless nothing else would remain.
  static List<Unit> dropFragments(List<Unit> list) {
    final n = list.length;
    final parent = List<int>.generate(n, (i) => i);
    int find(int i) => parent[i] == i ? i : parent[i] = find(parent[i]);
    for (var i = 0; i < n; i++) {
      for (var k = i + 1; k < n; k++) {
        if (gap(list[i], list[k]) < mergeDistance) parent[find(i)] = find(k);
      }
    }
    final size = <int, double>{};
    for (var i = 0; i < n; i++) {
      size[find(i)] = (size[find(i)] ?? 0) + length(list[i]);
    }
    final kept = [
      for (var i = 0; i < n; i++)
        if (size[find(i)]! >= fragmentLength) list[i],
    ];
    return kept.isEmpty ? list : kept;
  }
}

/// Picks one continuous way through route pieces that contain parallel
/// alternatives (e.g. EuroVelo 6 is mapped on both banks of the Danube).
///
/// Pieces are split where other pieces join them; the resulting segments
/// form a graph whose nodes are segment ends. Unmapped gaps can be crossed
/// at a high cost (so mapped route is always preferred), then the cheapest
/// path from [start] to [end] is taken.
class RoutePathFinder {
  /// Distance within which a piece end counts as joining another piece.
  static const double junctionDistance = 100;

  /// Crossing an unmapped gap costs this many times its straight length.
  static const double gapPenalty = 10;

  static List<List<LatLng>> bestPath(List<List<LatLng>> pieces, LatLng start, LatLng end) {
    pieces = [for (final p in pieces) if (p.length >= 2) p];
    if (pieces.length < 2) return pieces;

    // 1. Split pieces at vertices close to the ends of other pieces.
    final grid = <int, List<(int, int)>>{};
    int key(LatLng p) => ((p.latitude + 90) / 0.002).floor() * 400000 + ((p.longitude + 180) / 0.002).floor();
    for (var i = 0; i < pieces.length; i++) {
      for (var v = 0; v < pieces[i].length; v++) {
        (grid[key(pieces[i][v])] ??= []).add((i, v));
      }
    }
    final splits = [for (final p in pieces) <int>{0, p.length - 1}];
    for (var j = 0; j < pieces.length; j++) {
      for (final e in [pieces[j].first, pieces[j].last]) {
        final best = <int, (int, double)>{};
        final kLat = ((e.latitude + 90) / 0.002).floor();
        final kLon = ((e.longitude + 180) / 0.002).floor();
        for (var dy = -1; dy <= 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            for (final (i, v) in grid[(kLat + dy) * 400000 + kLon + dx] ?? const <(int, int)>[]) {
              if (i == j) continue;
              final d = haversine(e, pieces[i][v]);
              if (d <= junctionDistance && (best[i] == null || d < best[i]!.$2)) best[i] = (v, d);
            }
          }
        }
        for (final b in best.entries) {
          splits[b.key].add(b.value.$1);
        }
      }
    }
    final segments = <List<LatLng>>[];
    for (var i = 0; i < pieces.length; i++) {
      final idx = splits[i].toList()..sort();
      for (var k = 1; k < idx.length; k++) {
        if (idx[k] > idx[k - 1]) segments.add(pieces[i].sublist(idx[k - 1], idx[k] + 1));
      }
    }

    // 2. Nodes: segment ends, merged when within the junction distance.
    final nodes = <LatLng>[];
    final nodeGrid = <int, List<int>>{};
    int nodeOf(LatLng p) {
      final kLat = ((p.latitude + 90) / 0.002).floor();
      final kLon = ((p.longitude + 180) / 0.002).floor();
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          for (final n in nodeGrid[(kLat + dy) * 400000 + kLon + dx] ?? const <int>[]) {
            if (haversine(nodes[n], p) <= junctionDistance) return n;
          }
        }
      }
      nodes.add(p);
      (nodeGrid[kLat * 400000 + kLon] ??= []).add(nodes.length - 1);
      return nodes.length - 1;
    }

    final edges = <int, List<(int, int, bool)>>{}; // node -> (other, segment, forward)
    final segLen = <double>[];
    for (var s = 0; s < segments.length; s++) {
      final a = nodeOf(segments[s].first), b = nodeOf(segments[s].last);
      segLen.add(RouteAssembly.length([segments[s]]));
      (edges[a] ??= []).add((b, s, true));
      (edges[b] ??= []).add((a, s, false));
    }

    int nearestNode(LatLng p) {
      var best = 0;
      for (var n = 1; n < nodes.length; n++) {
        if (haversine(nodes[n], p) < haversine(nodes[best], p)) best = n;
      }
      return best;
    }

    final from = nearestNode(start), to = nearestNode(end);
    if (from == to) return pieces; // loop route: keep the listed order

    // 3. Dijkstra over segments plus (penalized) gap jumps between any nodes.
    final n = nodes.length;
    final dist = List<double>.filled(n, double.infinity);
    final prev = List<int>.filled(n, -1);
    final prevSeg = List<int>.filled(n, -1); // -1 = gap
    final prevFwd = List<bool>.filled(n, true);
    final done = List<bool>.filled(n, false);
    dist[from] = 0;
    for (var iter = 0; iter < n; iter++) {
      var u = -1;
      for (var k = 0; k < n; k++) {
        if (!done[k] && (u < 0 || dist[k] < dist[u])) u = k;
      }
      if (u < 0 || dist[u] == double.infinity || u == to) break;
      done[u] = true;
      for (final (v, s, fwd) in edges[u] ?? const <(int, int, bool)>[]) {
        final d = dist[u] + segLen[s];
        if (d < dist[v]) {
          dist[v] = d;
          prev[v] = u;
          prevSeg[v] = s;
          prevFwd[v] = fwd;
        }
      }
      for (var v = 0; v < n; v++) {
        if (done[v]) continue;
        final d = dist[u] + haversine(nodes[u], nodes[v]) * gapPenalty;
        if (d < dist[v]) {
          dist[v] = d;
          prev[v] = u;
          prevSeg[v] = -1;
        }
      }
    }
    if (prev[to] < 0) return pieces;

    // 4. Walk back and emit continuous pieces.
    final steps = <(int, bool)>[]; // segment (or -1 for gap), forward
    for (var v = to; v != from; v = prev[v]) {
      steps.add((prevSeg[v], prevFwd[v]));
    }
    final out = <List<LatLng>>[];
    var current = <LatLng>[];
    for (final (s, fwd) in steps.reversed) {
      if (s < 0) {
        if (current.length >= 2) out.add(current);
        current = <LatLng>[];
        continue;
      }
      final pts = fwd ? segments[s] : segments[s].reversed.toList();
      current.addAll(current.isNotEmpty ? pts.skip(1) : pts);
    }
    if (current.length >= 2) out.add(current);
    return out;
  }
}
