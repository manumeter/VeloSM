import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MapStyle {
  final String id;
  final String label;
  final String url;
  final List<String> subdomains;
  final int maxZoom;
  final String attribution;

  const MapStyle(this.id, this.label, this.url, this.attribution,
      {this.subdomains = const [], this.maxZoom = 19});

  static const all = [
    MapStyle('cyclosm', 'CyclOSM (cycling)',
        'https://{s}.tile-cyclosm.openstreetmap.fr/cyclosm/{z}/{x}/{y}.png',
        'CyclOSM, © OpenStreetMap contributors',
        subdomains: ['a', 'b', 'c'], maxZoom: 20),
    MapStyle('osm', 'OpenStreetMap', 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
        '© OpenStreetMap contributors'),
    MapStyle('topo', 'OpenTopoMap (terrain)', 'https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png',
        'OpenTopoMap (CC-BY-SA), © OpenStreetMap contributors',
        subdomains: ['a', 'b', 'c'], maxZoom: 17),
  ];

  static const cycleRoutesOverlay = MapStyle(
      'wmt', 'Signposted cycle routes', 'https://tile.waymarkedtrails.org/cycling/{z}/{x}/{y}.png',
      'Waymarked Trails (CC-BY-SA)');
}

/// User preferences, persisted with shared_preferences.
class Settings extends ChangeNotifier {
  final SharedPreferences _prefs;

  Settings(this._prefs);

  static Future<Settings> load() async => Settings(await SharedPreferences.getInstance());

  String _s(String k, String d) => _prefs.getString(k) ?? d;

  MapStyle get mapStyle {
    final custom = customTileUrl;
    if (_s('mapStyle', 'cyclosm') == 'custom' && custom.isNotEmpty) {
      return MapStyle('custom', 'Custom', custom, 'Custom tiles, © OpenStreetMap contributors',
          subdomains: const ['a', 'b', 'c']);
    }
    return MapStyle.all.firstWhere((m) => m.id == _s('mapStyle', 'cyclosm'),
        orElse: () => MapStyle.all.first);
  }

  String get mapStyleId => _s('mapStyle', 'cyclosm');
  set mapStyleId(String v) => _set('mapStyle', v);

  /// e.g. a Thunderforest OpenCycleMap URL with API key.
  String get customTileUrl => _s('customTileUrl', '');
  set customTileUrl(String v) => _set('customTileUrl', v.trim());

  bool get cycleRoutesOverlay => _prefs.getBool('cycleOverlay') ?? true;
  set cycleRoutesOverlay(bool v) => _setBool('cycleOverlay', v);

  String get brouterUrl => _s('brouterUrl', 'https://brouter.de');
  set brouterUrl(String v) => _set('brouterUrl', v.trim());

  List<String> get overpassServers => _s('overpassUrls',
          'https://overpass-api.de/api/interpreter\nhttps://overpass.private.coffee/api/interpreter')
      .split('\n')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  set overpassServers(List<String> v) => _set('overpassUrls', v.join('\n'));

  String get defaultProfile => _s('profile', 'trekking');
  set defaultProfile(String v) => _set('profile', v);

  bool get stickToCycleRoutes => _prefs.getBool('stickToCycleRoutes') ?? true;
  set stickToCycleRoutes(bool v) => _setBool('stickToCycleRoutes', v);

  double get dayLengthKm => _prefs.getDouble('dayLengthKm') ?? 80;
  set dayLengthKm(double v) {
    _prefs.setDouble('dayLengthKm', v);
    notifyListeners();
  }

  /// Multiplier on each category's default search radius.
  double get poiRadiusFactor => _prefs.getDouble('poiRadiusFactor') ?? 1;
  set poiRadiusFactor(double v) {
    _prefs.setDouble('poiRadiusFactor', v);
    notifyListeners();
  }

  Set<String> get poiCategories =>
      (_prefs.getStringList('poiCategories') ??
              ['water', 'toilets', 'supermarket', 'bakery', 'camping', 'accommodation', 'bike'])
          .toSet();
  set poiCategories(Set<String> v) {
    _prefs.setStringList('poiCategories', v.toList());
    notifyListeners();
  }

  bool get keepScreenOn => _prefs.getBool('keepScreenOn') ?? true;
  set keepScreenOn(bool v) => _setBool('keepScreenOn', v);

  void _set(String k, String v) {
    _prefs.setString(k, v);
    notifyListeners();
  }

  void _setBool(String k, bool v) {
    _prefs.setBool(k, v);
    notifyListeners();
  }
}
