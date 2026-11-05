import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/geo.dart';
import '../../models/poi.dart';

/// Round category badge used in lists and on the map.
class PoiBadge extends StatelessWidget {
  final PoiCategory category;
  final double size;

  const PoiBadge(this.category, {super.key, this.size = 32});

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: category.color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: const [BoxShadow(blurRadius: 2, color: Colors.black26)],
        ),
        child: Icon(category.icon, color: Colors.white, size: size * 0.55),
      );
}

Marker poiMarker(Poi poi, {VoidCallback? onTap, double size = 30}) => Marker(
      point: poi.position,
      width: size,
      height: size,
      child: GestureDetector(onTap: onTap, child: PoiBadge(poi.cat, size: size)),
    );

/// "in 12.4 km · 300 m off route (≈ 750 m detour)"
String poiDistanceText(PoiOnRoute p, double currentAlong) {
  final ahead = p.along - currentAlong;
  final where = ahead.abs() < 50
      ? 'here'
      : ahead < 0
          ? '${formatDistance(-ahead)} behind'
          : 'in ${formatDistance(ahead)}';
  if (p.offset < 30) return '$where · on route';
  return '$where · ${formatDistance(p.offset)} off route (≈ ${formatDistance(p.detour)} detour)';
}

/// Short summary of useful tags (opening hours, fee, ...).
List<String> poiFacts(Poi poi) {
  final t = poi.tags;
  return [
    if (t['opening_hours'] != null) 'Open: ${t['opening_hours']}',
    if (t['fee'] == 'no') 'Free' else if (t['fee'] == 'yes') 'Fee required',
    if (t['drinking_water'] == 'yes' && poi.category != 'water') 'Drinking water',
    if (t['drinking_water'] == 'no') 'Not drinking water',
    if (t['seasonal'] == 'yes') 'Seasonal',
    if (t['tents'] == 'yes') 'Tents allowed',
    if (t['tents'] == 'no') 'No tents',
    if (t['shower'] == 'yes' || t['shower'] == 'hot') 'Showers',
    if (t['stars'] != null) '${t['stars']} stars',
    if (t['wheelchair'] == 'yes') 'Wheelchair accessible',
    if (t['access'] == 'private' || t['access'] == 'customers') 'Access: ${t['access']}',
    if (t['addr:street'] != null)
      [t['addr:street'], t['addr:housenumber'], t['addr:city']].whereType<String>().join(' '),
  ];
}

/// Bottom sheet with POI details and actions.
class PoiDetails extends StatelessWidget {
  final Poi poi;
  final PoiOnRoute? onRoute;
  final double currentAlong;
  final List<Widget> actions;

  const PoiDetails({
    super.key,
    required this.poi,
    this.onRoute,
    this.currentAlong = 0,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    final t = poi.tags;
    final website = t['website'] ?? t['contact:website'] ?? t['url'];
    final phone = t['phone'] ?? t['contact:phone'];
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              PoiBadge(poi.cat, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(poi.name, style: theme.textTheme.titleLarge),
                  Text(poi.cat.label, style: theme.textTheme.bodySmall),
                ]),
              ),
            ]),
            if (onRoute != null) ...[
              const SizedBox(height: 8),
              Text(poiDistanceText(onRoute!, currentAlong), style: theme.textTheme.titleSmall),
              Text('Route km ${(onRoute!.along / 1000).toStringAsFixed(1)}',
                  style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 8),
            for (final f in poiFacts(poi)) Text(f),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 4, children: [
              ...actions,
              if (website != null)
                OutlinedButton.icon(
                  icon: const Icon(Icons.public),
                  label: const Text('Website'),
                  onPressed: () => launchUrl(
                      Uri.parse(website.startsWith('http') ? website : 'https://$website'),
                      mode: LaunchMode.externalApplication),
                ),
              if (phone != null)
                OutlinedButton.icon(
                  icon: const Icon(Icons.call),
                  label: const Text('Call'),
                  onPressed: () => launchUrl(Uri.parse('tel:${phone.replaceAll(' ', '')}')),
                ),
              OutlinedButton.icon(
                icon: const Icon(Icons.map_outlined),
                label: const Text('OSM'),
                onPressed: () =>
                    launchUrl(Uri.parse(poi.osmUrl), mode: LaunchMode.externalApplication),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

/// Wrap of filter chips for selecting POI categories.
class CategoryChips extends StatelessWidget {
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;
  final Map<String, int>? counts;

  const CategoryChips({super.key, required this.selected, required this.onChanged, this.counts});

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(children: [
          for (final c in PoiCategory.all)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: FilterChip(
                avatar: Icon(c.icon, size: 18, color: c.color),
                label: Text(counts?[c.id] != null ? '${c.label} (${counts![c.id]})' : c.label),
                selected: selected.contains(c.id),
                onSelected: (v) {
                  final s = {...selected};
                  v ? s.add(c.id) : s.remove(c.id);
                  onChanged(s);
                },
              ),
            ),
        ]),
      );
}
