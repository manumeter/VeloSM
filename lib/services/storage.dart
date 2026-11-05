import 'dart:convert';
import 'dart:io';

import '../models/poi.dart';
import '../models/tour.dart';

/// POIs downloaded for a tour, so they are available offline on the road.
class PoiCache {
  final Map<String, Poi> pois;

  /// Route chunks already downloaded, as `"<chunk>:<category>"` keys.
  final Set<String> fetched;

  /// Route geometry the [fetched] chunk keys refer to.
  String fingerprint;

  PoiCache({Map<String, Poi>? pois, Set<String>? fetched, this.fingerprint = ''})
      : pois = pois ?? {},
        fetched = fetched ?? {};

  void addAll(Iterable<Poi> list) {
    for (final p in list) {
      pois[p.id] = p;
    }
  }

  Map<String, dynamic> toJson() => {
        'fingerprint': fingerprint,
        'fetched': fetched.toList(),
        'pois': [for (final p in pois.values) p.toJson()],
      };

  factory PoiCache.fromJson(Map<String, dynamic> j) => PoiCache(
        fingerprint: j['fingerprint'] as String? ?? '',
        fetched: {for (final f in j['fetched'] as List? ?? const []) f as String},
        pois: {
          for (final p in j['pois'] as List? ?? const [])
            (p as Map<String, dynamic>)['id'] as String: Poi.fromJson(p),
        },
      );
}

/// JSON-file storage: one file per tour plus an index for the tour list.
class TourRepository {
  final Directory root;

  TourRepository(this.root);

  Directory get _tours => Directory('${root.path}/tours');
  File get _index => File('${_tours.path}/index.json');
  File _tourFile(String id) => File('${_tours.path}/$id.json');
  File _poiFile(String id) => File('${_tours.path}/$id.pois.json');

  Future<List<TourSummary>> list() async {
    if (!await _index.exists()) return [];
    try {
      final j = jsonDecode(await _index.readAsString()) as List;
      return [for (final e in j) TourSummary.fromJson(e as Map<String, dynamic>)]
        ..sort((a, b) => b.updated.compareTo(a.updated));
    } on FormatException {
      return _rebuildIndex();
    }
  }

  Future<List<TourSummary>> _rebuildIndex() async {
    final out = <TourSummary>[];
    if (!await _tours.exists()) return out;
    await for (final f in _tours.list()) {
      final name = f.uri.pathSegments.last;
      if (f is! File || !name.endsWith('.json') || name.contains('.pois.') ||
          name == 'index.json') {
        continue;
      }
      try {
        out.add(TourSummary.of(
            Tour.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>)));
      } catch (_) {
        // Skip unreadable files rather than failing the whole list.
      }
    }
    await _writeIndex(out);
    return out;
  }

  Future<void> _writeIndex(List<TourSummary> list) async {
    await _tours.create(recursive: true);
    await _atomicWrite(_index, jsonEncode([for (final s in list) s.toJson()]));
  }

  Future<Tour?> load(String id) async {
    final f = _tourFile(id);
    if (!await f.exists()) return null;
    return Tour.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
  }

  Future<TourSummary> save(Tour tour) async {
    await _tours.create(recursive: true);
    await _atomicWrite(_tourFile(tour.id), jsonEncode(tour.toJson()));
    final summary = TourSummary.of(tour);
    final entries = (await list())..removeWhere((s) => s.id == tour.id);
    entries.add(summary);
    await _writeIndex(entries);
    return summary;
  }

  Future<void> delete(String id) async {
    for (final f in [_tourFile(id), _poiFile(id)]) {
      if (await f.exists()) await f.delete();
    }
    final entries = (await list())..removeWhere((s) => s.id == id);
    await _writeIndex(entries);
  }

  Future<PoiCache> loadPois(String tourId) async {
    final f = _poiFile(tourId);
    if (!await f.exists()) return PoiCache();
    try {
      return PoiCache.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
    } on FormatException {
      return PoiCache();
    }
  }

  Future<void> savePois(String tourId, PoiCache cache) async {
    await _tours.create(recursive: true);
    await _atomicWrite(_poiFile(tourId), jsonEncode(cache.toJson()));
  }

  /// Write to a temp file and rename, so a crash never leaves half a tour.
  static Future<void> _atomicWrite(File f, String content) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    await tmp.rename(f.path);
  }
}
