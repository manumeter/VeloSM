import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/brouter_service.dart';
import '../../state/settings.dart';
import '../ui_utils.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Settings>();
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(children: [
        const _Header('Map'),
        RadioGroup<String>(
          groupValue: s.mapStyleId,
          onChanged: (v) => s.mapStyleId = v!,
          child: Column(children: [
            for (final m in MapStyle.all) RadioListTile<String>(value: m.id, title: Text(m.label)),
            RadioListTile<String>(
              value: 'custom',
              title: const Text('Custom tile server'),
              subtitle: Text(s.customTileUrl.isEmpty ? 'Not set' : s.customTileUrl,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              secondary: IconButton(
                icon: const Icon(Icons.edit),
                onPressed: () async {
                  final v = await promptText(context, 'Tile URL template',
                      initial: s.customTileUrl,
                      hint: 'https://tile.thunderforest.com/cycle/{z}/{x}/{y}.png?apikey=…');
                  if (v != null) s.customTileUrl = v;
                },
              ),
            ),
          ]),
        ),
        SwitchListTile(
          title: const Text('Show signposted cycle routes'),
          subtitle: const Text('Overlay from Waymarked Trails'),
          value: s.cycleRoutesOverlay,
          onChanged: (v) => s.cycleRoutesOverlay = v,
        ),
        const _Header('Routing'),
        ListTile(
          title: const Text('Default profile for new tours'),
          subtitle: Text(RoutingProfile.byId(s.defaultProfile).label),
          onTap: () async {
            final v = await showDialog<String>(
              context: context,
              builder: (ctx) => SimpleDialog(
                title: const Text('Routing profile'),
                children: [
                  for (final p in RoutingProfile.all)
                    SimpleDialogOption(
                      onPressed: () => Navigator.pop(ctx, p.id),
                      child: ListTile(title: Text(p.label), subtitle: Text(p.description)),
                    ),
                ],
              ),
            );
            if (v != null) s.defaultProfile = v;
          },
        ),
        SwitchListTile(
          title: const Text('Stick to signposted cycle routes'),
          value: s.stickToCycleRoutes,
          onChanged: (v) => s.stickToCycleRoutes = v,
        ),
        ListTile(
          title: const Text('BRouter server'),
          subtitle: Text(s.brouterUrl),
          onTap: () async {
            final v = await promptText(context, 'BRouter server URL', initial: s.brouterUrl);
            if (v != null && v.startsWith('http')) s.brouterUrl = v;
          },
        ),
        const _Header('Places'),
        ListTile(
          title: const Text('Search distance from route'),
          subtitle: Text('${(s.poiRadiusFactor * 100).round()} % of the default per category '
              '(e.g. water ${(500 * s.poiRadiusFactor).round()} m, '
              'campsites ${(5 * s.poiRadiusFactor).toStringAsFixed(1)} km)'),
        ),
        Slider(
          value: s.poiRadiusFactor,
          min: 0.5,
          max: 3,
          divisions: 5,
          label: '${(s.poiRadiusFactor * 100).round()} %',
          onChanged: (v) => s.poiRadiusFactor = v,
        ),
        ListTile(
          title: const Text('Overpass servers'),
          subtitle: Text(s.overpassServers.join('\n')),
          onTap: () async {
            final v = await promptText(context, 'Overpass API URLs (comma separated)',
                initial: s.overpassServers.join(', '));
            if (v == null) return;
            final list = v.split(',').map((e) => e.trim()).where((e) => e.startsWith('http')).toList();
            if (list.isNotEmpty) s.overpassServers = list;
          },
        ),
        const _Header('Navigation'),
        SwitchListTile(
          title: const Text('Keep screen on while navigating'),
          value: s.keepScreenOn,
          onChanged: (v) => s.keepScreenOn = v,
        ),
        const _Header('About'),
        const ListTile(
          title: Text('VeloSM'),
          subtitle: Text('Map data © OpenStreetMap contributors (ODbL). Routing by BRouter. '
              'Places via Overpass API. Signposted routes via Waymarked Trails.'),
        ),
      ]),
    );
  }
}

class _Header extends StatelessWidget {
  final String text;

  const _Header(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text(text,
            style: TextStyle(
                color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.bold)),
      );
}
