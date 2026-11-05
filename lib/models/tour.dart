import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../core/geo.dart';
import '../core/polyline_codec.dart';

/// A point the tour passes through. Waypoints flagged [overnight] end a day.
class Waypoint {
  final String id;
  LatLng position;
  String? name;
  bool overnight;

  /// Created by the day planner (removed again when re-planning).
  bool auto;

  Waypoint({
    required this.id,
    required this.position,
    this.name,
    this.overnight = false,
    this.auto = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'lat': position.latitude,
        'lon': position.longitude,
        if (name != null) 'name': name,
        if (overnight) 'overnight': true,
        if (auto) 'auto': true,
      };

  factory Waypoint.fromJson(Map<String, dynamic> j) => Waypoint(
        id: j['id'] as String,
        position: LatLng((j['lat'] as num).toDouble(), (j['lon'] as num).toDouble()),
        name: j['name'] as String?,
        overnight: j['overnight'] as bool? ?? false,
        auto: j['auto'] as bool? ?? false,
      );
}

/// How a leg's geometry was produced.
enum LegSource {
  /// Calculated by the routing engine; recalculated when waypoints change.
  routed,

  /// Imported (GPX, signposted route); kept as-is.
  track,

  /// Straight line fallback.
  straight,
}

/// A turn instruction at a point index of a leg (BRouter voice hint codes).
class TurnHint {
  final int index;
  final int command;
  final int exit;

  const TurnHint(this.index, this.command, [this.exit = 0]);

  List<int> toJson() => [index, command, exit];

  factory TurnHint.fromJson(List<dynamic> j) =>
      TurnHint(j[0] as int, j[1] as int, j.length > 2 ? j[2] as int : 0);
}

/// Geometry between two consecutive waypoints.
class Leg {
  final List<LatLng> points;

  /// Same length as [points], or empty when unknown.
  final List<double> elevations;
  final LegSource source;
  final List<TurnHint> hints;

  late final double distance = _length(points);
  late final ({double ascent, double descent}) climb = elevationGain(elevations);

  Leg({
    required this.points,
    this.elevations = const [],
    this.source = LegSource.routed,
    this.hints = const [],
  }) : assert(elevations.isEmpty || elevations.length == points.length);

  factory Leg.straight(LatLng a, LatLng b) =>
      Leg(points: [a, b], source: LegSource.straight);

  bool get hasElevation => elevations.isNotEmpty;

  /// Splits the leg at segment [seg] (between points seg and seg+1) at
  /// fraction [t]. Returns the two halves sharing the split point.
  (Leg, Leg) splitAt(int seg, double t) {
    seg = seg.clamp(0, points.length - 2);
    final p = lerpLatLng(points[seg], points[seg + 1], t);
    final first = [...points.sublist(0, seg + 1), p];
    final second = [p, ...points.sublist(seg + 1)];
    List<double> e1 = const [], e2 = const [];
    if (hasElevation) {
      final e = elevations[seg] + (elevations[seg + 1] - elevations[seg]) * t;
      e1 = [...elevations.sublist(0, seg + 1), e];
      e2 = [e, ...elevations.sublist(seg + 1)];
    }
    final h1 = hints.where((h) => h.index <= seg).toList();
    final h2 = [
      for (final h in hints)
        if (h.index > seg) TurnHint(h.index - seg, h.command, h.exit),
    ];
    return (
      Leg(points: first, elevations: e1, source: source, hints: h1),
      Leg(points: second, elevations: e2, source: source, hints: h2),
    );
  }

  /// Concatenates two legs that share a junction point.
  Leg join(Leg other) {
    final offset = points.length - 1;
    final pts = [...points, ...other.points.skip(1)];
    final ele = hasElevation && other.hasElevation
        ? [...elevations, ...other.elevations.skip(1)]
        : const <double>[];
    return Leg(
      points: pts,
      elevations: ele,
      source: source == other.source ? source : LegSource.track,
      hints: [
        ...hints,
        for (final h in other.hints) TurnHint(h.index + offset, h.command, h.exit),
      ],
    );
  }

  Map<String, dynamic> toJson() => {
        'src': source.name,
        'pts': PolylineCodec.encodePoints(points),
        if (hasElevation) 'ele': PolylineCodec.encodeElevations(elevations),
        if (hints.isNotEmpty) 'hints': [for (final h in hints) h.toJson()],
      };

  factory Leg.fromJson(Map<String, dynamic> j) {
    final pts = PolylineCodec.decodePoints(j['pts'] as String);
    var ele = j['ele'] == null
        ? const <double>[]
        : PolylineCodec.decodeElevations(j['ele'] as String);
    if (ele.length != pts.length) ele = const [];
    return Leg(
      points: pts,
      elevations: ele,
      source: LegSource.values.byName(j['src'] as String? ?? 'routed'),
      hints: [
        for (final h in (j['hints'] as List? ?? const [])) TurnHint.fromJson(h as List),
      ],
    );
  }
}

double _length(List<LatLng> pts) {
  var d = 0.0;
  for (var i = 1; i < pts.length; i++) {
    d += haversine(pts[i - 1], pts[i]);
  }
  return d;
}

/// Total ascent/descent with a hysteresis filter that ignores noise below
/// [threshold] meters.
({double ascent, double descent}) elevationGain(List<double> ele,
    {double threshold = 5}) {
  if (ele.isEmpty) return (ascent: 0, descent: 0);
  var ascent = 0.0, descent = 0.0;
  var ref = ele.first;
  for (final e in ele) {
    if (e.isNaN) continue;
    if (ref.isNaN) ref = e;
    final d = e - ref;
    if (d > threshold) {
      ascent += d;
      ref = e;
    } else if (d < -threshold) {
      descent -= d;
      ref = e;
    }
  }
  return (ascent: ascent, descent: descent);
}

/// One day of a multi-day tour: the legs between two overnight stops.
class Stage {
  final int number;
  final int firstLeg;
  final int endLeg; // exclusive
  final Waypoint start;
  final Waypoint end;
  final double distance;
  final double ascent;
  final double descent;
  final bool complete;

  /// Distance from the tour start to this stage's start.
  final double startOffset;

  const Stage({
    required this.number,
    required this.firstLeg,
    required this.endLeg,
    required this.start,
    required this.end,
    required this.distance,
    required this.ascent,
    required this.descent,
    required this.complete,
    required this.startOffset,
  });

  String get title {
    final a = start.name, b = end.name;
    if (a != null && b != null) return '$a → $b';
    return b ?? a ?? 'Day $number';
  }
}

/// A multi-day bicycle tour.
class Tour {
  final String id;
  String name;
  String profile;
  bool stickToCycleRoutes;
  final List<Waypoint> waypoints;

  /// `legs[i]` connects `waypoints[i]` and `waypoints[i + 1]`; `null` means
  /// the leg still needs to be routed.
  final List<Leg?> legs;
  DateTime created;
  DateTime updated;
  DateTime? startDate;

  /// Incremented on every geometry change (used to invalidate caches).
  int revision;

  Tour({
    required this.id,
    required this.name,
    this.profile = 'trekking',
    this.stickToCycleRoutes = true,
    List<Waypoint>? waypoints,
    List<Leg?>? legs,
    DateTime? created,
    DateTime? updated,
    this.startDate,
    this.revision = 0,
  })  : waypoints = waypoints ?? [],
        legs = legs ?? [],
        created = created ?? DateTime.now(),
        updated = updated ?? DateTime.now() {
    _normalizeLegs();
  }

  void _normalizeLegs() {
    final want = math.max(0, waypoints.length - 1);
    while (legs.length < want) {
      legs.add(null);
    }
    while (legs.length > want) {
      legs.removeLast();
    }
  }

  bool get isComplete => legs.every((l) => l != null);

  double get distance => legs.fold(0.0, (s, l) => s + (l?.distance ?? 0));

  double get ascent => legs.fold(0.0, (s, l) => s + (l?.climb.ascent ?? 0));

  int get dayCount => stages.length;

  List<Stage> get stages {
    final out = <Stage>[];
    if (waypoints.length < 2) return out;
    var first = 0;
    var offset = 0.0;
    for (var i = 1; i < waypoints.length; i++) {
      if (waypoints[i].overnight || i == waypoints.length - 1) {
        var d = 0.0, up = 0.0, down = 0.0;
        var complete = true;
        for (var l = first; l < i; l++) {
          final leg = legs[l];
          if (leg == null) {
            complete = false;
            d += haversine(waypoints[l].position, waypoints[l + 1].position);
            continue;
          }
          d += leg.distance;
          up += leg.climb.ascent;
          down += leg.climb.descent;
        }
        out.add(Stage(
          number: out.length + 1,
          firstLeg: first,
          endLeg: i,
          start: waypoints[first],
          end: waypoints[i],
          distance: d,
          ascent: up,
          descent: down,
          complete: complete,
          startOffset: offset,
        ));
        offset += d;
        first = i;
      }
    }
    return out;
  }

  /// Marks the tour as modified; [geometry] changes also bump [revision].
  void touch({bool geometry = true}) {
    if (geometry) revision++;
    updated = DateTime.now();
    _normalizeLegs();
  }

  Map<String, dynamic> toJson() => {
        'version': 1,
        'id': id,
        'name': name,
        'profile': profile,
        'stickToCycleRoutes': stickToCycleRoutes,
        'created': created.toIso8601String(),
        'updated': updated.toIso8601String(),
        if (startDate != null) 'startDate': startDate!.toIso8601String(),
        'revision': revision,
        'waypoints': [for (final w in waypoints) w.toJson()],
        'legs': [for (final l in legs) l?.toJson()],
      };

  factory Tour.fromJson(Map<String, dynamic> j) => Tour(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'Tour',
        profile: j['profile'] as String? ?? 'trekking',
        stickToCycleRoutes: j['stickToCycleRoutes'] as bool? ?? true,
        created: DateTime.tryParse(j['created'] as String? ?? ''),
        updated: DateTime.tryParse(j['updated'] as String? ?? ''),
        startDate: DateTime.tryParse(j['startDate'] as String? ?? ''),
        revision: j['revision'] as int? ?? 0,
        waypoints: [
          for (final w in j['waypoints'] as List) Waypoint.fromJson(w as Map<String, dynamic>),
        ],
        legs: [
          for (final l in j['legs'] as List)
            l == null ? null : Leg.fromJson(l as Map<String, dynamic>),
        ],
      );
}

/// Lightweight listing entry so the tour list does not load full geometry.
class TourSummary {
  final String id;
  final String name;
  final double distance;
  final double ascent;
  final int days;
  final DateTime updated;

  const TourSummary({
    required this.id,
    required this.name,
    required this.distance,
    required this.ascent,
    required this.days,
    required this.updated,
  });

  factory TourSummary.of(Tour t) => TourSummary(
        id: t.id,
        name: t.name,
        distance: t.distance,
        ascent: t.ascent,
        days: t.dayCount,
        updated: t.updated,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'distance': distance,
        'ascent': ascent,
        'days': days,
        'updated': updated.toIso8601String(),
      };

  factory TourSummary.fromJson(Map<String, dynamic> j) => TourSummary(
        id: j['id'] as String,
        name: j['name'] as String,
        distance: (j['distance'] as num).toDouble(),
        ascent: (j['ascent'] as num?)?.toDouble() ?? 0,
        days: j['days'] as int? ?? 0,
        updated: DateTime.parse(j['updated'] as String),
      );
}
