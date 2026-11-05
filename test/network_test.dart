@Tags(['network'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:velosm/core/route_track.dart';
import 'package:velosm/models/poi.dart';
import 'package:velosm/services/brouter_service.dart';
import 'package:velosm/services/geocoding_service.dart';
import 'package:velosm/services/http.dart';
import 'package:velosm/services/overpass_service.dart';
import 'package:velosm/services/waymarked_service.dart';

/// Checks the parsers against the real services (opt-in, see dart_test.yaml).
void main() {
  final http = Http();
  const zurich = LatLng(47.3769, 8.5417), winterthur = LatLng(47.4996, 8.7240);

  test('BRouter routes along cycle routes', () async {
    final leg = await BRouterService(http, 'https://brouter.de')
        .route(zurich, winterthur, profile: 'trekking', stickToCycleRoutes: true);
    expect(leg.distance, inInclusiveRange(20000, 40000));
    expect(leg.hasElevation, isTrue);
    expect(leg.hints, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('Overpass finds water and supermarkets along a route', () async {
    final leg = await BRouterService(http, 'https://brouter.de')
        .route(zurich, winterthur, profile: 'trekking');
    final track = RouteTrack.fromLegs([leg]);
    final pois = await OverpassService(http, ['https://overpass-api.de/api/interpreter'])
        .searchBounds(track.chunkBounds(20000),
            [PoiCategory.byId('water')!, PoiCategory.byId('supermarket')!]);
    final placed = track.placePois(pois);
    expect(placed.where((p) => p.poi.category == 'water'), isNotEmpty);
    expect(placed.where((p) => p.poi.category == 'supermarket'), isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('Waymarked Trails search and import', () async {
    final wmt = WaymarkedService(http);
    final results = await wmt.search('Rhein-Route');
    expect(results, isNotEmpty);
    final tour = await wmt.importRoute(results.firstWhere((r) => r.id == 149204));
    expect(tour.distance, closeTo(42000, 2000));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('Nominatim search', () async {
    final places = await GeocodingService(http).search('Konstanz');
    expect(places.first.position.latitude, closeTo(47.66, 0.1));
  });
}
