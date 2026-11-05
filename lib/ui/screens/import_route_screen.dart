import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/waymarked_service.dart';
import '../../state/app_state.dart';
import '../ui_utils.dart';

/// Search signposted cycle routes (EuroVelo, national, regional, local) on
/// Waymarked Trails and import one as a tour.
class ImportRouteScreen extends StatefulWidget {
  const ImportRouteScreen({super.key});

  @override
  State<ImportRouteScreen> createState() => _ImportRouteScreenState();
}

class _ImportRouteScreenState extends State<ImportRouteScreen> {
  final _ctrl = TextEditingController();
  List<SignedRoute> _results = const [];
  bool _loading = false;
  String? _error;

  Future<void> _search(String q) async {
    if (q.trim().isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await context.read<AppState>().waymarked.search(q.trim());
      const order = {'INT': 0, 'NAT': 1, 'REG': 2, 'LOC': 3};
      r.sort((a, b) => (order[a.group] ?? 4).compareTo(order[b.group] ?? 4));
      setState(() => _results = r);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _import(SignedRoute r) async {
    final app = context.read<AppState>();
    try {
      final tour = await runWithProgress(
          context, 'Loading "${r.name}"…', () => app.waymarked.importRoute(r));
      tour.profile = app.settings.defaultProfile;
      tour.stickToCycleRoutes = true;
      await app.save(tour);
      if (mounted) Navigator.pop(context, tour);
    } catch (e) {
      if (mounted) showError(context, 'Import failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: TextField(
            controller: _ctrl,
            autofocus: true,
            textInputAction: TextInputAction.search,
            decoration: const InputDecoration(
                hintText: 'e.g. EuroVelo 6, Danube, Rhein-Route', border: InputBorder.none),
            onSubmitted: _search,
          ),
          actions: [
            IconButton(icon: const Icon(Icons.search), onPressed: () => _search(_ctrl.text)),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)))
                : _results.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'Search for a signposted cycle route by name or number. The whole '
                          'route is imported as one tour, which you can then split into days.',
                        ),
                      )
                    : ListView(children: [
                        for (final r in _results)
                          ListTile(
                            leading: CircleAvatar(
                              child: Text(r.group ?? '?', style: const TextStyle(fontSize: 11)),
                            ),
                            title: Text(r.ref != null ? '${r.name} (${r.ref})' : r.name),
                            subtitle: Text([
                              r.groupLabel,
                              if (r.itinerary.isNotEmpty) r.itinerary.join(' – '),
                            ].join(' · ')),
                            onTap: () => _import(r),
                          ),
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text('Route data: Waymarked Trails · © OpenStreetMap contributors',
                              style: TextStyle(fontSize: 11)),
                        ),
                      ]),
      );
}
