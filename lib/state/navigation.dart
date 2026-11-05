import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../core/geo.dart';
import '../core/route_track.dart';
import '../models/poi.dart';
import '../models/tour.dart';
import 'app_state.dart';
import 'poi_manager.dart';

/// Live state while riding a tour: GPS position matched to the route,
/// progress, next turn and the POIs coming up.
class NavigationController extends ChangeNotifier {
  final AppState app;
  final Tour tour;
  final RouteTrack track;
  final PoiManager pois;

  StreamSubscription<Position>? _sub;
  Timer? _simTimer;
  LatLng? position;
  double? heading;
  double? speed;
  RouteMatch? match;
  String? error;
  bool simulating = false;

  /// Distance beyond which the rider counts as off route.
  static const double offRouteDistance = 75;

  /// How far ahead to look for POIs.
  double lookAhead = 100000;

  List<PoiOnRoute> upcoming = const [];
  double _upcomingAlong = double.negativeInfinity;
  DateTime _lastAutoFetch = DateTime.fromMillisecondsSinceEpoch(0);

  NavigationController({
    required this.app,
    required this.tour,
    required this.track,
    required this.pois,
  }) {
    pois.addListener(_poisChanged);
    app.settings.addListener(_poisChanged);
  }

  Set<String> get categories => app.settings.poiCategories;

  double get along => match?.along ?? 0;

  bool get onRoute => match != null && match!.offset <= offRouteDistance;

  double get remaining => track.length - along;

  Stage? get currentStage {
    final stages = tour.stages;
    if (stages.isEmpty) return null;
    for (final s in stages) {
      if (along < s.startOffset + s.distance) return s;
    }
    return stages.last;
  }

  double get stageRemaining {
    final s = currentStage;
    if (s == null) return 0;
    return (s.startOffset + s.distance - along).clamp(0, double.infinity);
  }

  double get stageAscentRemaining {
    final s = currentStage;
    if (s == null) return 0;
    return track.ascentBetween(along, s.startOffset + s.distance);
  }

  RouteHint? get nextHint => onRoute ? track.nextHint(along) : null;

  /// Starts GPS tracking. Returns false if location is unavailable.
  Future<bool> start() async {
    error = null;
    if (!await Geolocator.isLocationServiceEnabled()) {
      error = 'Location services are disabled.';
      notifyListeners();
      return false;
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      error = 'Location permission denied.';
      notifyListeners();
      return false;
    }
    final LocationSettings settings;
    if (defaultTargetPlatform == TargetPlatform.android) {
      settings = AndroidSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 5,
        intervalDuration: const Duration(seconds: 2),
        foregroundNotificationConfig: ForegroundNotificationConfig(
          notificationTitle: 'VeloSM navigation',
          notificationText: 'Following "${tour.name}"',
          setOngoing: true,
          enableWakeLock: true,
        ),
      );
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      settings = AppleSettings(
        accuracy: LocationAccuracy.best,
        activityType: ActivityType.fitness,
        distanceFilter: 5,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: true,
        allowBackgroundLocationUpdates: true,
      );
    } else {
      settings = const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 5);
    }
    await _sub?.cancel();
    _sub = Geolocator.getPositionStream(locationSettings: settings).listen(
      (p) {
        if (simulating) return;
        update(LatLng(p.latitude, p.longitude),
            heading: p.heading >= 0 ? p.heading : null, speed: p.speed);
      },
      onError: (Object e) {
        error = 'Location error: $e';
        notifyListeners();
      },
    );
    return true;
  }

  /// Feeds a new position (from GPS or the simulator).
  void update(LatLng p, {double? heading, double? speed}) {
    final prev = position;
    position = p;
    this.speed = speed;
    this.heading = heading ??
        (prev != null && haversine(prev, p) > 3 ? bearing(prev, p) : this.heading);
    match = track.match(p, previous: match);
    if ((along - _upcomingAlong).abs() > 25) _refreshUpcoming();
    _maybeAutoFetch();
    notifyListeners();
  }

  void _poisChanged() {
    _refreshUpcoming();
    notifyListeners();
  }

  void _refreshUpcoming() {
    _upcomingAlong = along;
    final cats = categories;
    final from = along - 30;
    final to = along + lookAhead;
    final list = <PoiOnRoute>[];
    for (final e in pois.placed(track)) {
      if (e.along < from) continue;
      if (e.along > to) break;
      if (cats.contains(e.poi.category)) list.add(e);
    }
    upcoming = list;
  }

  /// Keeps the next ~60 km of POIs downloaded while online.
  void _maybeAutoFetch() {
    if (pois.downloading || !pois.loaded) return;
    if (DateTime.now().difference(_lastAutoFetch) < const Duration(minutes: 3)) return;
    final to = along + 60000;
    if (pois.covered(track, categories, from: along, to: to)) return;
    _lastAutoFetch = DateTime.now();
    unawaited(pois.download(track, categories, from: along, to: to));
  }

  /// Rides along the route at [kmh] (for trying the app without GPS).
  void simulate({double kmh = 60, double? startAt}) {
    stopSimulation();
    simulating = true;
    var d = startAt ?? along;
    _simTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      d += kmh / 3.6;
      if (d >= track.length) {
        stopSimulation();
        return;
      }
      update(track.pointAt(d), speed: kmh / 3.6);
    });
    update(track.pointAt(d));
  }

  void stopSimulation() {
    _simTimer?.cancel();
    _simTimer = null;
    simulating = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _simTimer?.cancel();
    pois.removeListener(_poisChanged);
    app.settings.removeListener(_poisChanged);
    super.dispose();
  }
}
