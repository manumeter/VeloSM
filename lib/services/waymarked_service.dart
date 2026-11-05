import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';
import 'package:uuid/uuid.dart';

import '../core/geo.dart';
import '../core/route_assembly.dart';
import '../core/route_track.dart';
import '../models/tour.dart';
import 'http.dart';

/// A signposted cycle route found on Waymarked Trails.
class SignedRoute {
  final int id;
  final String name;
  final String? ref;

  /// INT (EuroVelo etc.), NAT, REG or LOC.
  final String? group;
  final List<String> itinerary;

  const SignedRoute(this.id, this.name, this.ref, this.group, this.itinerary);

  String get groupLabel => switch (group) {
        'INT' => 'International',
        'NAT' => 'National',
        'REG' => 'Regional',
        'LOC' => 'Local',
        _ => group ?? '',
      };
}

/// Imports signposted bicycle route relations from
/// https://cycling.waymarkedtrails.org, which already resolves (super-)
/// relations into ordered sections of member ways.
class WaymarkedService {
  final Http http;
  static const base = 'https://cycling.waymarkedtrails.org/api/v1';

  WaymarkedService(this.http);

  Future<List<SignedRoute>> search(String query) async {
    final uri = Uri.parse('$base/list/search')
        .replace(queryParameters: {'query': query, 'limit': '30'});
    final json = await http.getJson(uri) as Map<String, dynamic>;
    return [
      for (final r in (json['results'] as List? ?? const []))
        if (r['type'] == 'relation')
          SignedRoute(
            (r['id'] as num).toInt(),
            r['name'] as String? ?? r['ref'] as String? ?? 'Route ${r['id']}',
            r['ref'] as String?,
            r['group'] as String?,
            [for (final s in (r['itinerary'] as List? ?? const [])) s.toString()],
          ),
    ];
  }

  Future<Tour> importRoute(SignedRoute route) async {
    final body = await http.get(Uri.parse('$base/details/relation/${route.id}'),
        timeout: const Duration(seconds: 120));
    // Long routes are megabytes of JSON: decode and assemble off the UI thread.
    return compute(_tourFromBody, (body, route.name));
  }

  /// Turns the WMT route structure (route → main → linear/split → ways) into
  /// ordered, continuous pieces (see [RouteAssembly]).
  static List<List<LatLng>> extractPieces(Map<String, dynamic> details) {
    final route = details['route'] as Map<String, dynamic>?;
    if (route == null) return const [];
    final pieces = [
      for (final piece in _pieces(route))
        if (piece.length >= 2) piece,
    ];
    if (pieces.length < 2) return pieces;
    // The ordered assembly gets start and end right, but relations with
    // parallel alternatives need one path chosen through them.
    return RoutePathFinder.bestPath(pieces, pieces.first.first, pieces.last.last);
  }

  static Unit _pieces(Map<String, dynamic> node) {
    List<Unit> children(String key) => [
          for (final c in (node[key] as List? ?? const [])) _pieces(c as Map<String, dynamic>),
        ];
    switch (node['route_type']) {
      case 'base':
        final geom = node['geometry'] as Map<String, dynamic>?;
        if (geom == null) return const [];
        final pts = [
          for (final c in geom['coordinates'] as List)
            fromWebMercator((c[0] as num).toDouble(), (c[1] as num).toDouble()),
        ];
        return pts.length >= 2 ? [pts] : const [];
      case 'linear':
        return RouteAssembly.chain(children('ways'));
      case 'split':
        // Separate ways per direction: follow the forward branch.
        return RouteAssembly.chain(children(node['forward'] != null ? 'forward' : 'backward'));
      case 'route':
        return RouteAssembly.joinRoute(children('main'));
      default:
        return const [];
    }
  }

  /// Chains ways head to tail into one line, reversing ways as needed.
  static List<LatLng> chain(List<List<LatLng>> ways) =>
      RouteAssembly.chain([for (final w in ways) [w]]).expand((p) => p).toList();

  /// Builds a tour with one track leg per continuous piece. Gaps in the OSM
  /// data between pieces become unrouted legs, which the planner routes.
  static Tour tourFromDetails(Map<String, dynamic> details, {String? fallbackName}) {
    const uuid = Uuid();
    final pieces = extractPieces(details);
    if (pieces.isEmpty) throw const ServiceException('This route has no usable geometry.');
    final name = (details['name'] as String?) ?? fallbackName ?? 'Signposted route';
    final ref = details['ref'] as String?;
    final itinerary = [for (final s in (details['itinerary'] as List? ?? const [])) s.toString()];
    final waypoints = <Waypoint>[];
    final legs = <Leg?>[];
    for (final piece in pieces) {
      final keep = simplifyIndices(piece, 2);
      final pts = [for (final i in keep) piece[i]];
      if (waypoints.isEmpty) {
        waypoints.add(Waypoint(id: uuid.v4(), position: pts.first));
      } else {
        waypoints.add(Waypoint(id: uuid.v4(), position: pts.first));
        legs.add(null); // gap, routed later
      }
      waypoints.add(Waypoint(id: uuid.v4(), position: pts.last));
      legs.add(Leg(points: pts, source: LegSource.track));
    }
    if (itinerary.isNotEmpty) waypoints.first.name = itinerary.first;
    if (itinerary.length > 1) waypoints.last.name = itinerary.last;
    final tour = Tour(
      id: uuid.v4(),
      name: ref != null && !name.contains(ref) ? '$name ($ref)' : name,
      waypoints: waypoints,
      legs: legs,
    );
    tour.touch();
    return tour;
  }
}

Tour _tourFromBody((String, String) args) => WaymarkedService.tourFromDetails(
    jsonDecode(args.$1) as Map<String, dynamic>,
    fallbackName: args.$2);
