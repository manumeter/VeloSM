import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/geo.dart';
import '../../core/route_track.dart';
import '../../models/poi.dart';
import '../../models/tour.dart';
import '../../services/brouter_service.dart';
import '../../state/app_state.dart';
import '../../state/navigation.dart';
import '../../state/poi_manager.dart';
import '../ui_utils.dart';
import '../widgets/base_map.dart';
import '../widgets/elevation_profile.dart';
import '../widgets/poi_widgets.dart';

/// Riding view: follows the GPS position along the tour and lists what is
/// coming up (water, food, campsites, ...) with distance and detour.
class NavigationScreen extends StatefulWidget {
  final Tour tour;

  const NavigationScreen({super.key, required this.tour});

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen> {
  late final NavigationController nav;
  late final PoiManager pois;
  late final RouteTrack track;
  final map = MapController();
  bool _follow = true;
  bool _mapReady = false;

  // Simplified copy of the route for drawing.
  late final List<LatLng> _drawPts;
  late final List<double> _drawAlong;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    track = RouteTrack.fromTour(widget.tour);
    final keep = simplifyIndices(track.points, 4);
    _drawPts = [for (final i in keep) track.points[i]];
    _drawAlong = [for (final i in keep) track.cumulative[i]];
    pois = PoiManager(app, widget.tour);
    nav = NavigationController(app: app, tour: widget.tour, track: track, pois: pois)
      ..addListener(_onNav);
    unawaited(pois.load());
    if (app.settings.keepScreenOn) unawaited(WakelockPlus.enable());
    unawaited(_start());
  }

  Future<void> _start() async {
    final ok = await nav.start();
    if (!ok && mounted) {
      showError(context, '${nav.error} You can still simulate a ride from the menu.');
    }
  }

  void _onNav() {
    if (!mounted) return;
    setState(() {});
    final p = nav.position;
    if (_follow && _mapReady && p != null) {
      map.move(p, map.camera.zoom < 13 ? 15 : map.camera.zoom);
    }
  }

  @override
  void dispose() {
    nav.removeListener(_onNav);
    nav.dispose();
    pois.dispose();
    unawaited(WakelockPlus.disable());
    super.dispose();
  }

  int _drawIndex(double along) {
    var lo = 0, hi = _drawAlong.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_drawAlong[mid] <= along) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  List<Widget> _layers() {
    final m = nav.match;
    final split = m == null ? 0 : _drawIndex(m.along);
    final here = m == null ? null : track.pointAt(m.along);
    final done = m == null ? <LatLng>[] : [..._drawPts.sublist(0, split + 1), here!];
    final ahead = m == null ? _drawPts : [here!, ..._drawPts.sublist(split + 1)];
    final scheme = Theme.of(context).colorScheme;
    return [
      PolylineLayer(simplificationTolerance: 0.6, polylines: [
        if (done.length > 1) Polyline(points: done, color: Colors.grey, strokeWidth: 5),
        Polyline(
          points: ahead,
          color: scheme.primary,
          strokeWidth: 6,
          borderColor: Colors.white,
          borderStrokeWidth: 1.5,
        ),
      ]),
      MarkerLayer(markers: [
        for (final s in widget.tour.stages.take(widget.tour.stages.length - 1))
          Marker(
            point: s.end.position,
            width: 26,
            height: 26,
            child: const CircleAvatar(
              backgroundColor: Colors.indigo,
              child: Icon(Icons.bedtime, size: 14, color: Colors.white),
            ),
          ),
        for (final p in nav.upcoming.take(150)) poiMarker(p.poi, size: 26, onTap: () => _showPoi(p)),
        if (nav.position != null)
          Marker(
            point: nav.position!,
            width: 40,
            height: 40,
            child: Transform.rotate(
              angle: (nav.heading ?? 0) * 3.14159265 / 180,
              child: Icon(nav.heading == null ? Icons.circle : Icons.navigation,
                  color: Colors.deepOrange, size: nav.heading == null ? 20 : 36),
            ),
          ),
      ]),
    ];
  }

  Future<void> _showPoi(PoiOnRoute p) async {
    final app = context.read<AppState>();
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => PoiDetails(
        poi: p.poi,
        onRoute: p,
        currentAlong: nav.along,
        actions: [
          OutlinedButton.icon(
            icon: const Icon(Icons.center_focus_strong),
            label: const Text('Show'),
            onPressed: () {
              Navigator.pop(ctx);
              setState(() => _follow = false);
              map.move(p.poi.position, 16);
            },
          ),
          if (p.offset > 30)
            OutlinedButton.icon(
              icon: const Icon(Icons.straighten),
              label: const Text('Exact detour'),
              onPressed: () async {
                Navigator.pop(ctx);
                try {
                  final leg = await runWithProgress(context, 'Calculating detour…', () {
                    return app.brouter.route(track.pointAt(p.along), p.poi.position,
                        profile: widget.tour.profile);
                  });
                  if (mounted) {
                    showInfo(context,
                        '${p.poi.name}: ${formatDistance(leg.distance)} by bike from the route, '
                        '≈ ${formatDistance(leg.distance * 2)} detour there and back.');
                  }
                } catch (e) {
                  if (mounted) showError(context, e.toString());
                }
              },
            ),
        ],
      ),
    );
  }

  Future<void> _menu(String v) async {
    switch (v) {
      case 'sim':
        final kmh = await promptText(context, 'Simulated speed (km/h)',
            initial: '60', keyboard: TextInputType.number);
        final speed = double.tryParse(kmh ?? '');
        if (speed != null && speed > 0) {
          setState(() => _follow = true);
          nav.simulate(kmh: speed);
        }
      case 'stopsim':
        nav.stopSimulation();
      case 'dl60':
        await pois.download(track, nav.categories, from: nav.along, to: nav.along + 60000);
      case 'dlday':
        final s = nav.currentStage;
        if (s != null) {
          await pois.download(track, nav.categories,
              from: nav.along, to: s.startOffset + s.distance);
        }
      case 'dlall':
        await pois.download(track, nav.categories, from: nav.along);
      case 'profile':
        await _showProfile();
    }
    if (pois.error != null && mounted) showError(context, pois.error!);
  }

  Future<void> _showProfile() async {
    final s = nav.currentStage;
    final from = s?.startOffset ?? 0;
    final to = s == null ? track.length : s.startOffset + s.distance;
    await showModalBottomSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(s == null ? 'Elevation' : 'Day ${s.number}: ${s.title}'),
            const SizedBox(height: 8),
            ElevationProfile(data: track.profile(from: from, to: to), marker: nav.along, height: 180),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final start = track.isEmpty ? const LatLng(48.5, 9.0) : track.points.first;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.tour.name),
        actions: [
          PopupMenuButton<String>(
            onSelected: _menu,
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'profile', child: Text('Elevation profile')),
              const PopupMenuItem(value: 'dl60', child: Text('Download places: next 60 km')),
              const PopupMenuItem(value: 'dlday', child: Text('Download places: rest of the day')),
              const PopupMenuItem(value: 'dlall', child: Text('Download places: rest of the tour')),
              nav.simulating
                  ? const PopupMenuItem(value: 'stopsim', child: Text('Stop simulation'))
                  : const PopupMenuItem(value: 'sim', child: Text('Simulate ride')),
            ],
          ),
        ],
      ),
      body: Stack(children: [
        Listener(
          onPointerDown: (_) {
            if (_follow) setState(() => _follow = false);
          },
          child: BaseMap(
            controller: map,
            initialCenter: start,
            initialZoom: 14,
            onMapReady: () => _mapReady = true,
            layers: _layers(),
          ),
        ),
        Positioned(top: 8, left: 8, right: 8, child: _TopBanner(nav: nav)),
        Positioned(
          right: 12,
          top: 96,
          child: FloatingActionButton.small(
            heroTag: 'follow',
            tooltip: 'Follow position',
            backgroundColor: _follow ? Theme.of(context).colorScheme.primaryContainer : null,
            onPressed: () {
              setState(() => _follow = true);
              if (nav.position != null) map.move(nav.position!, 15);
            },
            child: const Icon(Icons.my_location),
          ),
        ),
        DraggableScrollableSheet(
          initialChildSize: 0.34,
          minChildSize: 0.14,
          maxChildSize: 0.85,
          builder: (ctx, scroll) => Material(
            elevation: 8,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            child: _UpcomingList(nav: nav, pois: pois, scroll: scroll, onTap: _showPoi),
          ),
        ),
      ]),
    );
  }
}

IconData turnIcon(int command) => switch (command) {
      2 => Icons.turn_left,
      3 => Icons.turn_slight_left,
      4 => Icons.turn_sharp_left,
      5 => Icons.turn_right,
      6 => Icons.turn_slight_right,
      7 => Icons.turn_sharp_right,
      8 => Icons.fork_left,
      9 => Icons.fork_right,
      10 || 11 => Icons.u_turn_left,
      12 => Icons.u_turn_right,
      14 || 15 => Icons.roundabout_right,
      17 => Icons.turn_slight_left,
      18 => Icons.turn_slight_right,
      _ => Icons.straight,
    };

class _TopBanner extends StatelessWidget {
  final NavigationController nav;

  const _TopBanner({required this.nav});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (nav.position == null) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.gps_not_fixed),
          title: Text(nav.error ?? 'Waiting for GPS…'),
        ),
      );
    }
    if (!nav.onRoute) {
      return Card(
        color: scheme.errorContainer,
        child: ListTile(
          leading: const Icon(Icons.wrong_location),
          title: const Text('Off route'),
          subtitle: Text(nav.match == null
              ? 'More than 3 km from the tour'
              : '${formatDistance(nav.match!.offset)} from the tour'),
        ),
      );
    }
    final hint = nav.nextHint;
    if (hint == null) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.straight),
          title: Text('Follow the route · ${formatDistance(nav.remaining)} to the finish'),
        ),
      );
    }
    final dist = hint.along - nav.along;
    return Card(
      color: scheme.primaryContainer,
      child: ListTile(
        leading: Icon(turnIcon(hint.command), size: 40),
        title: Text(formatDistance(dist),
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
        subtitle: Text(turnText(hint.command, hint.exit)),
      ),
    );
  }
}

class _UpcomingList extends StatelessWidget {
  final NavigationController nav;
  final PoiManager pois;
  final ScrollController scroll;
  final ValueChanged<PoiOnRoute> onTap;

  const _UpcomingList(
      {required this.nav, required this.pois, required this.scroll, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final settings = context.read<AppState>().settings;
    final stage = nav.currentStage;
    final theme = Theme.of(context);
    final counts = <String, int>{};
    for (final p in pois.placed(nav.track)) {
      if (p.along >= nav.along && p.along <= nav.along + nav.lookAhead) {
        counts[p.poi.category] = (counts[p.poi.category] ?? 0) + 1;
      }
    }
    // Next item of every selected category, for the at-a-glance row.
    final nextOf = <String, PoiOnRoute>{};
    for (final p in nav.upcoming) {
      if (p.along >= nav.along) nextOf.putIfAbsent(p.poi.category, () => p);
    }
    return ListView(
      controller: scroll,
      padding: EdgeInsets.zero,
      children: [
        Center(
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 8),
            width: 36,
            height: 4,
            decoration: BoxDecoration(color: Colors.grey, borderRadius: BorderRadius.circular(2)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            _Stat(stage == null ? 'Day' : 'Day ${stage.number}',
                stage == null ? '–' : formatDistance(nav.stageRemaining), 'to day end'),
            _Stat('Climb', '${nav.stageAscentRemaining.round()} m', 'left today'),
            _Stat('Tour', formatDistance(nav.remaining), 'to finish'),
            if (nav.speed != null && nav.speed! > 0.5)
              _Stat('Speed', '${(nav.speed! * 3.6).round()}', 'km/h'),
          ]),
        ),
        if (pois.downloading)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(children: [
              Expanded(child: LinearProgressIndicator(value: pois.progress)),
              const SizedBox(width: 8),
              const Text('Loading places…'),
            ]),
          ),
        const SizedBox(height: 8),
        CategoryChips(
          selected: settings.poiCategories,
          counts: counts,
          onChanged: (v) => settings.poiCategories = v,
        ),
        if (nextOf.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text('Next', style: theme.textTheme.titleSmall),
          ),
          SizedBox(
            height: 76,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                for (final p in nextOf.values)
                  Card(
                    child: InkWell(
                      onTap: () => onTap(p),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Row(children: [
                          PoiBadge(p.poi.cat, size: 28),
                          const SizedBox(width: 8),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(formatDistance(p.along - nav.along),
                                  style: const TextStyle(fontWeight: FontWeight.bold)),
                              Text(p.offset < 30 ? 'on route' : '+${formatDistance(p.detour)}',
                                  style: theme.textTheme.bodySmall),
                            ],
                          ),
                        ]),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text('Coming up', style: theme.textTheme.titleSmall),
        ),
        if (nav.upcoming.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(pois.count == 0
                ? 'No places downloaded yet. They load automatically while online, '
                    'or use the menu to download them for offline use.'
                : 'Nothing of the selected kinds in the next ${formatDistance(nav.lookAhead)}.'),
          ),
        for (final p in nav.upcoming.take(100))
          ListTile(
            dense: true,
            leading: PoiBadge(p.poi.cat, size: 30),
            title: Text(p.poi.name),
            subtitle: Text(poiDistanceText(p, nav.along)),
            trailing: p.poi.tags['opening_hours'] != null
                ? const Icon(Icons.schedule, size: 16)
                : null,
            onTap: () => onTap(p),
          ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  final String label, value, unit;

  const _Stat(this.label, this.value, this.unit);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(children: [
      Text(label, style: t.bodySmall),
      Text(value, style: t.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
      Text(unit, style: t.bodySmall),
    ]);
  }
}
