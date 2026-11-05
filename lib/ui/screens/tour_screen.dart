import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../core/geo.dart';
import '../../core/stage_planner.dart';
import '../../models/poi.dart';
import '../../models/tour.dart';
import '../../services/brouter_service.dart';
import '../../state/app_state.dart';
import '../../state/poi_manager.dart';
import '../../state/tour_editor.dart';
import '../ui_utils.dart';
import '../widgets/base_map.dart';
import '../widgets/poi_widgets.dart';
import 'navigation_screen.dart';
import 'place_search_screen.dart';
import 'stage_screen.dart';

const stageColors = [Color(0xFF1565C0), Color(0xFF8E24AA)];

String dayDate(Tour tour, int dayNumber) {
  final start = tour.startDate;
  if (start == null) return '';
  final d = start.add(Duration(days: dayNumber - 1));
  const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return '${wd[d.weekday - 1]} ${d.day}.${d.month}.';
}

/// Tour planner: map with waypoints and route, list of days.
class TourScreen extends StatefulWidget {
  final Tour tour;

  const TourScreen({super.key, required this.tour});

  @override
  State<TourScreen> createState() => _TourScreenState();
}

class _TourScreenState extends State<TourScreen> {
  late final TourEditor editor;
  late final PoiManager pois;
  final map = MapController();
  int? _moving;
  bool _showPois = true;
  LatLngBounds? _visible;
  double _zoom = 5;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    editor = TourEditor(app, widget.tour)..addListener(_rebuild);
    pois = PoiManager(app, widget.tour)..addListener(_rebuild);
    unawaited(pois.load());
    unawaited(editor.routeMissing());
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    editor.removeListener(_rebuild);
    pois.removeListener(_rebuild);
    editor.dispose();
    pois.dispose();
    super.dispose();
  }

  Tour get tour => editor.tour;

  void _fitTour() {
    final pts = [for (final w in tour.waypoints) w.position];
    if (tour.legs.whereType<Leg>().isNotEmpty) {
      final b = GeoBounds.of(editor.track.points);
      pts.addAll([LatLng(b.south, b.west), LatLng(b.north, b.east)]);
    }
    fitTo(map, pts, padding: const EdgeInsets.fromLTRB(40, 100, 40, 260));
  }

  // ---------------------------------------------------------------- map

  List<Polyline>? _lines;
  Object? _linesKey;

  /// Route polylines, rebuilt only when the tour changes (keeping the same
  /// list lets flutter_map reuse its projection while panning).
  List<Polyline> _routeLines() {
    // `updated` changes on every edit, including overnight flags (day colors).
    final key = (tour.updated, tour.waypoints.length, editor.legErrors.length);
    if (_lines != null && _linesKey == key) return _lines!;
    final lines = <Polyline>[];
    final stages = tour.stages;
    for (final s in stages) {
      for (var li = s.firstLeg; li < s.endLeg; li++) {
        final leg = tour.legs[li];
        if (leg == null || leg.source == LegSource.straight) {
          lines.add(Polyline(
            points: leg?.points ?? [tour.waypoints[li].position, tour.waypoints[li + 1].position],
            color: editor.legError(li) != null ? Colors.red : Colors.grey,
            strokeWidth: 3,
            pattern: StrokePattern.dashed(segments: const [8, 8]),
          ));
        } else {
          lines.add(Polyline(
            points: leg.points,
            color: stageColors[(s.number - 1) % 2],
            strokeWidth: 5,
            borderColor: Colors.white,
            borderStrokeWidth: 1.5,
          ));
        }
      }
    }
    _linesKey = key;
    return _lines = lines;
  }

  List<Widget> _layers() {
    return [
      PolylineLayer(polylines: _routeLines(), simplificationTolerance: 0.6),
      if (_showPois) MarkerLayer(markers: _poiMarkers()),
      MarkerLayer(markers: _waypointMarkers()),
    ];
  }

  List<Marker> _poiMarkers() {
    if (_zoom < 11 || _visible == null) return const [];
    final cats = context.read<AppState>().settings.poiCategories;
    final out = <Marker>[];
    for (final p in pois.placed(editor.track)) {
      if (!cats.contains(p.poi.category) || !_visible!.contains(p.poi.position)) continue;
      out.add(poiMarker(p.poi, size: 26, onTap: () => _poiTapped(p)));
      if (out.length > 300) break;
    }
    return out;
  }

  List<Marker> _waypointMarkers() {
    final wps = tour.waypoints;
    final stages = tour.stages;
    final dayOf = <String, int>{for (final s in stages) s.end.id: s.number};
    return [
      for (var i = 0; i < wps.length; i++)
        Marker(
          point: wps[i].position,
          width: 34,
          height: 34,
          child: GestureDetector(
            onTap: () => _waypointTapped(i),
            child: _WaypointIcon(
              kind: i == 0
                  ? _WpKind.start
                  : i == wps.length - 1
                      ? _WpKind.end
                      : wps[i].overnight
                          ? _WpKind.overnight
                          : _WpKind.via,
              label: wps[i].overnight ? '${dayOf[wps[i].id] ?? ''}' : null,
              highlighted: _moving == i,
            ),
          ),
        ),
    ];
  }

  void _onTap(TapPosition _, LatLng p) {
    if (_moving != null) {
      editor.moveWaypoint(_moving!, p);
      setState(() => _moving = null);
    }
  }

  Future<void> _onLongPress(TapPosition _, LatLng p) async {
    final leg = editor.nearestLeg(p, radius: 3000);
    final onRoute = tour.legs.isEmpty ? null : editor.track.nearest(p, radius: 300);
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.add_location_alt),
            title: Text(tour.waypoints.isEmpty ? 'Start here' : 'Add destination here'),
            onTap: () => Navigator.pop(ctx, 'append'),
          ),
          if (leg != null)
            ListTile(
              leading: const Icon(Icons.alt_route),
              title: const Text('Route via this point'),
              subtitle: Text('Inserted between waypoint ${leg + 1} and ${leg + 2}'),
              onTap: () => Navigator.pop(ctx, 'insert'),
            ),
          if (tour.waypoints.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.first_page),
              title: const Text('Make this the new start'),
              onTap: () => Navigator.pop(ctx, 'start'),
            ),
          if (onRoute != null)
            ListTile(
              leading: const Icon(Icons.bedtime),
              title: const Text('End a day here'),
              onTap: () => Navigator.pop(ctx, 'endday'),
            ),
          ListTile(
            leading: const Icon(Icons.search),
            title: const Text('Find places nearby'),
            onTap: () => Navigator.pop(ctx, 'nearby'),
          ),
        ]),
      ),
    );
    switch (action) {
      case 'append':
        editor.addWaypoint(p);
      case 'insert':
        editor.insertWaypoint(leg!, p);
      case 'start':
        editor.addAsStart(p);
      case 'endday':
        editor.endDayAt(onRoute!.along);
      case 'nearby':
        await _searchNearby(p);
    }
  }

  Future<void> _searchNearby(LatLng p) async {
    final cats = await pickCategories(context, context.read<AppState>().settings.poiCategories);
    if (cats == null || !mounted) return;
    try {
      final found = await runWithProgress(
          context, 'Searching nearby…', () => pois.searchAround(p, 5000, cats));
      if (mounted) showInfo(context, '${found.length} places found within 5 km.');
      setState(() => _showPois = true);
      map.move(p, 13);
    } catch (e) {
      if (mounted) showError(context, e.toString());
    }
  }

  Future<void> _waypointTapped(int i) async {
    final wp = tour.waypoints[i];
    final isEnd = i == 0 || i == tour.waypoints.length - 1;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: Text(wp.name ?? 'Waypoint ${i + 1}'),
            subtitle: Text('${wp.position.latitude.toStringAsFixed(5)}, '
                '${wp.position.longitude.toStringAsFixed(5)}'),
          ),
          ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('Rename'),
              onTap: () => Navigator.pop(ctx, 'rename')),
          if (!isEnd)
            SwitchListTile(
              secondary: const Icon(Icons.bedtime),
              title: const Text('Overnight stop (end of day)'),
              value: wp.overnight,
              onChanged: (_) => Navigator.pop(ctx, 'overnight'),
            ),
          ListTile(
              leading: const Icon(Icons.open_with),
              title: const Text('Move (tap new position)'),
              onTap: () => Navigator.pop(ctx, 'move')),
          ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Remove'),
              onTap: () => Navigator.pop(ctx, 'delete')),
        ]),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'rename':
        final n = await promptText(context, 'Name', initial: wp.name ?? '');
        if (n != null) editor.renameWaypoint(i, n);
      case 'overnight':
        editor.toggleOvernight(i);
      case 'move':
        setState(() => _moving = i);
        showInfo(context, 'Tap the map at the new position.');
      case 'delete':
        editor.removeWaypoint(i);
    }
  }

  Future<void> _poiTapped(PoiOnRoute p) async {
    final canStop = {'camping', 'accommodation', 'shelter'}.contains(p.poi.category);
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => PoiDetails(
        poi: p.poi,
        onRoute: p,
        actions: [
          if (canStop)
            FilledButton.icon(
              icon: const Icon(Icons.bedtime),
              label: const Text('End day here'),
              onPressed: () {
                Navigator.pop(ctx);
                editor.endDayAt(p.along, name: p.poi.name);
              },
            ),
          OutlinedButton.icon(
            icon: const Icon(Icons.alt_route),
            label: const Text('Route via'),
            onPressed: () {
              Navigator.pop(ctx);
              final leg = editor.nearestLeg(p.poi.position, radius: 20000);
              if (leg != null) editor.insertWaypoint(leg, p.poi.position, name: p.poi.name);
            },
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- actions

  Future<void> _chooseProfile() async {
    var profile = tour.profile;
    var stick = tour.stickToCycleRoutes;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Routing'),
          content: SingleChildScrollView(
            child: RadioGroup<String>(
              groupValue: profile,
              onChanged: (v) => set(() => profile = v!),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                for (final p in RoutingProfile.all)
                  RadioListTile<String>(
                    value: p.id,
                    title: Text(p.label),
                    subtitle: Text(p.description),
                  ),
                SwitchListTile(
                  title: const Text('Stick to signposted cycle routes'),
                  subtitle: const Text('Touring profile only'),
                  value: stick,
                  onChanged: profile == 'trekking' ? (v) => set(() => stick = v) : null,
                ),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true), child: const Text('Recalculate')),
          ],
        ),
      ),
    );
    if (ok == true) editor.setProfile(profile, stick);
  }

  Future<void> _planDays() async {
    if (!tour.isComplete) {
      showError(context, 'Wait until all legs are routed.');
      return;
    }
    final settings = context.read<AppState>().settings;
    var km = settings.dayLengthKm;
    var preferCamping = false, preferLodging = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Split into days'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('${km.round()} km per day → about '
                '${(tour.distance / 1000 / km).round().clamp(1, 9999)} days'),
            Slider(
              value: km,
              min: 20,
              max: 250,
              divisions: 46,
              label: '${km.round()} km',
              onChanged: (v) => set(() => km = v),
            ),
            CheckboxListTile(
              title: const Text('Prefer stopping at campsites'),
              value: preferCamping,
              onChanged: (v) => set(() => preferCamping = v!),
            ),
            CheckboxListTile(
              title: const Text('Prefer stopping at hotels / hostels'),
              value: preferLodging,
              onChanged: (v) => set(() => preferLodging = v!),
            ),
            const Text('Your own overnight stops are kept.', style: TextStyle(fontSize: 12)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Split')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    settings.dayLengthKm = km;
    final wanted = {if (preferCamping) 'camping', if (preferLodging) 'accommodation'};
    if (wanted.isNotEmpty && !pois.covered(editor.track, wanted)) {
      await runWithProgress(context, 'Downloading places along the route…',
          () => pois.download(editor.track, wanted));
      if (pois.error != null && mounted) showError(context, pois.error!);
    }
    final candidates = [
      for (final p in pois.placed(editor.track))
        if (wanted.contains(p.poi.category)) StopCandidate(p.along, p.poi.name),
    ];
    final n = editor.planDays(km * 1000, candidates: candidates);
    if (mounted) showInfo(context, 'Tour split into ${tour.dayCount} days ($n new stops).');
  }

  Future<void> _downloadPois() async {
    final settings = context.read<AppState>().settings;
    final cats = await pickCategories(context, settings.poiCategories,
        title: 'Download places along the route');
    if (cats == null) return;
    settings.poiCategories = cats;
    setState(() => _showPois = true);
    await pois.download(editor.track, cats);
    if (pois.error != null && mounted) showError(context, pois.error!);
  }

  Future<void> _pickStartDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: tour.startDate ?? now,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 5),
    );
    if (d != null) editor.setStartDate(d);
  }

  Future<void> _menu(String v) async {
    switch (v) {
      case 'rename':
        final n = await promptText(context, 'Tour name', initial: tour.name);
        if (n != null) editor.renameTour(n);
      case 'profile':
        await _chooseProfile();
      case 'days':
        await _planDays();
      case 'cleardays':
        editor.clearAutoDays();
      case 'pois':
        await _downloadPois();
      case 'date':
        await _pickStartDate();
      case 'reverse':
        editor.reverse();
      case 'gpx':
        await editor.save();
        if (mounted) await shareGpx(context, tour);
    }
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final stages = tour.stages;
    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(onTap: () => _menu('rename'), child: Text(tour.name)),
        actions: [
          IconButton(
            icon: const Icon(Icons.navigation),
            tooltip: 'Navigate',
            onPressed: tour.legs.isEmpty
                ? null
                : () async {
                    await editor.save();
                    if (!context.mounted) return;
                    Navigator.push(context,
                        MaterialPageRoute(builder: (_) => NavigationScreen(tour: tour)));
                  },
          ),
          PopupMenuButton<String>(
            onSelected: _menu,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'profile', child: Text('Routing profile')),
              PopupMenuItem(value: 'days', child: Text('Split into days')),
              PopupMenuItem(value: 'cleardays', child: Text('Remove automatic day splits')),
              PopupMenuItem(value: 'pois', child: Text('Download places along route')),
              PopupMenuItem(value: 'date', child: Text('Set start date')),
              PopupMenuItem(value: 'reverse', child: Text('Reverse direction')),
              PopupMenuItem(value: 'rename', child: Text('Rename')),
              PopupMenuItem(value: 'gpx', child: Text('Export GPX')),
            ],
          ),
        ],
      ),
      body: Stack(children: [
        BaseMap(
          controller: map,
          initialFit: _initialFit(),
          initialCenter: tour.waypoints.isNotEmpty
              ? tour.waypoints.first.position
              : const LatLng(48.5, 9.0),
          initialZoom: tour.waypoints.isNotEmpty ? 11 : 5,
          onTap: _onTap,
          onLongPress: _onLongPress,
          onPositionChanged: (cam, _) {
            final z = cam.zoom;
            final b = cam.visibleBounds;
            // Only POI markers depend on the camera, and only from zoom 11.
            if ((z >= 11) != (_zoom >= 11) || (z >= 11 && _visible != b)) {
              setState(() {
                _zoom = z;
                _visible = b;
              });
            }
          },
          layers: _layers(),
        ),
        Positioned(
          top: 8,
          left: 8,
          right: 8,
          child: _SearchBar(onPicked: (place) {
            map.move(place.position, 13);
            if (tour.waypoints.isEmpty) {
              editor.addWaypoint(place.position, name: place.name);
            } else {
              _askAddPlace(place.position, place.name);
            }
          }),
        ),
        if (tour.waypoints.isEmpty)
          const Positioned(
            top: 72,
            left: 16,
            right: 16,
            child: Card(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: Text('Search a place or long-press the map to set the start.'),
              ),
            ),
          ),
        Positioned(
          right: 12,
          top: 72,
          child: Column(children: [
            FloatingActionButton.small(
              heroTag: 'fit',
              tooltip: 'Show whole tour',
              onPressed: _fitTour,
              child: const Icon(Icons.fit_screen),
            ),
            const SizedBox(height: 8),
            FloatingActionButton.small(
              heroTag: 'pois',
              tooltip: 'Show places',
              onPressed: () => setState(() => _showPois = !_showPois),
              child: Icon(_showPois ? Icons.place : Icons.location_off),
            ),
          ]),
        ),
        DraggableScrollableSheet(
          initialChildSize: 0.28,
          minChildSize: 0.12,
          maxChildSize: 0.85,
          builder: (ctx, scroll) => Material(
            elevation: 8,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            child: ListView(
              controller: scroll,
              padding: EdgeInsets.zero,
              children: [
                Center(
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 8),
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                        color: Colors.grey, borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                _Summary(editor: editor, pois: pois, onRetry: (i) => editor.retryLeg(i)),
                for (final s in stages) _StageTile(tour: tour, stage: s, open: () => _openStage(s)),
                if (stages.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Add at least two waypoints to create a route.'),
                  ),
                ..._legProblems(),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ]),
    );
  }

  CameraFit? _initialFit() {
    if (tour.waypoints.length < 2) return null;
    final pts = tour.legs.whereType<Leg>().isEmpty
        ? [for (final w in tour.waypoints) w.position]
        : () {
            final b = GeoBounds.of(editor.track.points);
            return [LatLng(b.south, b.west), LatLng(b.north, b.east)];
          }();
    return CameraFit.coordinates(
        coordinates: pts, padding: const EdgeInsets.fromLTRB(40, 100, 40, 260));
  }

  Iterable<Widget> _legProblems() sync* {
    for (var i = 0; i < tour.legs.length; i++) {
      final err = editor.legError(i);
      if (err == null) continue;
      yield ListTile(
        leading: const Icon(Icons.error_outline, color: Colors.red),
        title: Text('Leg ${i + 1} could not be routed'),
        subtitle: Text(err),
        trailing: Wrap(children: [
          IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Retry',
              onPressed: () => editor.retryLeg(i)),
          IconButton(
              icon: const Icon(Icons.horizontal_rule),
              tooltip: 'Use straight line',
              onPressed: () => editor.useStraightLine(i)),
        ]),
      );
    }
  }

  Future<void> _askAddPlace(LatLng p, String name) async {
    final leg = editor.nearestLeg(p, radius: 30000);
    final v = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(name)),
          ListTile(
              leading: const Icon(Icons.add_location_alt),
              title: const Text('Add as destination'),
              onTap: () => Navigator.pop(ctx, 'append')),
          if (leg != null)
            ListTile(
                leading: const Icon(Icons.alt_route),
                title: const Text('Route via this place'),
                onTap: () => Navigator.pop(ctx, 'insert')),
          ListTile(
              leading: const Icon(Icons.first_page),
              title: const Text('Make this the start'),
              onTap: () => Navigator.pop(ctx, 'start')),
        ]),
      ),
    );
    switch (v) {
      case 'append':
        editor.addWaypoint(p, name: name);
      case 'insert':
        editor.insertWaypoint(leg!, p, name: name);
      case 'start':
        editor.addAsStart(p, name: name);
    }
  }

  void _openStage(Stage s) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => StageScreen(editor: editor, pois: pois, stageNumber: s.number)),
    );
  }
}

class _Summary extends StatelessWidget {
  final TourEditor editor;
  final PoiManager pois;
  final ValueChanged<int> onRetry;

  const _Summary({required this.editor, required this.pois, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final t = editor.tour;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 16, children: [
          Text(formatDistance(t.distance), style: theme.textTheme.titleLarge),
          if (t.stages.isNotEmpty)
            Text('${t.dayCount} ${t.dayCount == 1 ? 'day' : 'days'}',
                style: theme.textTheme.titleLarge),
          if (t.ascent > 0) Text('↑ ${t.ascent.round()} m', style: theme.textTheme.titleLarge),
        ]),
        Text(RoutingProfile.byId(t.profile).label +
            (t.profile == 'trekking' && t.stickToCycleRoutes ? ' · sticking to cycle routes' : '')),
        if (editor.routing)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(children: [
              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 8),
              Text('Routing… ${editor.missingLegs} legs left'),
            ]),
          ),
        if (pois.downloading)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(children: [
              Expanded(child: LinearProgressIndicator(value: pois.progress)),
              const SizedBox(width: 8),
              Text('Places ${(pois.progress * 100).round()} %'),
              IconButton(icon: const Icon(Icons.close), onPressed: pois.cancel),
            ]),
          )
        else if (pois.count > 0)
          Text('${pois.count} places downloaded for offline use',
              style: theme.textTheme.bodySmall),
      ]),
    );
  }
}

class _StageTile extends StatelessWidget {
  final Tour tour;
  final Stage stage;
  final VoidCallback open;

  const _StageTile({required this.tour, required this.stage, required this.open});

  @override
  Widget build(BuildContext context) {
    final date = dayDate(tour, stage.number);
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: stageColors[(stage.number - 1) % 2],
        foregroundColor: Colors.white,
        child: Text('${stage.number}'),
      ),
      title: Text(stage.title),
      subtitle: Text([
        if (date.isNotEmpty) date,
        formatDistance(stage.distance),
        if (stage.ascent > 0) '↑ ${stage.ascent.round()} m',
        if (!stage.complete) 'not routed yet',
      ].join(' · ')),
      trailing: const Icon(Icons.chevron_right),
      onTap: open,
    );
  }
}

class _SearchBar extends StatelessWidget {
  final ValueChanged<PlaceResult> onPicked;

  const _SearchBar({required this.onPicked});

  @override
  Widget build(BuildContext context) => Card(
        child: ListTile(
          leading: const Icon(Icons.search),
          title: const Text('Search place'),
          onTap: () async {
            final r = await Navigator.push<PlaceResult>(
                context, MaterialPageRoute(builder: (_) => const PlaceSearchScreen()));
            if (r != null) onPicked(r);
          },
        ),
      );
}

enum _WpKind { start, via, overnight, end }

class _WaypointIcon extends StatelessWidget {
  final _WpKind kind;
  final String? label;
  final bool highlighted;

  const _WaypointIcon({required this.kind, this.label, this.highlighted = false});

  @override
  Widget build(BuildContext context) {
    final (color, icon) = switch (kind) {
      _WpKind.start => (Colors.green.shade700, Icons.play_arrow),
      _WpKind.end => (Colors.red.shade700, Icons.flag),
      _WpKind.overnight => (Colors.indigo, Icons.bedtime),
      _WpKind.via => (Colors.blueGrey, Icons.circle),
    };
    final size = kind == _WpKind.via ? 20.0 : 30.0;
    return Center(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: highlighted ? Colors.orange : Colors.white, width: highlighted ? 4 : 2),
          boxShadow: const [BoxShadow(blurRadius: 3, color: Colors.black38)],
        ),
        child: kind == _WpKind.via
            ? null
            : label != null && label!.isNotEmpty
                ? Center(
                    child: Text(label!,
                        style: const TextStyle(
                            color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)))
                : Icon(icon, color: Colors.white, size: 18),
      ),
    );
  }
}

/// Dialog for choosing POI categories.
Future<Set<String>?> pickCategories(BuildContext context, Set<String> initial,
    {String title = 'What are you looking for?'}) {
  var sel = {...initial};
  return showDialog<Set<String>>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Wrap(spacing: 6, runSpacing: 6, children: [
            for (final c in PoiCategory.all)
              FilterChip(
                avatar: Icon(c.icon, size: 18, color: c.color),
                label: Text(c.label),
                selected: sel.contains(c.id),
                onSelected: (v) => set(() => v ? sel.add(c.id) : sel.remove(c.id)),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: sel.isEmpty ? null : () => Navigator.pop(ctx, sel),
              child: const Text('OK')),
        ],
      ),
    ),
  );
}
