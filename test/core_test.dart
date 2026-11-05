import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:velosm/core/geo.dart';
import 'package:velosm/core/polyline_codec.dart';
import 'package:velosm/core/route_assembly.dart';
import 'package:velosm/core/route_track.dart';
import 'package:velosm/models/poi.dart';
import 'package:velosm/models/tour.dart';

/// Straight north-going line starting at [start], [n] points [step] m apart.
List<LatLng> northLine(LatLng start, int n, double step) {
  final dLat = step / earthRadiusM * 180 / math.pi;
  return [for (var i = 0; i < n; i++) LatLng(start.latitude + dLat * i, start.longitude)];
}

Poi poi(String id, LatLng p, String cat) =>
    Poi(id: id, position: p, category: cat, tags: {'name': id});

void main() {
  group('geo', () {
    test('haversine Zurich–Bern', () {
      final d = haversine(const LatLng(47.3769, 8.5417), const LatLng(46.9480, 7.4474));
      expect(d, closeTo(95500, 1500));
    });

    test('projection onto segment', () {
      const a = LatLng(47, 8), b = LatLng(47, 8.01);
      final pr = projectOnSegment(const LatLng(47.001, 8.005), a, b);
      expect(pr.t, closeTo(0.5, 0.01));
      expect(pr.distance, closeTo(111, 2));
      // Beyond the end clamps to the end point.
      expect(projectOnSegment(const LatLng(47, 8.02), a, b).t, 1);
    });

    test('web mercator conversion', () {
      final p = fromWebMercator(1055147.89, 5969422.39);
      expect(p.latitude, closeTo(47.168, 0.01));
      expect(p.longitude, closeTo(9.478, 0.01));
    });

    test('formatDistance', () {
      expect(formatDistance(843), '840 m');
      expect(formatDistance(12440), '12.4 km');
      expect(formatDistance(1234567), '1,235 km');
    });
  });

  group('polyline codec', () {
    test('round trip keeps 1e-6 precision', () {
      final pts = [
        const LatLng(47.376899, 8.541699),
        const LatLng(-33.856784, 151.215297),
        const LatLng(0, -0.000001),
      ];
      final back = PolylineCodec.decodePoints(PolylineCodec.encodePoints(pts));
      expect(back.length, 3);
      for (var i = 0; i < 3; i++) {
        expect(back[i].latitude, closeTo(pts[i].latitude, 1e-6));
        expect(back[i].longitude, closeTo(pts[i].longitude, 1e-6));
      }
    });

    test('elevations round trip', () {
      final ele = [407.75, 410.0, -12.3, 3500.1];
      final back = PolylineCodec.decodeElevations(PolylineCodec.encodeElevations(ele));
      for (var i = 0; i < ele.length; i++) {
        expect(back[i], closeTo(ele[i], 0.051));
      }
    });

    test('corrupt data is rejected', () {
      expect(() => PolylineCodec.decodePoints('_p~iF~ps|U_'), throwsFormatException);
    });
  });

  test('elevation gain filters noise', () {
    final noisy = <double>[100, 102, 99, 101, 100, 120, 118, 140, 130, 100];
    final g = elevationGain(noisy);
    expect(g.ascent, closeTo(40, 0.1));
    expect(g.descent, closeTo(40, 0.1));
  });

  group('RouteTrack', () {
    final line = northLine(const LatLng(47, 8), 101, 100); // 10 km
    final leg1 = Leg(points: line.sublist(0, 51), hints: const [TurnHint(10, 2)]);
    final leg2 = Leg(points: line.sublist(50), hints: const [TurnHint(5, 5)]);
    final track = RouteTrack.fromLegs([leg1, leg2]);

    test('joins legs without duplicating the junction', () {
      expect(track.points.length, 101);
      expect(track.length, closeTo(10000, 5));
      expect(track.legStarts, [0, 50]);
    });

    test('hints are positioned along the whole route', () {
      expect(track.hints.map((h) => h.along.round()), [1000, 5500]);
      expect(track.nextHint(0)!.command, 2);
      expect(track.nextHint(1200)!.command, 5);
      expect(track.nextHint(6000), isNull);
    });

    test('nearest and pointAt', () {
      final p = track.pointAt(2500);
      final east = LatLng(p.latitude, p.longitude + 0.004); // ~300 m east
      final m = track.nearest(east, radius: 1000)!;
      expect(m.along, closeTo(2500, 5));
      expect(m.offset, closeTo(303, 5));
      expect(track.nearest(east, radius: 100), isNull);
    });

    test('long straight segments are densified', () {
      final t = RouteTrack.fromLegs([Leg.straight(const LatLng(47, 8), const LatLng(47, 9))]);
      expect(t.points.length, greaterThan(70));
      expect(t.length, closeTo(75800, 200));
      // A point in the middle of the long segment is still found by the grid.
      expect(t.nearest(const LatLng(47.001, 8.5), radius: 500), isNotNull);
    });

    test('out-and-back routes yield two passes', () {
      final out = northLine(const LatLng(47, 8), 51, 100);
      final back = out.reversed.toList();
      final t = RouteTrack.fromLegs([Leg(points: out), Leg(points: back)]);
      final passes = t.passesNear(t.pointAt(2000), 200);
      expect(passes.length, 2);
      expect(passes[0].along, closeTo(2000, 5));
      expect(passes[1].along, closeTo(8000, 5));
    });

    test('match prefers the stretch around the previous position', () {
      final out = northLine(const LatLng(47, 8), 51, 100);
      final t = RouteTrack.fromLegs([Leg(points: out), Leg(points: out.reversed.toList())]);
      // Both passes are equally close; the previous match decides.
      final back = t.passesNear(t.pointAt(7000), 50).last;
      expect(back.along, closeTo(7000, 5));
      final m = t.match(t.pointAt(7100), previous: back)!;
      expect(m.along, closeTo(7100, 5));
    });

    test('placePois respects category radius', () {
      final p = track.pointAt(4000);
      final water = poi('n1', LatLng(p.latitude, p.longitude + 0.004), 'water'); // 300 m
      final farWater = poi('n2', LatLng(p.latitude, p.longitude + 0.01), 'water'); // 760 m
      final camp = poi('n3', LatLng(p.latitude, p.longitude + 0.04), 'camping'); // 3 km
      final placed = track.placePois([water, farWater, camp]);
      expect(placed.map((e) => e.poi.id), ['n1', 'n3']);
      expect(placed.first.along, closeTo(4000, 5));
      expect(placed.first.detour, closeTo(placed.first.offset * 2.5, 0.01));
      expect(track.placePois([farWater], radiusFactor: 2).length, 1);
    });

    test('chunk bounds cover the route', () {
      final chunks = track.chunkBounds(3000);
      expect(chunks.length, 4);
      for (final p in track.points) {
        expect(chunks.any((c) => c.contains(p)), isTrue);
      }
    });

    test('simplify keeps corners and drops collinear points', () {
      final pts = [
        ...northLine(const LatLng(47, 8), 20, 50),
        const LatLng(47.0086, 8.01),
      ];
      final keep = simplifyIndices(pts, 2);
      expect(keep, [0, 19, 20]);
    });
  });

  group('PoiCategory', () {
    test('classify uses tag filters', () {
      expect(PoiCategory.classify({'amenity': 'drinking_water'})!.id, 'water');
      expect(PoiCategory.classify({'man_made': 'water_tap', 'drinking_water': 'yes'})!.id, 'water');
      expect(PoiCategory.classify({'man_made': 'water_tap'}), isNull);
      expect(PoiCategory.classify({'railway': 'station', 'station': 'subway'}), isNull);
      expect(PoiCategory.classify({'tourism': 'camp_site'})!.id, 'camping');
    });

    test('overpass selectors', () {
      expect(const TagFilter('amenity', ['toilets']).toOverpass(), '["amenity"="toilets"]');
      expect(const TagFilter('shop', ['a', 'b']).toOverpass(), r'["shop"~"^(a|b)$"]');
      expect(
          const TagFilter('natural', ['spring'], require: {'drinking_water': 'yes'}).toOverpass(),
          '["natural"="spring"]["drinking_water"="yes"]');
    });
  });

  group('RoutePathFinder', () {
    test('picks one of two parallel alternatives and skips the detour', () {
      // Main line going north 20 km; an alternative leaves it at km 5 and
      // rejoins at km 15 with a 6 km eastward bulge (longer).
      final main = northLine(const LatLng(47, 8), 201, 100);
      final bulge = [
        main[50],
        const LatLng(47.0675, 8.08),
        const LatLng(47.1124, 8.08),
        main[150],
      ];
      final tail = northLine(main.last, 50, 100); // listed separately
      final out = RoutePathFinder.bestPath([main, bulge, tail], main.first, tail.last);
      expect(out.length, 1);
      expect(RouteAssembly.length([out.single]), closeTo(24900, 50));
    });

    test('crosses an unmapped gap only when needed', () {
      final a = northLine(const LatLng(47, 8), 51, 100);
      final b = northLine(LatLng(a.last.latitude + 0.02, 8), 51, 100); // ~2.2 km gap
      final out = RoutePathFinder.bestPath([b, a], a.first, b.last);
      expect(out.length, 2);
      expect(out.first.first, a.first);
      expect(out.last.last, b.last);
    });

    test('drops fragments and reorders listed members', () {
      final a = northLine(const LatLng(47, 8), 21, 100);
      final b = northLine(a.last, 21, 100);
      final c = northLine(b.last, 21, 100);
      final fragment = northLine(const LatLng(47.3, 8.2), 3, 10);
      final joined = RouteAssembly.joinRoute([
        [a],
        [c],
        [fragment],
        [b.reversed.toList()],
      ]);
      expect(joined.length, 1);
      expect(RouteAssembly.length(joined), closeTo(6000, 10));
    });
  });
}
