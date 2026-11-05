import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

/// One OSM tag condition: `key` has one of [values] (any value if empty),
/// plus optional extra required / excluded tag values.
class TagFilter {
  final String key;
  final List<String> values;
  final Map<String, String> require;
  final Map<String, String> exclude;

  const TagFilter(this.key, this.values,
      {this.require = const {}, this.exclude = const {}});

  bool matches(Map<String, String> tags) {
    final v = tags[key];
    if (v == null) return false;
    if (values.isNotEmpty && !values.contains(v)) return false;
    for (final e in require.entries) {
      if (tags[e.key] != e.value) return false;
    }
    for (final e in exclude.entries) {
      if (tags[e.key] == e.value) return false;
    }
    return true;
  }

  /// Overpass QL tag selector, e.g. `["amenity"~"^(toilets|shower)$"]`.
  String toOverpass() {
    final b = StringBuffer();
    if (values.isEmpty) {
      b.write('["$key"]');
    } else if (values.length == 1) {
      b.write('["$key"="${values.first}"]');
    } else {
      b.write('["$key"~"^(${values.join('|')})\$"]');
    }
    for (final e in require.entries) {
      b.write('["${e.key}"="${e.value}"]');
    }
    for (final e in exclude.entries) {
      b.write('["${e.key}"!="${e.value}"]');
    }
    return b.toString();
  }
}

/// A searchable kind of place (water, supermarket, camping, ...).
class PoiCategory {
  final String id;
  final String label;
  final IconData icon;
  final Color color;

  /// Default maximum straight-line distance from the route, in meters.
  final double radius;
  final List<TagFilter> filters;

  const PoiCategory({
    required this.id,
    required this.label,
    required this.icon,
    required this.color,
    required this.radius,
    required this.filters,
  });

  bool matches(Map<String, String> tags) => filters.any((f) => f.matches(tags));

  static PoiCategory? byId(String id) {
    for (final c in all) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// First category matching [tags], in priority order.
  static PoiCategory? classify(Map<String, String> tags) {
    for (final c in all) {
      if (c.matches(tags)) return c;
    }
    return null;
  }

  static const all = <PoiCategory>[
    PoiCategory(
      id: 'water',
      label: 'Drinking water',
      icon: Icons.water_drop,
      color: Color(0xFF1E88E5),
      radius: 500,
      filters: [
        TagFilter('amenity', ['drinking_water', 'water_point']),
        TagFilter('man_made', ['water_tap', 'water_well'],
            require: {'drinking_water': 'yes'}),
        TagFilter('natural', ['spring'], require: {'drinking_water': 'yes'}),
      ],
    ),
    PoiCategory(
      id: 'toilets',
      label: 'Toilets',
      icon: Icons.wc,
      color: Color(0xFF6D4C41),
      radius: 500,
      filters: [TagFilter('amenity', ['toilets'])],
    ),
    PoiCategory(
      id: 'shower',
      label: 'Showers',
      icon: Icons.shower,
      color: Color(0xFF00897B),
      radius: 1000,
      filters: [TagFilter('amenity', ['shower'])],
    ),
    PoiCategory(
      id: 'supermarket',
      label: 'Supermarkets',
      icon: Icons.shopping_cart,
      color: Color(0xFF43A047),
      radius: 2000,
      filters: [
        TagFilter('shop', ['supermarket', 'convenience', 'general', 'greengrocer']),
      ],
    ),
    PoiCategory(
      id: 'bakery',
      label: 'Bakeries',
      icon: Icons.bakery_dining,
      color: Color(0xFFF9A825),
      radius: 1000,
      filters: [TagFilter('shop', ['bakery'])],
    ),
    PoiCategory(
      id: 'food',
      label: 'Restaurants & cafés',
      icon: Icons.restaurant,
      color: Color(0xFFE64A19),
      radius: 1000,
      filters: [
        TagFilter('amenity', ['restaurant', 'cafe', 'fast_food', 'pub', 'biergarten']),
      ],
    ),
    PoiCategory(
      id: 'camping',
      label: 'Campsites',
      icon: Icons.festival,
      color: Color(0xFF2E7D32),
      radius: 5000,
      filters: [TagFilter('tourism', ['camp_site'])],
    ),
    PoiCategory(
      id: 'accommodation',
      label: 'Accommodation',
      icon: Icons.hotel,
      color: Color(0xFF8E24AA),
      radius: 3000,
      filters: [
        TagFilter('tourism',
            ['hotel', 'hostel', 'guest_house', 'motel', 'alpine_hut', 'chalet', 'apartment']),
      ],
    ),
    PoiCategory(
      id: 'shelter',
      label: 'Shelters & huts',
      icon: Icons.cabin,
      color: Color(0xFF795548),
      radius: 1000,
      filters: [
        TagFilter('amenity', ['shelter']),
        TagFilter('tourism', ['wilderness_hut']),
      ],
    ),
    PoiCategory(
      id: 'bike',
      label: 'Bike shops & repair',
      icon: Icons.pedal_bike,
      color: Color(0xFFD81B60),
      radius: 3000,
      filters: [
        TagFilter('shop', ['bicycle']),
        TagFilter('amenity', ['bicycle_repair_station']),
      ],
    ),
    PoiCategory(
      id: 'pharmacy',
      label: 'Pharmacies',
      icon: Icons.local_pharmacy,
      color: Color(0xFFC62828),
      radius: 3000,
      filters: [TagFilter('amenity', ['pharmacy'])],
    ),
    PoiCategory(
      id: 'atm',
      label: 'ATMs',
      icon: Icons.atm,
      color: Color(0xFF546E7A),
      radius: 2000,
      filters: [TagFilter('amenity', ['atm'])],
    ),
    PoiCategory(
      id: 'station',
      label: 'Train stations',
      icon: Icons.train,
      color: Color(0xFF3949AB),
      radius: 5000,
      filters: [
        TagFilter('railway', ['station', 'halt'], exclude: {'station': 'subway'}),
      ],
    ),
  ];
}

/// A point of interest from OpenStreetMap.
class Poi {
  /// OSM id with type prefix, e.g. `n123`, `w456`.
  final String id;
  final LatLng position;
  final String category;
  final Map<String, String> tags;

  const Poi({
    required this.id,
    required this.position,
    required this.category,
    required this.tags,
  });

  PoiCategory get cat => PoiCategory.byId(category) ?? PoiCategory.all.first;

  String get name {
    final n = tags['name'] ?? tags['brand'] ?? tags['operator'];
    if (n != null && n.isNotEmpty) return n;
    final kind = tags['amenity'] ?? tags['shop'] ?? tags['tourism'] ??
        tags['man_made'] ?? tags['natural'] ?? tags['railway'];
    if (kind != null) {
      final s = kind.replaceAll('_', ' ');
      return s[0].toUpperCase() + s.substring(1);
    }
    return cat.label;
  }

  String get osmUrl {
    const types = {'n': 'node', 'w': 'way', 'r': 'relation'};
    return 'https://www.openstreetmap.org/${types[id[0]] ?? 'node'}/${id.substring(1)}';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'lat': position.latitude,
        'lon': position.longitude,
        'cat': category,
        'tags': tags,
      };

  factory Poi.fromJson(Map<String, dynamic> j) => Poi(
        id: j['id'] as String,
        position: LatLng((j['lat'] as num).toDouble(), (j['lon'] as num).toDouble()),
        category: j['cat'] as String,
        tags: (j['tags'] as Map).cast<String, String>(),
      );
}

/// A POI positioned relative to a route.
class PoiOnRoute {
  final Poi poi;

  /// Distance from the route start to the closest route point, in meters.
  final double along;

  /// Straight-line distance from the route to the POI, in meters.
  final double offset;

  const PoiOnRoute(this.poi, this.along, this.offset);

  /// Estimated extra riding for going there and back. Roads are rarely
  /// straight, hence the factor on top of the out-and-back distance.
  double get detour => offset < 30 ? 0 : offset * 2 * 1.25;
}
