import 'dart:convert';
import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../core/geo.dart';
import '../models/poi.dart';
import 'http.dart';

/// Queries OpenStreetMap POIs through the Overpass API.
class OverpassService {
  final Http http;
  final List<String> servers;

  OverpassService(this.http, this.servers);

  /// Overpass QL selecting [categories] in each of [areas]. Every category
  /// uses its own margin around the area so that e.g. campsites are searched
  /// further from the route than water taps.
  static String buildBoundsQuery(List<GeoBounds> areas, List<PoiCategory> categories,
      {double radiusFactor = 1}) {
    final b = StringBuffer('[out:json][timeout:180];(');
    for (final area in areas) {
      for (final c in categories) {
        final bbox = area.expanded(c.radius * radiusFactor).toOverpass();
        for (final f in c.filters) {
          b.write('nwr${f.toOverpass()}($bbox);');
        }
      }
    }
    b.write(');out center tags qt;');
    return b.toString();
  }

  static String buildAroundQuery(LatLng center, double radius, List<PoiCategory> categories) {
    final b = StringBuffer('[out:json][timeout:90];(');
    final around = 'around:${radius.round()},'
        '${center.latitude.toStringAsFixed(6)},${center.longitude.toStringAsFixed(6)}';
    for (final c in categories) {
      for (final f in c.filters) {
        b.write('nwr${f.toOverpass()}($around);');
      }
    }
    b.write(');out center tags qt;');
    return b.toString();
  }

  /// Parses an Overpass JSON answer into POIs; elements that match none of
  /// the known categories are dropped.
  static List<Poi> parse(String body) {
    final json = jsonDecode(body) as Map<String, dynamic>;
    final out = <Poi>[];
    final seen = <String>{};
    for (final e in (json['elements'] as List? ?? const [])) {
      final m = e as Map<String, dynamic>;
      final type = m['type'] as String? ?? 'node';
      final id = '${type[0]}${m['id']}';
      if (!seen.add(id)) continue;
      double? lat = (m['lat'] as num?)?.toDouble();
      double? lon = (m['lon'] as num?)?.toDouble();
      final center = m['center'] as Map<String, dynamic>?;
      if (center != null) {
        lat = (center['lat'] as num).toDouble();
        lon = (center['lon'] as num).toDouble();
      }
      if (lat == null || lon == null) continue;
      final tags = <String, String>{
        for (final t in (m['tags'] as Map<String, dynamic>? ?? const {}).entries)
          t.key: t.value.toString(),
      };
      final cat = PoiCategory.classify(tags);
      if (cat == null) continue;
      out.add(Poi(id: id, position: LatLng(lat, lon), category: cat.id, tags: tags));
    }
    return out;
  }

  /// Runs [query], trying each configured server; retries on overload.
  Future<List<Poi>> run(String query) async {
    ServiceException? last;
    for (var attempt = 0; attempt < math.max(2, servers.length); attempt++) {
      final server = servers[attempt % servers.length];
      try {
        final body = await http.postForm(Uri.parse(server), {'data': query},
            timeout: const Duration(seconds: 200));
        if (!body.trimLeft().startsWith('{')) {
          throw ServiceException('Overpass returned an unexpected answer.');
        }
        return parse(body);
      } on HttpStatusException catch (e) {
        last = e;
        if (e.status == 429 || e.status == 504) {
          await Future<void>.delayed(Duration(seconds: 5 + attempt * 10));
        }
      } on ServiceException catch (e) {
        last = e;
      }
    }
    throw last ?? const ServiceException('Overpass request failed');
  }

  Future<List<Poi>> searchBounds(List<GeoBounds> areas, List<PoiCategory> categories,
          {double radiusFactor = 1}) =>
      run(buildBoundsQuery(areas, categories, radiusFactor: radiusFactor));

  Future<List<Poi>> searchAround(LatLng center, double radius, List<PoiCategory> categories) =>
      run(buildAroundQuery(center, radius, categories));
}
