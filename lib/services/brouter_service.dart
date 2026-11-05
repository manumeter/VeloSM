import 'dart:convert';

import 'package:latlong2/latlong.dart';

import '../models/tour.dart';
import 'http.dart';

/// Routing profile offered in the UI (all exist on the public brouter.de).
class RoutingProfile {
  final String id;
  final String label;
  final String description;

  const RoutingProfile(this.id, this.label, this.description);

  static const all = [
    RoutingProfile('trekking', 'Touring',
        'Loaded touring bike. Prefers signposted cycle routes and quiet roads.'),
    RoutingProfile('safety', 'Safety first', 'Avoids traffic as much as possible.'),
    RoutingProfile('fastbike-lowtraffic', 'Road bike, low traffic',
        'Paved roads only, avoids busy roads.'),
    RoutingProfile('fastbike', 'Road bike', 'Fast, paved roads.'),
    RoutingProfile('gravel', 'Gravel', 'Allows unpaved tracks.'),
    RoutingProfile('shortest', 'Shortest', 'Shortest path, ignores comfort.'),
  ];

  static RoutingProfile byId(String id) =>
      all.firstWhere((p) => p.id == id, orElse: () => all.first);
}

/// Client for a BRouter server (https://brouter.de or self-hosted).
class BRouterService {
  final Http http;
  final String baseUrl;

  BRouterService(this.http, this.baseUrl);

  Uri buildUri(List<LatLng> points, String profile, {bool stickToCycleRoutes = false}) {
    final lonlats = points
        .map((p) => '${p.longitude.toStringAsFixed(6)},${p.latitude.toStringAsFixed(6)}')
        .join('|');
    final base = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    final params = {
      'lonlats': lonlats,
      'profile': profile,
      'alternativeidx': '0',
      'format': 'geojson',
      'timode': '3',
      // Parameter of the trekking profile: strongly favor ways that are part
      // of signposted cycle route relations (lcn/rcn/ncn/icn).
      if (stickToCycleRoutes && profile.startsWith('trekking'))
        'profile:stick_to_cycleroutes': '1',
    };
    return Uri.parse('$base/brouter').replace(queryParameters: params);
  }

  Future<Leg> route(LatLng from, LatLng to,
      {required String profile, bool stickToCycleRoutes = false}) async {
    final uri = buildUri([from, to], profile, stickToCycleRoutes: stickToCycleRoutes);
    final String body;
    try {
      body = await http.get(uri, timeout: const Duration(seconds: 150));
    } on HttpStatusException catch (e) {
      throw ServiceException(_explain(e.message));
    }
    return parse(body);
  }

  static String _explain(String msg) {
    if (msg.contains('not mapped') || msg.contains('position not')) {
      return 'A waypoint is too far from any road or path. Move it closer to a road.';
    }
    if (msg.contains('watchdog') || msg.contains('timeout')) {
      return 'Routing took too long. Add intermediate waypoints to shorten this leg.';
    }
    return msg;
  }

  /// Parses a BRouter GeoJSON answer into a leg.
  static Leg parse(String body) {
    final trimmed = body.trimLeft();
    if (!trimmed.startsWith('{')) {
      throw ServiceException(_explain(trimmed.split('\n').first));
    }
    final json = jsonDecode(trimmed) as Map<String, dynamic>;
    final features = json['features'] as List? ?? const [];
    if (features.isEmpty) throw const ServiceException('Routing returned no route.');
    final f = features.first as Map<String, dynamic>;
    final coords = (f['geometry'] as Map<String, dynamic>)['coordinates'] as List;
    final pts = <LatLng>[];
    final ele = <double>[];
    var hasEle = true;
    for (final c in coords) {
      final l = c as List;
      pts.add(LatLng((l[1] as num).toDouble(), (l[0] as num).toDouble()));
      if (l.length > 2 && l[2] != null) {
        ele.add((l[2] as num).toDouble());
      } else {
        hasEle = false;
      }
    }
    final props = f['properties'] as Map<String, dynamic>? ?? const {};
    final hints = <TurnHint>[
      for (final h in (props['voicehints'] as List? ?? const []))
        if (h is List && h.length >= 2)
          TurnHint((h[0] as num).toInt(), (h[1] as num).toInt(),
              h.length > 2 ? (h[2] as num).toInt() : 0),
    ];
    return Leg(
      points: pts,
      elevations: hasEle && ele.length == pts.length ? ele : const [],
      source: LegSource.routed,
      hints: hints,
    );
  }
}

/// Text for a BRouter voice hint command.
String turnText(int command, int exit) {
  switch (command) {
    case 1:
      return 'Continue straight';
    case 2:
      return 'Turn left';
    case 3:
      return 'Turn slightly left';
    case 4:
      return 'Turn sharply left';
    case 5:
      return 'Turn right';
    case 6:
      return 'Turn slightly right';
    case 7:
      return 'Turn sharply right';
    case 8:
      return 'Keep left';
    case 9:
      return 'Keep right';
    case 10:
    case 11:
    case 12:
      return 'Make a U-turn';
    case 13:
      return 'Off route';
    case 14:
    case 15:
      return exit > 0 ? 'Roundabout: take exit $exit' : 'Enter the roundabout';
    case 16:
      return 'Straight line section';
    case 17:
      return 'Take the exit on the left';
    case 18:
      return 'Take the exit on the right';
    default:
      return 'Continue';
  }
}
