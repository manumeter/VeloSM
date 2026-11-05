import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../core/geo.dart';
import '../core/route_track.dart';
import '../models/poi.dart';
import '../models/tour.dart';
import '../services/storage.dart';
import 'app_state.dart';

/// Downloads, caches and positions POIs along a tour.
class PoiManager extends ChangeNotifier {
  final AppState app;
  final Tour tour;
  PoiCache cache = PoiCache();
  bool loaded = false;

  bool downloading = false;
  double progress = 0;
  String? error;
  bool _cancel = false;

  static const double chunkLength = 20000;
  static const int chunksPerRequest = 6;

  List<PoiOnRoute>? _placed;
  RouteTrack? _placedTrack;
  double _placedFactor = 0;
  int _version = 0, _placedVersion = -1;

  PoiManager(this.app, this.tour);

  Future<void> load() async {
    cache = await app.repo.loadPois(tour.id);
    loaded = true;
    _version++;
    notifyListeners();
  }

  /// Identifies the route shape; splitting days or renaming keeps it.
  static String fingerprint(RouteTrack t) => t.isEmpty
      ? ''
      : '${(t.length / 10).round()}|${t.points.first.latitude.toStringAsFixed(5)},'
          '${t.points.first.longitude.toStringAsFixed(5)}|'
          '${t.points.last.latitude.toStringAsFixed(5)},${t.points.last.longitude.toStringAsFixed(5)}';

  void _sync(RouteTrack track) {
    final fp = fingerprint(track);
    if (cache.fingerprint != fp) {
      // POI positions are still valid, but the chunk layout changed.
      cache.fetched.clear();
      cache.fingerprint = fp;
    }
  }

  double get radiusFactor => app.settings.poiRadiusFactor;

  String _key(int chunk, String cat) => '$chunk:$cat:${radiusFactor.toStringAsFixed(1)}';

  /// All cached POIs positioned on [track] (memoized).
  List<PoiOnRoute> placed(RouteTrack track) {
    if (_placed == null ||
        !identical(_placedTrack, track) ||
        _placedVersion != _version ||
        _placedFactor != radiusFactor) {
      _placed = track.placePois(cache.pois.values, radiusFactor: radiusFactor);
      _placedTrack = track;
      _placedVersion = _version;
      _placedFactor = radiusFactor;
    }
    return _placed!;
  }

  /// Whether every chunk between [from] and [to] has been downloaded for [categories].
  bool covered(RouteTrack track, Set<String> categories, {double from = 0, double? to}) =>
      _missing(track, categories, from, to ?? track.length).isEmpty;

  Map<int, List<String>> _missing(
      RouteTrack track, Set<String> categories, double from, double to) {
    _sync(track);
    final count = track.chunkBounds(chunkLength).length;
    final k0 = math.max(0, (from / chunkLength).floor());
    final k1 = math.min(count - 1, (to / chunkLength).floor());
    final out = <int, List<String>>{};
    for (var k = k0; k <= k1; k++) {
      final cats = [for (final c in categories) if (!cache.fetched.contains(_key(k, c))) c];
      if (cats.isNotEmpty) out[k] = cats;
    }
    return out;
  }

  /// Downloads POIs of [categories] for the route between [from] and [to].
  Future<void> download(RouteTrack track, Set<String> categories,
      {double from = 0, double? to}) async {
    if (downloading || categories.isEmpty || track.isEmpty) return;
    final bounds = track.chunkBounds(chunkLength);
    final missing = _missing(track, categories, from, to ?? track.length);
    if (missing.isEmpty) return;
    downloading = true;
    _cancel = false;
    error = null;
    progress = 0;
    notifyListeners();

    // Batch neighbouring chunks that need the same categories.
    final batches = <(List<int>, List<String>)>[];
    for (final e in missing.entries) {
      final last = batches.isEmpty ? null : batches.last;
      if (last != null &&
          last.$1.length < chunksPerRequest &&
          listEquals(last.$2, e.value) &&
          last.$1.last == e.key - 1) {
        last.$1.add(e.key);
      } else {
        batches.add(([e.key], e.value));
      }
    }
    try {
      for (var b = 0; b < batches.length && !_cancel; b++) {
        final (chunks, cats) = batches[b];
        final pois = await app.overpass.searchBounds(
          [for (final k in chunks) bounds[k]],
          [for (final c in cats) PoiCategory.byId(c)!],
          radiusFactor: radiusFactor,
        );
        cache.addAll(pois);
        for (final k in chunks) {
          for (final c in cats) {
            cache.fetched.add(_key(k, c));
          }
        }
        _version++;
        progress = (b + 1) / batches.length;
        await app.repo.savePois(tour.id, cache);
        notifyListeners();
      }
    } catch (e) {
      error = e.toString();
    } finally {
      downloading = false;
      notifyListeners();
    }
  }

  void cancel() => _cancel = true;

  /// Searches around a single point (e.g. around a stage end) and adds the
  /// results to the cache. Returns the POIs found.
  Future<List<Poi>> searchAround(LatLng center, double radius, Set<String> categories) async {
    final cats = [for (final c in categories) PoiCategory.byId(c)!];
    final pois = await app.overpass.searchAround(center, radius, cats);
    cache.addAll(pois);
    _version++;
    await app.repo.savePois(tour.id, cache);
    notifyListeners();
    return pois;
  }

  /// Cached POIs near a point, nearest first.
  List<(Poi, double)> near(LatLng p, double radius, Set<String> categories) {
    final out = <(Poi, double)>[
      for (final poi in cache.pois.values)
        if (categories.contains(poi.category)) (poi, haversine(p, poi.position)),
    ]..retainWhere((e) => e.$2 <= radius);
    out.sort((a, b) => a.$2.compareTo(b.$2));
    return out;
  }

  /// Distinct categories present in the cache.
  Set<String> get cachedCategories => {for (final p in cache.pois.values) p.category};

  int get count => cache.pois.length;
}
