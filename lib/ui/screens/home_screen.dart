import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../core/geo.dart';
import '../../core/gpx.dart';
import '../../models/tour.dart';
import '../../state/app_state.dart';
import '../ui_utils.dart';
import 'import_route_screen.dart';
import 'navigation_screen.dart';
import 'settings_screen.dart';
import 'tour_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('VeloSM'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      body: app.loading
          ? const Center(child: CircularProgressIndicator())
          : app.tours.isEmpty
              ? const _EmptyState()
              : RefreshIndicator(
                  onRefresh: app.refresh,
                  child: ListView.builder(
                    padding: const EdgeInsets.only(bottom: 96),
                    itemCount: app.tours.length,
                    itemBuilder: (_, i) => _TourTile(app.tours[i]),
                  ),
                ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('New tour'),
        onPressed: () => showNewTourSheet(context),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.directions_bike, size: 72, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text('Plan your next bike tour', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text(
              'Plan multi-day tours along signposted cycle routes, split them into days and '
              'find water, food and a place to sleep along the way.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Create a tour'),
              onPressed: () => showNewTourSheet(context),
            ),
          ]),
        ),
      );
}

class _TourTile extends StatelessWidget {
  final TourSummary summary;

  const _TourTile(this.summary);

  Future<Tour?> _load(BuildContext context) async {
    final app = context.read<AppState>();
    final tour = await app.repo.load(summary.id);
    if (tour == null && context.mounted) showError(context, 'Tour could not be loaded.');
    return tour;
  }

  @override
  Widget build(BuildContext context) {
    final s = summary;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: ListTile(
        leading: const CircleAvatar(child: Icon(Icons.route)),
        title: Text(s.name),
        subtitle: Text([
          formatDistance(s.distance),
          if (s.days > 0) '${s.days} ${s.days == 1 ? 'day' : 'days'}',
          if (s.ascent > 0) '↑ ${s.ascent.round()} m',
        ].join(' · ')),
        onTap: () async {
          final tour = await _load(context);
          if (tour != null && context.mounted) openTour(context, tour);
        },
        trailing: PopupMenuButton<String>(
          onSelected: (v) async {
            final app = context.read<AppState>();
            if (v == 'delete') {
              final ok = await confirm(context, 'Delete "${s.name}"?',
                  'The tour and its downloaded places will be removed.');
              if (ok) await app.delete(s.id);
              return;
            }
            final tour = await _load(context);
            if (tour == null || !context.mounted) return;
            if (v == 'nav') {
              Navigator.push(
                  context, MaterialPageRoute(builder: (_) => NavigationScreen(tour: tour)));
            } else if (v == 'gpx') {
              await shareGpx(context, tour);
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'nav', child: Text('Start navigation')),
            PopupMenuItem(value: 'gpx', child: Text('Export GPX')),
            PopupMenuItem(value: 'delete', child: Text('Delete')),
          ],
        ),
      ),
    );
  }
}

void openTour(BuildContext context, Tour tour) {
  Navigator.push(context, MaterialPageRoute(builder: (_) => TourScreen(tour: tour)));
}

Future<void> showNewTourSheet(BuildContext context) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          leading: const Icon(Icons.edit_location_alt),
          title: const Text('Plan a new tour'),
          subtitle: const Text('Set waypoints on the map; routing follows cycle routes'),
          onTap: () => Navigator.pop(ctx, 'plan'),
        ),
        ListTile(
          leading: const Icon(Icons.signpost),
          title: const Text('Follow a signposted route'),
          subtitle: const Text('EuroVelo, national and regional cycle routes'),
          onTap: () => Navigator.pop(ctx, 'signed'),
        ),
        ListTile(
          leading: const Icon(Icons.file_open),
          title: const Text('Import GPX file'),
          subtitle: const Text('Each track in the file becomes one day'),
          onTap: () => Navigator.pop(ctx, 'gpx'),
        ),
      ]),
    ),
  );
  if (choice == null || !context.mounted) return;
  final app = context.read<AppState>();
  switch (choice) {
    case 'plan':
      final name = await promptText(context, 'Tour name', initial: 'My bike tour');
      if (name == null || !context.mounted) return;
      final tour = Tour(
        id: const Uuid().v4(),
        name: name,
        profile: app.settings.defaultProfile,
        stickToCycleRoutes: app.settings.stickToCycleRoutes,
      );
      await app.save(tour);
      if (context.mounted) openTour(context, tour);
    case 'signed':
      final tour = await Navigator.push<Tour>(
          context, MaterialPageRoute(builder: (_) => const ImportRouteScreen()));
      if (tour != null && context.mounted) openTour(context, tour);
    case 'gpx':
      await _importGpx(context);
  }
}

Future<void> _importGpx(BuildContext context) async {
  final app = context.read<AppState>();
  final files = await FilePicker.pickFiles(dialogTitle: 'Choose a GPX file');
  if (files.isEmpty || !context.mounted) return;
  final file = files.first;
  try {
    final fallback = file.name.replaceAll(RegExp(r'\.gpx$', caseSensitive: false), '');
    final tour = await runWithProgress(context, 'Reading GPX…', () async {
      final text = await file.xFile.readAsString();
      // Large multi-day files take a while to parse: keep the UI responsive.
      return compute(_tourFromGpx, (text, fallback));
    });
    tour.profile = app.settings.defaultProfile;
    tour.stickToCycleRoutes = app.settings.stickToCycleRoutes;
    await app.save(tour);
    if (context.mounted) openTour(context, tour);
  } catch (e) {
    if (context.mounted) showError(context, 'Could not import GPX: $e');
  }
}

Tour _tourFromGpx((String, String) args) {
  final gpx = Gpx.parse(args.$1);
  if (gpx.tracks.isEmpty) throw const FormatException('The file contains no track or route.');
  return Gpx.toTour(gpx, fallbackName: args.$2);
}
