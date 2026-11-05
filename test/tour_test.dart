import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:velosm/core/gpx.dart';
import 'package:velosm/core/stage_planner.dart';
import 'package:velosm/models/tour.dart';

import 'core_test.dart' show northLine;

/// A 300 km straight tour made of three 100 km routed legs.
Tour sampleTour() {
  final line = northLine(const LatLng(45, 8), 3001, 100);
  final wps = [
    for (final i in [0, 1000, 2000, 3000]) Waypoint(id: 'w$i', position: line[i]),
  ];
  return Tour(
    id: 't1',
    name: 'Sample',
    waypoints: wps,
    legs: [
      for (final i in [0, 1000, 2000])
        Leg(
          points: line.sublist(i, i + 1001),
          elevations: [for (var k = 0; k <= 1000; k++) 400.0 + (k % 200 < 100 ? k % 100 : 100 - k % 100)],
        ),
    ],
  );
}

void main() {
  test('stages follow overnight flags', () {
    final t = sampleTour();
    expect(t.stages.length, 1);
    t.waypoints[1].overnight = true;
    final s = t.stages;
    expect(s.length, 2);
    expect(s[0].distance, closeTo(100000, 50));
    expect(s[1].distance, closeTo(200000, 100));
    expect(s[1].startOffset, closeTo(100000, 50));
    expect(s[0].ascent, greaterThan(400));
  });

  test('json round trip', () {
    final t = sampleTour()..waypoints[2].overnight = true;
    t.legs[1] = null;
    final back = Tour.fromJson(t.toJson());
    expect(back.waypoints.length, 4);
    expect(back.legs[1], isNull);
    expect(back.legs[0]!.points.length, 1001);
    expect(back.legs[0]!.elevations.length, 1001);
    expect(back.distance, closeTo(t.distance, 1));
    expect(back.stages.length, 2);
  });

  test('leg split and join are inverse', () {
    final leg = sampleTour().legs.first!;
    final (a, b) = leg.splitAt(400, 0.5);
    expect(a.distance + b.distance, closeTo(leg.distance, 0.01));
    final j = a.join(b);
    expect(j.points.length, leg.points.length + 1);
    expect(j.distance, closeTo(leg.distance, 0.01));
  });

  test('splitAt inserts an overnight waypoint', () {
    final t = sampleTour();
    final rev = t.revision;
    final wp = StagePlanner.splitAt(t, 150000)!;
    expect(wp.overnight, isTrue);
    expect(t.waypoints.length, 5);
    expect(t.legs.length, 4);
    expect(t.stages.length, 2);
    expect(t.stages.first.distance, closeTo(150000, 100));
    expect(t.distance, closeTo(300000, 100));
    expect(t.revision, greaterThan(rev));
  });

  test('splitAt near an existing waypoint marks it instead', () {
    final t = sampleTour();
    final wp = StagePlanner.splitAt(t, 100020)!;
    expect(wp.id, 'w1000');
    expect(t.waypoints.length, 4);
  });

  test('planDays splits evenly and keeps user stops', () {
    final t = sampleTour()..waypoints[1].overnight = true; // user stop at 100 km
    final n = StagePlanner.planDays(t, 70000);
    // 100 km → 1 day (round(1.43)=1); 200 km → 3 days.
    expect(n, 2);
    final s = t.stages;
    expect(s.length, 4);
    expect(s[0].distance, closeTo(100000, 100));
    for (final d in s.skip(1)) {
      expect(d.distance, closeTo(66667, 200));
    }
    // Re-planning removes the previous automatic stops first.
    StagePlanner.planDays(t, 150000);
    expect(t.stages.length, 2);
    expect(t.waypoints.where((w) => w.auto), isEmpty);
    expect(t.distance, closeTo(300000, 100));
  });

  test('planDays snaps to campsites near the ideal position', () {
    final t = sampleTour();
    final n = StagePlanner.planDays(t, 100000, candidates: const [
      StopCandidate(92000, 'Camping Nord'),
      StopCandidate(140000, 'Too far'),
      StopCandidate(205000, 'Camping Süd'),
    ]);
    expect(n, 2);
    final s = t.stages;
    expect(s[0].distance, closeTo(92000, 100));
    expect(s[0].end.name, 'Camping Nord');
    expect(s[1].end.name, 'Camping Süd');
  });

  test('planDays requires a routed tour', () {
    final t = sampleTour();
    t.legs[0] = null;
    expect(() => StagePlanner.planDays(t, 50000), throwsStateError);
  });

  group('GPX', () {
    test('write and read back, one track per day', () {
      final t = sampleTour()..waypoints[2].overnight = true;
      final xml = Gpx.write(t);
      final gpx = Gpx.parse(xml);
      expect(gpx.name, 'Sample');
      expect(gpx.tracks.length, 2);
      expect(gpx.waypoints.length, 2);
      final back = Gpx.toTour(gpx);
      expect(back.stages.length, 2);
      expect(back.distance, closeTo(t.distance, 100));
      expect(back.legs.every((l) => l!.source == LegSource.track), isTrue);
      // Straight input collapses to very few points after simplification.
      expect(back.legs.first!.points.length, lessThan(10));
      expect(back.legs.first!.hasElevation, isTrue);
    });

    test('parses GPX 1.0 routes without namespace prefix issues', () {
      const xml = '''<?xml version="1.0"?>
<gpx version="1.0" xmlns="http://www.topografix.com/GPX/1/0">
  <rte><name>R</name>
    <rtept lat="47.0" lon="8.0"/><rtept lat="47.1" lon="8.0"/><rtept lat="47.2" lon="8.1"/>
  </rte>
  <wpt lat="47.1" lon="8.0"><name>Water</name></wpt>
</gpx>''';
      final gpx = Gpx.parse(xml);
      expect(gpx.tracks.single.points.length, 3);
      expect(gpx.tracks.single.elevations, isEmpty);
      expect(gpx.waypoints.single.name, 'Water');
      final t = Gpx.toTour(gpx);
      expect(t.waypoints.length, 2);
      expect(t.stages.length, 1);
    });

    test('gaps between tracks become unrouted legs', () {
      const xml = '''<gpx xmlns="http://www.topografix.com/GPX/1/1">
<trk><name>Day 1</name><trkseg><trkpt lat="47.0" lon="8.0"/><trkpt lat="47.1" lon="8.0"/></trkseg></trk>
<trk><name>Day 2</name><trkseg><trkpt lat="47.2" lon="8.0"/><trkpt lat="47.3" lon="8.0"/></trkseg></trk>
</gpx>''';
      final t = Gpx.toTour(Gpx.parse(xml));
      expect(t.legs.length, 3);
      expect(t.legs[1], isNull);
      expect(t.waypoints[1].overnight, isTrue);
      expect(t.waypoints[1].name, 'Day 1');
    });
  });
}
