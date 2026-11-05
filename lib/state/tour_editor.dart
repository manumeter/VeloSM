import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';
import 'package:uuid/uuid.dart';

import '../core/geo.dart';
import '../core/route_track.dart';
import '../core/stage_planner.dart';
import '../models/tour.dart';
import 'app_state.dart';

const _uuid = Uuid();

/// Editing session for one tour: waypoint changes, background routing of
/// changed legs, day planning and autosave.
class TourEditor extends ChangeNotifier {
  final AppState app;
  final Tour tour;

  /// Routing errors keyed by "fromWaypointId>toWaypointId".
  final Map<String, String> legErrors = {};
  bool _routing = false;
  bool _disposed = false;
  Timer? _saveTimer;
  RouteTrack? _track;
  int _trackRevision = -1;

  /// Longer legs tend to time out on the public routing server.
  static const double maxLegLength = 500000;

  TourEditor(this.app, this.tour);

  bool get routing => _routing;

  int get missingLegs => tour.legs.where((l) => l == null).length;

  RouteTrack get track {
    if (_track == null || _trackRevision != tour.revision) {
      _track = RouteTrack.fromTour(tour);
      _trackRevision = tour.revision;
    }
    return _track!;
  }

  String legKey(int i) => '${tour.waypoints[i].id}>${tour.waypoints[i + 1].id}';

  String? legError(int i) => legErrors[legKey(i)];

  void _changed({bool reroute = true, bool geometry = true}) {
    tour.touch(geometry: geometry);
    notifyListeners();
    _scheduleSave();
    if (reroute) unawaited(routeMissing());
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), save);
  }

  Future<void> save() async {
    _saveTimer?.cancel();
    await app.save(tour);
  }

  void addWaypoint(LatLng p, {String? name}) {
    tour.waypoints.add(Waypoint(id: _uuid.v4(), position: p, name: name));
    _changed();
  }

  void addAsStart(LatLng p, {String? name}) {
    tour.waypoints.insert(0, Waypoint(id: _uuid.v4(), position: p, name: name));
    tour.legs.insert(0, null);
    _changed();
  }

  /// Index of the leg passing closest to [p] (within [radius] meters).
  int? nearestLeg(LatLng p, {double radius = 3000}) {
    if (tour.legs.isEmpty) return null;
    final m = track.nearest(p, radius: radius);
    if (m == null) return null;
    var leg = 0;
    for (var i = 0; i < track.legStarts.length; i++) {
      if (track.legStarts[i] <= m.segment) leg = i;
    }
    return leg.clamp(0, tour.legs.length - 1);
  }

  /// Inserts a via point into leg [legIndex]; both halves get re-routed.
  void insertWaypoint(int legIndex, LatLng p, {String? name}) {
    tour.waypoints.insert(legIndex + 1, Waypoint(id: _uuid.v4(), position: p, name: name));
    tour.legs[legIndex] = null;
    tour.legs.insert(legIndex + 1, null);
    _changed();
  }

  void moveWaypoint(int i, LatLng p) {
    tour.waypoints[i].position = p;
    if (i > 0) tour.legs[i - 1] = null;
    if (i < tour.legs.length) tour.legs[i] = null;
    _changed();
  }

  void removeWaypoint(int i) {
    final wps = tour.waypoints;
    if (i == 0) {
      wps.removeAt(0);
      if (tour.legs.isNotEmpty) tour.legs.removeAt(0);
    } else if (i == wps.length - 1) {
      wps.removeLast();
      if (tour.legs.isNotEmpty) tour.legs.removeLast();
    } else {
      final a = tour.legs[i - 1], b = tour.legs[i];
      wps.removeAt(i);
      tour.legs.removeAt(i);
      // Imported tracks stay intact when a split point is removed.
      final keep = a != null && b != null && a.source != LegSource.routed &&
          b.source != LegSource.routed;
      tour.legs[i - 1] = keep ? a.join(b) : null;
    }
    _changed();
  }

  void toggleOvernight(int i) {
    if (i <= 0 || i >= tour.waypoints.length - 1) return;
    final w = tour.waypoints[i];
    w.overnight = !w.overnight;
    w.auto = false;
    _changed(reroute: false, geometry: false);
  }

  void renameWaypoint(int i, String? name) {
    tour.waypoints[i].name = (name == null || name.trim().isEmpty) ? null : name.trim();
    _changed(reroute: false, geometry: false);
  }

  void renameTour(String name) {
    if (name.trim().isEmpty) return;
    tour.name = name.trim();
    _changed(reroute: false, geometry: false);
  }

  void setStartDate(DateTime? d) {
    tour.startDate = d;
    _changed(reroute: false, geometry: false);
  }

  /// Changes the routing profile and recalculates all routed legs.
  void setProfile(String profile, bool stickToCycleRoutes) {
    tour.profile = profile;
    tour.stickToCycleRoutes = stickToCycleRoutes;
    for (var i = 0; i < tour.legs.length; i++) {
      if (tour.legs[i]?.source == LegSource.routed) tour.legs[i] = null;
    }
    legErrors.clear();
    _changed();
  }

  void reverse() {
    final wps = tour.waypoints.reversed.toList();
    final legs = [
      for (final l in tour.legs.reversed)
        l == null || l.source == LegSource.routed
            ? null // One-way streets: the reverse direction must be re-routed.
            : Leg(
                points: l.points.reversed.toList(),
                elevations: l.elevations.reversed.toList(),
                source: l.source,
              ),
    ];
    // Overnight flags belong to positions; keep them on the same places.
    tour.waypoints
      ..clear()
      ..addAll(wps);
    tour.legs
      ..clear()
      ..addAll(legs);
    if (wps.isNotEmpty) {
      wps.first.overnight = false;
      wps.last.overnight = false;
    }
    legErrors.clear();
    _changed();
  }

  void useStraightLine(int i) {
    legErrors.remove(legKey(i));
    tour.legs[i] = Leg.straight(tour.waypoints[i].position, tour.waypoints[i + 1].position);
    _changed(reroute: false);
  }

  void retryLeg(int i) {
    legErrors.remove(legKey(i));
    tour.legs[i] = null;
    _changed();
  }

  /// Splits the route at [along] and marks the point as an overnight stop.
  void endDayAt(double along, {String? name}) {
    StagePlanner.splitAt(tour, along, name: name);
    _changed(reroute: false);
  }

  int planDays(double dayLength, {List<StopCandidate> candidates = const []}) {
    final n = StagePlanner.planDays(tour, dayLength, candidates: candidates);
    _changed(reroute: false);
    return n;
  }

  void clearAutoDays() {
    StagePlanner.removeAutoStops(tour);
    _changed(reroute: false);
  }

  /// Routes every missing leg, one at a time. Results are matched back by
  /// waypoint ids, so editing while routing is safe.
  Future<void> routeMissing() async {
    if (_routing) return;
    _routing = true;
    notifyListeners();
    try {
      while (!_disposed) {
        var i = -1;
        for (var k = 0; k < tour.legs.length; k++) {
          if (tour.legs[k] == null && !legErrors.containsKey(legKey(k))) {
            i = k;
            break;
          }
        }
        if (i < 0) break;
        final key = legKey(i);
        final from = tour.waypoints[i].position;
        final to = tour.waypoints[i + 1].position;
        if (haversine(from, to) > maxLegLength) {
          legErrors[key] = 'This leg is ${formatDistance(haversine(from, to))} as the crow flies. '
              'Add waypoints in between (legs up to ~${formatDistance(maxLegLength)} route reliably).';
          notifyListeners();
          continue;
        }
        try {
          final leg = await app.brouter.route(from, to,
              profile: tour.profile, stickToCycleRoutes: tour.stickToCycleRoutes);
          final j = _findLeg(key, from, to);
          if (j != null && tour.legs[j] == null) {
            tour.legs[j] = leg;
            tour.touch();
            _scheduleSave();
          }
        } catch (e) {
          if (_findLeg(key, from, to) != null) legErrors[key] = e.toString();
        }
        if (!_disposed) notifyListeners();
      }
    } finally {
      _routing = false;
      if (!_disposed) notifyListeners();
    }
  }

  int? _findLeg(String key, LatLng from, LatLng to) {
    for (var k = 0; k < tour.legs.length; k++) {
      if (legKey(k) == key &&
          tour.waypoints[k].position == from &&
          tour.waypoints[k + 1].position == to) {
        return k;
      }
    }
    return null;
  }

  @override
  void dispose() {
    _disposed = true;
    if (_saveTimer?.isActive ?? false) unawaited(save());
    _saveTimer?.cancel();
    super.dispose();
  }
}
