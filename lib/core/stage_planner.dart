import 'package:uuid/uuid.dart';

import '../models/tour.dart';
import 'geo.dart';

const _uuid = Uuid();

/// A preferred place to end a day (e.g. a campsite), positioned on the route.
class StopCandidate {
  final double along;
  final String name;

  const StopCandidate(this.along, this.name);
}

/// Operations that change how a tour is divided into days.
class StagePlanner {
  /// Splits the leg containing [along] (distance from tour start) and inserts
  /// a new waypoint there. Returns the new waypoint, or null if [along] lies
  /// on an existing waypoint or in a leg that is not routed yet.
  static Waypoint? splitAt(Tour tour, double along,
      {bool overnight = true, bool auto = false, String? name}) {
    var offset = 0.0;
    for (var li = 0; li < tour.legs.length; li++) {
      final leg = tour.legs[li];
      final len = leg?.distance ??
          haversine(tour.waypoints[li].position, tour.waypoints[li + 1].position);
      if (along > offset + len) {
        offset += len;
        continue;
      }
      final local = along - offset;
      if (local < 50) {
        return _markExisting(tour, li, overnight, name);
      }
      if (len - local < 50) {
        return _markExisting(tour, li + 1, overnight, name);
      }
      if (leg == null) return null;
      var d = 0.0;
      for (var s = 0; s + 1 < leg.points.length; s++) {
        final segLen = haversine(leg.points[s], leg.points[s + 1]);
        if (d + segLen >= local) {
          final t = segLen == 0 ? 0.0 : (local - d) / segLen;
          final (a, b) = leg.splitAt(s, t);
          final wp = Waypoint(
            id: _uuid.v4(),
            position: b.points.first,
            overnight: overnight,
            auto: auto,
            name: name,
          );
          tour.waypoints.insert(li + 1, wp);
          tour.legs[li] = a;
          tour.legs.insert(li + 1, b);
          tour.touch();
          return wp;
        }
        d += segLen;
      }
      return null;
    }
    return null;
  }

  static Waypoint? _markExisting(Tour tour, int wi, bool overnight, String? name) {
    final wp = tour.waypoints[wi];
    if (wi == 0 || wi == tour.waypoints.length - 1) return wp;
    wp.overnight = overnight;
    if (name != null && wp.name == null) wp.name = name;
    tour.touch();
    return wp;
  }

  /// Removes waypoints previously created by [planDays], joining their legs.
  static void removeAutoStops(Tour tour) {
    for (var i = tour.waypoints.length - 2; i >= 1; i--) {
      final wp = tour.waypoints[i];
      if (!wp.auto) continue;
      final a = tour.legs[i - 1], b = tour.legs[i];
      tour.waypoints.removeAt(i);
      tour.legs.removeAt(i);
      tour.legs[i - 1] = (a != null && b != null) ? a.join(b) : null;
    }
    tour.touch();
  }

  /// Divides the tour into days of roughly [dayLength] meters. Overnight stops
  /// set by the user are kept; longer stretches between them are split into
  /// equal days. If [candidates] are given (campsites, hotels, ...), each
  /// split snaps to the candidate closest to the ideal position, as long as it
  /// is within [tolerance] (fraction of the day length).
  static int planDays(Tour tour, double dayLength,
      {List<StopCandidate> candidates = const [], double tolerance = 0.2}) {
    if (!tour.isComplete) {
      throw StateError('Route all legs before planning days.');
    }
    removeAutoStops(tour);
    final sorted = [...candidates]..sort((a, b) => a.along.compareTo(b.along));
    final splits = <StopCandidate>[];
    for (final stage in tour.stages) {
      final n = (stage.distance / dayLength).round();
      if (n <= 1) continue;
      final step = stage.distance / n;
      var prev = stage.startOffset;
      for (var k = 1; k < n; k++) {
        final ideal = stage.startOffset + step * k;
        final window = dayLength * tolerance;
        StopCandidate? best;
        for (final c in sorted) {
          if (c.along < ideal - window) continue;
          if (c.along > ideal + window) break;
          // Keep days at least half the target length.
          if (c.along - prev < dayLength * 0.5) continue;
          if (best == null || (c.along - ideal).abs() < (best.along - ideal).abs()) {
            best = c;
          }
        }
        final stop = best ?? StopCandidate(ideal, '');
        splits.add(stop);
        prev = stop.along;
      }
    }
    // Insert from the end so earlier distances stay valid.
    var count = 0;
    for (final s in splits.reversed) {
      final wp = splitAt(tour, s.along,
          auto: true, name: s.name.isEmpty ? null : s.name);
      if (wp != null) count++;
    }
    return count;
  }
}
