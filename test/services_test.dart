import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:velosm/core/geo.dart';
import 'package:velosm/core/route_track.dart';
import 'package:velosm/models/poi.dart';
import 'package:velosm/models/tour.dart';
import 'package:velosm/services/brouter_service.dart';
import 'package:velosm/services/http.dart';
import 'package:velosm/services/overpass_service.dart';
import 'package:velosm/services/storage.dart';
import 'package:velosm/services/waymarked_service.dart';

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

void main() {
  group('BRouter', () {
    test('parses GeoJSON with elevation and voice hints', () {
      final leg = BRouterService.parse(fixture('brouter_zurich.geojson'));
      expect(leg.points.length, 1320);
      expect(leg.elevations.length, 1320);
      expect(leg.points.first.latitude, closeTo(47.3769, 1e-4));
      expect(leg.distance, closeTo(28494, 300)); // BRouter's own track-length
      expect(leg.hints, isNotEmpty);
      expect(leg.hints.first.index, 1);
      expect(leg.hints.first.command, 2);
      expect(leg.climb.ascent, greaterThan(150));
    });

    test('error text becomes a helpful message', () {
      expect(
        () => BRouterService.parse('from-position not mapped in existing datafile\n'),
        throwsA(isA<ServiceException>()
            .having((e) => e.message, 'message', contains('too far from any road'))),
      );
    });

    test('request uses the cycle route parameter only for trekking', () {
      final s = BRouterService(Http(), 'https://brouter.de/');
      final pts = [const LatLng(47, 8), const LatLng(47.1, 8.1)];
      final u = s.buildUri(pts, 'trekking', stickToCycleRoutes: true);
      expect(u.toString(), startsWith('https://brouter.de/brouter?'));
      expect(u.queryParameters['lonlats'], '8.000000,47.000000|8.100000,47.100000');
      expect(u.queryParameters['profile:stick_to_cycleroutes'], '1');
      expect(s.buildUri(pts, 'fastbike', stickToCycleRoutes: true).queryParameters,
          isNot(contains('profile:stick_to_cycleroutes')));
    });
  });

  group('Overpass', () {
    test('bounds query has one statement per area, category and filter', () {
      final q = OverpassService.buildBoundsQuery(
        [GeoBounds(47, 8, 47.1, 8.1), GeoBounds(47.1, 8.1, 47.2, 8.2)],
        [PoiCategory.byId('water')!, PoiCategory.byId('camping')!],
      );
      expect(q, startsWith('[out:json]'));
      expect('nwr['.allMatches(q).length, 2 * (3 + 1));
      expect(q, contains('out center tags qt;'));
    });

    test('parses nodes and way centers, drops unknown kinds', () {
      final body = jsonEncode({
        'elements': [
          {'type': 'node', 'id': 1, 'lat': 47.0, 'lon': 8.0, 'tags': {'amenity': 'drinking_water'}},
          {
            'type': 'way',
            'id': 2,
            'center': {'lat': 47.1, 'lon': 8.1},
            'tags': {'tourism': 'camp_site', 'name': 'Camping Seeblick'}
          },
          {'type': 'node', 'id': 3, 'lat': 47.0, 'lon': 8.0, 'tags': {'amenity': 'bench'}},
          {'type': 'node', 'id': 1, 'lat': 47.0, 'lon': 8.0, 'tags': {'amenity': 'drinking_water'}},
        ]
      });
      final pois = OverpassService.parse(body);
      expect(pois.map((p) => p.id), ['n1', 'w2']);
      expect(pois[1].category, 'camping');
      expect(pois[1].name, 'Camping Seeblick');
      expect(pois[0].name, 'Drinking water');
    });

    test('falls back to the next server on errors', () async {
      final hosts = <String>[];
      final client = MockClient((req) async {
        hosts.add(req.url.host);
        if (req.url.host == 'a.example') return http.Response('busy', 500);
        return http.Response(jsonEncode({'elements': []}), 200);
      });
      final s = OverpassService(Http(client), ['https://a.example/api', 'https://b.example/api']);
      expect(await s.run('[out:json];'), isEmpty);
      expect(hosts, ['a.example', 'b.example']);
    });
  });

  group('Waymarked Trails', () {
    test('signposted route becomes a tour of track pieces', () {
      final details = jsonDecode(fixture('wmt_149204.json')) as Map<String, dynamic>;
      final tour = WaymarkedService.tourFromDetails(details);
      expect(tour.name, contains('Rhein-Route'));
      // The stray 39 m fragment near Buchs is dropped, not bridged.
      expect(tour.legs.length, 1);
      expect(tour.legs.single!.source, LegSource.track);
      final official = (details['route']['length'] as num).toDouble();
      expect(tour.distance, closeTo(official, official * 0.02));
      expect(tour.waypoints.first.name, 'Buchs (SG)');
      expect(tour.waypoints.last.name, 'St. Margrethen');
    });

    test('gaps between pieces become unrouted legs', () {
      Map<String, dynamic> way(List<List<double>> c) =>
          {'route_type': 'base', 'geometry': {'type': 'LineString', 'coordinates': c}};
      // Two linear sections 10 km apart (in EPSG:3857 meters), the second mapped backwards.
      final details = {
        'name': 'Gappy',
        'route': {
          'route_type': 'route',
          'main': [
            {'route_type': 'linear', 'ways': [way([[0, 0], [5000, 0]]), way([[5000, 0], [10000, 0]])]},
            {'route_type': 'linear', 'ways': [way([[30000, 0], [20000, 0]])]},
          ],
        },
      };
      final tour = WaymarkedService.tourFromDetails(details);
      expect(tour.legs.length, 3);
      expect(tour.legs[1], isNull);
      expect(tour.legs[2]!.points.first.longitude, lessThan(tour.legs[2]!.points.last.longitude));
    });

    test('chain orients ways head to tail', () {
      final a = [const LatLng(47, 8), const LatLng(47.01, 8)];
      final b = [const LatLng(47.02, 8), const LatLng(47.01, 8)]; // reversed
      final c = [const LatLng(47.02, 8), const LatLng(47.03, 8)];
      // First way reversed relative to the others.
      final chained = WaymarkedService.chain([a.reversed.toList(), b, c]);
      expect(chained.first, const LatLng(47, 8));
      expect(chained.last, const LatLng(47.03, 8));
      expect(chained.length, 4);
    });
  });

  group('storage', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('velosm'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('save, list, load, delete', () async {
      final repo = TourRepository(dir);
      expect(await repo.list(), isEmpty);
      final leg = BRouterService.parse(fixture('brouter_zurich.geojson'));
      final tour = Tour(
        id: 'abc',
        name: 'Zürich',
        waypoints: [
          Waypoint(id: 'a', position: leg.points.first),
          Waypoint(id: 'b', position: leg.points.last),
        ],
        legs: [leg],
      );
      await repo.save(tour);
      final list = await repo.list();
      expect(list.single.name, 'Zürich');
      expect(list.single.distance, closeTo(leg.distance, 1));
      final back = (await repo.load('abc'))!;
      expect(back.legs.single!.hints.length, leg.hints.length);
      expect(RouteTrack.fromTour(back).length, closeTo(leg.distance, 1));

      final cache = PoiCache()
        ..addAll([Poi(id: 'n1', position: leg.points[100], category: 'water', tags: const {})])
        ..fetched.add('0:water:1.0');
      await repo.savePois('abc', cache);
      final c2 = await repo.loadPois('abc');
      expect(c2.pois.keys, ['n1']);
      expect(c2.fetched, {'0:water:1.0'});

      await repo.delete('abc');
      expect(await repo.list(), isEmpty);
      expect(await repo.load('abc'), isNull);
    });

    test('corrupt index is rebuilt from tour files', () async {
      final repo = TourRepository(dir);
      await repo.save(Tour(id: 'x', name: 'X'));
      File('${dir.path}/tours/index.json').writeAsStringSync('{broken');
      expect((await repo.list()).single.id, 'x');
    });
  });
}
