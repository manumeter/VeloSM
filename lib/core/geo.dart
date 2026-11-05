import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Mean earth radius in meters (WGS84 sphere approximation).
const double earthRadiusM = 6371008.8;

double _rad(double deg) => deg * math.pi / 180.0;

/// Great-circle distance between two points in meters.
double haversine(LatLng a, LatLng b) {
  final dLat = _rad(b.latitude - a.latitude);
  final dLon = _rad(b.longitude - a.longitude);
  final la1 = _rad(a.latitude);
  final la2 = _rad(b.latitude);
  final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(la1) * math.cos(la2) * math.sin(dLon / 2) * math.sin(dLon / 2);
  return 2 * earthRadiusM * math.asin(math.min(1.0, math.sqrt(h)));
}

/// Initial bearing from [a] to [b] in degrees (0..360, 0 = north).
double bearing(LatLng a, LatLng b) {
  final la1 = _rad(a.latitude);
  final la2 = _rad(b.latitude);
  final dLon = _rad(b.longitude - a.longitude);
  final y = math.sin(dLon) * math.cos(la2);
  final x = math.cos(la1) * math.sin(la2) -
      math.sin(la1) * math.cos(la2) * math.cos(dLon);
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}

/// Linear interpolation between two coordinates (fine for short segments).
LatLng lerpLatLng(LatLng a, LatLng b, double t) => LatLng(
      a.latitude + (b.latitude - a.latitude) * t,
      a.longitude + (b.longitude - a.longitude) * t,
    );

/// Result of projecting a point onto a segment a-b.
class SegmentProjection {
  /// Position along the segment, clamped to 0..1.
  final double t;

  /// Distance from the point to the projected point, in meters.
  final double distance;

  const SegmentProjection(this.t, this.distance);
}

/// Projects [p] onto segment [a]-[b] using a local equirectangular
/// approximation (accurate for segments up to a few kilometers).
SegmentProjection projectOnSegment(LatLng p, LatLng a, LatLng b) {
  final cosLat = math.cos(_rad(p.latitude));
  final ax = (a.longitude - p.longitude) * cosLat;
  final ay = a.latitude - p.latitude;
  final bx = (b.longitude - p.longitude) * cosLat;
  final by = b.latitude - p.latitude;
  final dx = bx - ax;
  final dy = by - ay;
  final len2 = dx * dx + dy * dy;
  var t = len2 == 0 ? 0.0 : -(ax * dx + ay * dy) / len2;
  if (t < 0) t = 0;
  if (t > 1) t = 1;
  final qx = ax + dx * t;
  final qy = ay + dy * t;
  final d = math.sqrt(qx * qx + qy * qy) * _rad(1) * earthRadiusM;
  return SegmentProjection(t, d);
}

/// Spherical web-mercator (EPSG:3857) meters to WGS84.
LatLng fromWebMercator(double x, double y) {
  final lon = x / 6378137.0 * 180 / math.pi;
  final lat =
      (2 * math.atan(math.exp(y / 6378137.0)) - math.pi / 2) * 180 / math.pi;
  return LatLng(lat, lon);
}

/// Axis-aligned bounding box in degrees.
class GeoBounds {
  double south, west, north, east;

  GeoBounds(this.south, this.west, this.north, this.east);

  factory GeoBounds.of(Iterable<LatLng> points) {
    final it = points.iterator;
    if (!it.moveNext()) throw ArgumentError('empty point list');
    final b = GeoBounds(it.current.latitude, it.current.longitude,
        it.current.latitude, it.current.longitude);
    while (it.moveNext()) {
      b.extend(it.current);
    }
    return b;
  }

  void extend(LatLng p) {
    if (p.latitude < south) south = p.latitude;
    if (p.latitude > north) north = p.latitude;
    if (p.longitude < west) west = p.longitude;
    if (p.longitude > east) east = p.longitude;
  }

  /// Grows the box by [meters] on every side.
  GeoBounds expanded(double meters) {
    final dLat = meters / earthRadiusM * 180 / math.pi;
    final midLat = (south + north) / 2;
    final dLon = dLat / math.max(0.01, math.cos(_rad(midLat)));
    return GeoBounds(math.max(-90, south - dLat), west - dLon,
        math.min(90, north + dLat), east + dLon);
  }

  bool contains(LatLng p) =>
      p.latitude >= south &&
      p.latitude <= north &&
      p.longitude >= west &&
      p.longitude <= east;

  /// Overpass bbox order: south,west,north,east.
  String toOverpass() => '${south.toStringAsFixed(5)},${west.toStringAsFixed(5)},'
      '${north.toStringAsFixed(5)},${east.toStringAsFixed(5)}';
}

/// Human readable distance: "850 m", "12.4 km", "1,234 km".
String formatDistance(double meters) {
  if (meters.isNaN || meters.isInfinite) return '–';
  final m = meters.abs();
  if (m < 1000) return '${(m / 10).round() * 10} m';
  if (m < 100000) return '${(m / 1000).toStringAsFixed(1)} km';
  final km = (m / 1000).round().toString();
  final buf = StringBuffer();
  for (var i = 0; i < km.length; i++) {
    if (i > 0 && (km.length - i) % 3 == 0) buf.write(',');
    buf.write(km[i]);
  }
  return '$buf km';
}

String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  return h > 0 ? '${h}h ${m.toString().padLeft(2, '0')}' : '$m min';
}
