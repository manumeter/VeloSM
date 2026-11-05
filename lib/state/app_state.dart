import 'package:flutter/foundation.dart';

import '../models/tour.dart';
import '../services/brouter_service.dart';
import '../services/geocoding_service.dart';
import '../services/http.dart';
import '../services/overpass_service.dart';
import '../services/storage.dart';
import '../services/waymarked_service.dart';
import 'settings.dart';

/// Wires services together and keeps the list of saved tours.
class AppState extends ChangeNotifier {
  final Settings settings;
  final TourRepository repo;
  final Http http;

  List<TourSummary> tours = [];
  bool loading = true;

  AppState({required this.settings, required this.repo, Http? http})
      : http = http ?? Http();

  BRouterService get brouter => BRouterService(http, settings.brouterUrl);
  OverpassService get overpass => OverpassService(http, settings.overpassServers);
  GeocodingService get geocoding => GeocodingService(http);
  WaymarkedService get waymarked => WaymarkedService(http);

  Future<void> refresh() async {
    tours = await repo.list();
    loading = false;
    notifyListeners();
  }

  Future<void> save(Tour tour) async {
    await repo.save(tour);
    await refresh();
  }

  Future<void> delete(String id) async {
    await repo.delete(id);
    await refresh();
  }
}
