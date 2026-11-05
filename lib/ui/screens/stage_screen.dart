import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../core/geo.dart';
import '../../models/poi.dart';
import '../../models/tour.dart';
import '../../state/app_state.dart';
import '../../state/poi_manager.dart';
import '../../state/tour_editor.dart';
import '../ui_utils.dart';
import '../widgets/base_map.dart';
import '../widgets/elevation_profile.dart';
import '../widgets/poi_widgets.dart';
import 'tour_screen.dart';

const _sleepCategories = {'camping', 'accommodation', 'shelter'};

/// One day of the tour: profile, places along the way and where to sleep.
class StageScreen extends StatefulWidget {
  final TourEditor editor;
  final PoiManager pois;
  final int stageNumber;

  const StageScreen({super.key, required this.editor, required this.pois, required this.stageNumber});

  @override
  State<StageScreen> createState() => _StageScreenState();
}

class _StageScreenState extends State<StageScreen> {
  final map = MapController();
  late Set<String> _cats;

  @override
  void initState() {
    super.initState();
    _cats = context.read<AppState>().settings.poiCategories;
    widget.editor.addListener(_rebuild);
    widget.pois.addListener(_rebuild);
  }

  @override
  void dispose() {
    widget.editor.removeListener(_rebuild);
    widget.pois.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  Stage? get stage {
    final stages = widget.editor.tour.stages;
    final i = widget.stageNumber - 1;
    return i < stages.length ? stages[i] : null;
  }

  Future<void> _download(Stage s) async {
    final cats = await pickCategories(context, _cats, title: 'Download places for this day');
    if (cats == null) return;
    setState(() => _cats = cats);
    final track = widget.editor.track;
    await widget.pois.download(track, cats, from: s.startOffset, to: s.startOffset + s.distance);
    if (widget.pois.error != null && mounted) showError(context, widget.pois.error!);
  }

  Future<void> _findSleep(Stage s) async {
    try {
      final found = await runWithProgress(context, 'Searching places to sleep…',
          () => widget.pois.searchAround(s.end.position, 10000, _sleepCategories));
      if (mounted) showInfo(context, '${found.length} places to sleep within 10 km.');
    } catch (e) {
      if (mounted) showError(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = stage;
    if (s == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('This day no longer exists.')));
    }
    final tour = widget.editor.tour;
    final track = widget.editor.track;
    final from = s.startOffset, to = s.startOffset + s.distance;
    final placed = [
      for (final p in widget.pois.placed(track))
        if (p.along >= from - 100 && p.along <= to + 100 && _cats.contains(p.poi.category)) p,
    ];
    final counts = <String, int>{};
    for (final p in widget.pois.placed(track)) {
      if (p.along >= from && p.along <= to) {
        counts[p.poi.category] = (counts[p.poi.category] ?? 0) + 1;
      }
    }
    final sleep = widget.pois.near(s.end.position, 10000, _sleepCategories).take(15).toList();
    final stagePoints = <LatLng>[
      for (var li = s.firstLeg; li < s.endLeg; li++)
        ...(tour.legs[li]?.points ?? [tour.waypoints[li].position, tour.waypoints[li + 1].position]),
    ];
    final date = dayDate(tour, s.number);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text('Day ${s.number}${date.isEmpty ? '' : ' · $date'}')),
      body: ListView(children: [
        SizedBox(
          height: 220,
          child: BaseMap(
            controller: map,
            initialFit: stagePoints.length > 1
                ? CameraFit.coordinates(coordinates: stagePoints, padding: const EdgeInsets.all(24))
                : null,
            initialCenter: s.start.position,
            initialZoom: 11,
            layers: [
              PolylineLayer(polylines: [
                Polyline(points: stagePoints, color: stageColors[(s.number - 1) % 2], strokeWidth: 5),
              ], simplificationTolerance: 0.6),
              MarkerLayer(markers: [
                for (final p in placed.take(200)) poiMarker(p.poi, size: 22, onTap: () => _showPoi(p)),
                for (final (poi, _) in sleep) poiMarker(poi, size: 22),
              ]),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.title, style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text([
              formatDistance(s.distance),
              '↑ ${s.ascent.round()} m',
              '↓ ${s.descent.round()} m',
              'km ${(from / 1000).round()}–${(to / 1000).round()} of the tour',
            ].join(' · ')),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: ElevationProfile(data: track.profile(from: from, to: to)),
        ),
        const Divider(),
        ListTile(
          title: Text('Along the way', style: theme.textTheme.titleMedium),
          trailing: widget.pois.downloading
              ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
              : TextButton.icon(
                  icon: const Icon(Icons.download),
                  label: const Text('Download'),
                  onPressed: () => _download(s),
                ),
        ),
        CategoryChips(selected: _cats, counts: counts, onChanged: (v) => setState(() => _cats = v)),
        if (placed.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No places loaded for this day yet. Tap "Download" (works offline afterwards).'),
          ),
        for (final p in placed.take(300))
          ListTile(
            leading: PoiBadge(p.poi.cat),
            title: Text(p.poi.name),
            subtitle: Text('km ${((p.along - from) / 1000).toStringAsFixed(1)} of the day · '
                '${p.offset < 30 ? 'on route' : '${formatDistance(p.offset)} off (≈ ${formatDistance(p.detour)} detour)'}'),
            onTap: () => _showPoi(p),
          ),
        const Divider(),
        ListTile(
          title: Text('Places to sleep near the end', style: theme.textTheme.titleMedium),
          trailing: TextButton.icon(
            icon: const Icon(Icons.search),
            label: const Text('Search'),
            onPressed: () => _findSleep(s),
          ),
        ),
        for (final (poi, d) in sleep)
          ListTile(
            leading: PoiBadge(poi.cat),
            title: Text(poi.name),
            subtitle: Text('${formatDistance(d)} from the day\'s end'),
            onTap: () => _showPoi(widget.pois.placed(track).firstWhere(
                  (p) => p.poi.id == poi.id,
                  orElse: () => PoiOnRoute(poi, to, d),
                )),
          ),
        const SizedBox(height: 32),
      ]),
    );
  }

  Future<void> _showPoi(PoiOnRoute p) async {
    final canStop = _sleepCategories.contains(p.poi.category);
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => PoiDetails(
        poi: p.poi,
        onRoute: p,
        currentAlong: stage?.startOffset ?? 0,
        actions: [
          if (canStop)
            FilledButton.icon(
              icon: const Icon(Icons.bedtime),
              label: const Text('End day here'),
              onPressed: () {
                Navigator.pop(ctx);
                widget.editor.endDayAt(p.along, name: p.poi.name);
              },
            ),
        ],
      ),
    );
  }
}
