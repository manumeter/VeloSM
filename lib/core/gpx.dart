import 'package:latlong2/latlong.dart';
import 'package:uuid/uuid.dart';
import 'package:xml/xml.dart';

import '../models/poi.dart';
import '../models/tour.dart';
import 'geo.dart';
import 'route_track.dart';

const _uuid = Uuid();

class GpxTrack {
  final String? name;
  final List<LatLng> points;
  final List<double> elevations;

  GpxTrack(this.name, this.points, this.elevations);
}

class GpxWaypoint {
  final String? name;
  final LatLng position;

  GpxWaypoint(this.name, this.position);
}

class GpxData {
  final String? name;
  final List<GpxTrack> tracks;
  final List<GpxWaypoint> waypoints;

  GpxData(this.name, this.tracks, this.waypoints);
}

/// GPX 1.0/1.1 reader and writer.
class Gpx {
  static GpxData parse(String text) {
    final doc = XmlDocument.parse(text);
    final root = doc.rootElement;
    String? childText(XmlElement e, String name) {
      for (final c in e.childElements) {
        if (c.localName == name) {
          final t = c.innerText.trim();
          return t.isEmpty ? null : t;
        }
      }
      return null;
    }

    LatLng? pos(XmlElement e) {
      final lat = double.tryParse(e.getAttribute('lat') ?? '');
      final lon = double.tryParse(e.getAttribute('lon') ?? '');
      if (lat == null || lon == null) return null;
      return LatLng(lat, lon);
    }

    GpxTrack? readPoints(String? name, Iterable<XmlElement> pts) {
      final points = <LatLng>[];
      final ele = <double>[];
      var hasEle = true;
      for (final p in pts) {
        final ll = pos(p);
        if (ll == null) continue;
        points.add(ll);
        final e = double.tryParse(childText(p, 'ele') ?? '');
        if (e == null) hasEle = false;
        ele.add(e ?? double.nan);
      }
      if (points.length < 2) return null;
      return GpxTrack(name, points, hasEle ? ele : const []);
    }

    final tracks = <GpxTrack>[];
    for (final trk in root.findAllElements('trk', namespaceUri: '*')) {
      final t = readPoints(childText(trk, 'name'),
          trk.findAllElements('trkpt', namespaceUri: '*'));
      if (t != null) tracks.add(t);
    }
    for (final rte in root.findAllElements('rte', namespaceUri: '*')) {
      final t = readPoints(childText(rte, 'name'),
          rte.findAllElements('rtept', namespaceUri: '*'));
      if (t != null) tracks.add(t);
    }
    final wpts = <GpxWaypoint>[
      for (final w in root.findElements('wpt', namespaceUri: '*'))
        if (pos(w) != null) GpxWaypoint(childText(w, 'name'), pos(w)!),
    ];
    String? name;
    for (final m in root.findElements('metadata', namespaceUri: '*')) {
      name = childText(m, 'name');
    }
    name ??= tracks.isNotEmpty ? tracks.first.name : null;
    return GpxData(name, tracks, wpts);
  }

  /// Builds a tour from parsed GPX. Each track becomes one day, which matches
  /// how most multi-day GPX files are organized. Tracks are simplified to
  /// ~[tolerance] meters to keep huge files manageable.
  static Tour toTour(GpxData gpx, {String? fallbackName, double tolerance = 2}) {
    final tour = Tour(
      id: _uuid.v4(),
      name: gpx.name ?? fallbackName ?? 'Imported tour',
    );
    for (final t in gpx.tracks) {
      final keep = simplifyIndices(t.points, tolerance);
      final leg = Leg(
        points: [for (final i in keep) t.points[i]],
        elevations: t.elevations.isEmpty ? const [] : [for (final i in keep) t.elevations[i]],
        source: LegSource.track,
      );
      if (tour.waypoints.isEmpty) {
        tour.waypoints.add(Waypoint(id: _uuid.v4(), position: leg.points.first));
      } else if (haversine(tour.waypoints.last.position, leg.points.first) > 20) {
        // Gap between tracks: connect with a straight line (routable later).
        tour.waypoints.add(Waypoint(id: _uuid.v4(), position: leg.points.first));
        tour.legs.add(null);
      }
      tour.waypoints.add(Waypoint(
        id: _uuid.v4(),
        position: leg.points.last,
        overnight: gpx.tracks.length > 1,
        name: gpx.tracks.length > 1 ? t.name : null,
      ));
      tour.legs.add(leg);
    }
    if (tour.waypoints.isNotEmpty) tour.waypoints.last.overnight = false;
    tour.touch();
    return tour;
  }

  /// Writes the tour with one `<trk>` per day, overnight stops as `<wpt>`
  /// and optionally a list of POIs as additional waypoints.
  static String write(Tour tour, {List<Poi> pois = const []}) {
    final b = XmlBuilder();
    b.processing('xml', 'version="1.0" encoding="UTF-8"');
    b.element('gpx', attributes: {
      'version': '1.1',
      'creator': 'VeloSM',
      'xmlns': 'http://www.topografix.com/GPX/1/1',
    }, nest: () {
      b.element('metadata', nest: () {
        b.element('name', nest: tour.name);
        b.element('time', nest: tour.updated.toUtc().toIso8601String());
      });
      void wpt(LatLng p, String name, [String? type]) {
        b.element('wpt', attributes: {
          'lat': p.latitude.toStringAsFixed(6),
          'lon': p.longitude.toStringAsFixed(6),
        }, nest: () {
          b.element('name', nest: name);
          if (type != null) b.element('type', nest: type);
        });
      }

      for (final s in tour.stages) {
        wpt(s.end.position, s.end.name ?? 'End of day ${s.number}', 'overnight');
      }
      for (final p in pois) {
        wpt(p.position, p.name, p.cat.label);
      }
      for (final s in tour.stages) {
        b.element('trk', nest: () {
          b.element('name', nest: 'Day ${s.number}: ${s.title}');
          b.element('trkseg', nest: () {
            LatLng? last;
            for (var li = s.firstLeg; li < s.endLeg; li++) {
              final leg = tour.legs[li] ??
                  Leg.straight(tour.waypoints[li].position, tour.waypoints[li + 1].position);
              for (var i = 0; i < leg.points.length; i++) {
                final p = leg.points[i];
                if (last != null && i == 0 && haversine(last, p) < 1) continue;
                b.element('trkpt', attributes: {
                  'lat': p.latitude.toStringAsFixed(6),
                  'lon': p.longitude.toStringAsFixed(6),
                }, nest: () {
                  if (leg.hasElevation && !leg.elevations[i].isNaN) {
                    b.element('ele', nest: leg.elevations[i].toStringAsFixed(1));
                  }
                });
                last = p;
              }
            }
          });
        });
      }
    });
    return b.buildDocument().toXmlString(pretty: true);
  }
}
