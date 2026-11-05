import 'package:latlong2/latlong.dart';

import 'http.dart';

class Place {
  final String name;
  final String detail;
  final LatLng position;

  const Place(this.name, this.detail, this.position);
}

/// Place search via Nominatim (only on explicit user search, per its policy).
class GeocodingService {
  final Http http;
  final String baseUrl;

  GeocodingService(this.http, {this.baseUrl = 'https://nominatim.openstreetmap.org'});

  Future<List<Place>> search(String query, {LatLng? near}) async {
    final params = {
      'q': query,
      'format': 'jsonv2',
      'limit': '10',
      if (near != null) ...{
        // Prefer (but do not restrict to) results around the map center.
        'viewbox': '${near.longitude - 2},${near.latitude + 2},'
            '${near.longitude + 2},${near.latitude - 2}',
      },
    };
    final res = await http.getJson(Uri.parse('$baseUrl/search').replace(queryParameters: params));
    return [
      for (final r in res as List)
        Place(
          (r['name'] as String?)?.isNotEmpty == true
              ? r['name'] as String
              : (r['display_name'] as String).split(',').first,
          r['display_name'] as String? ?? '',
          LatLng(double.parse(r['lat'] as String), double.parse(r['lon'] as String)),
        ),
    ];
  }

  Future<String?> reverse(LatLng p) async {
    final uri = Uri.parse('$baseUrl/reverse').replace(queryParameters: {
      'lat': p.latitude.toStringAsFixed(6),
      'lon': p.longitude.toStringAsFixed(6),
      'format': 'jsonv2',
      'zoom': '14',
    });
    final r = await http.getJson(uri) as Map<String, dynamic>;
    final a = r['address'] as Map<String, dynamic>?;
    if (a == null) return r['name'] as String?;
    for (final k in ['village', 'town', 'city', 'hamlet', 'suburb', 'municipality']) {
      if (a[k] != null) return a[k] as String;
    }
    return r['name'] as String?;
  }
}
