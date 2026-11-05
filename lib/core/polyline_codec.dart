import 'package:latlong2/latlong.dart';

/// Compact text encoding for long tracks, based on the Google encoded
/// polyline algorithm. Coordinates use 1e-6 degree precision; elevation is
/// stored separately in decimeters. A 3000 km tour encodes to a few MB.
class PolylineCodec {
  static const int _coordFactor = 1000000;

  static String encodePoints(List<LatLng> points) {
    final buf = StringBuffer();
    var lastLat = 0, lastLon = 0;
    for (final p in points) {
      final lat = (p.latitude * _coordFactor).round();
      final lon = (p.longitude * _coordFactor).round();
      _encodeValue(lat - lastLat, buf);
      _encodeValue(lon - lastLon, buf);
      lastLat = lat;
      lastLon = lon;
    }
    return buf.toString();
  }

  static List<LatLng> decodePoints(String encoded) {
    final values = _decodeValues(encoded);
    if (values.length.isOdd) {
      throw const FormatException('corrupt polyline: odd number of values');
    }
    final out = <LatLng>[];
    var lat = 0, lon = 0;
    for (var i = 0; i < values.length; i += 2) {
      lat += values[i];
      lon += values[i + 1];
      out.add(LatLng(lat / _coordFactor, lon / _coordFactor));
    }
    return out;
  }

  /// Elevations in meters, stored with 0.1 m resolution.
  static String encodeElevations(List<double> elevations) {
    final buf = StringBuffer();
    var last = 0;
    for (final e in elevations) {
      final v = (e * 10).round();
      _encodeValue(v - last, buf);
      last = v;
    }
    return buf.toString();
  }

  static List<double> decodeElevations(String encoded) {
    var v = 0;
    return [
      for (final d in _decodeValues(encoded)) (v += d) / 10.0,
    ];
  }

  static void _encodeValue(int value, StringBuffer buf) {
    var v = value < 0 ? ~(value << 1) : (value << 1);
    while (v >= 0x20) {
      buf.writeCharCode((0x20 | (v & 0x1f)) + 63);
      v >>= 5;
    }
    buf.writeCharCode(v + 63);
  }

  static List<int> _decodeValues(String encoded) {
    final out = <int>[];
    var index = 0;
    final len = encoded.length;
    while (index < len) {
      var shift = 0, result = 0, b = 0;
      do {
        if (index >= len) {
          throw const FormatException('corrupt polyline: truncated value');
        }
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      out.add((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
    }
    return out;
  }
}
