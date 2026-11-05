import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../state/settings.dart';

/// Map with the configured base layer, optional signposted cycle route
/// overlay and the attributions the tile providers require.
class BaseMap extends StatelessWidget {
  final MapController? controller;
  final LatLng initialCenter;
  final double initialZoom;
  final CameraFit? initialFit;
  final List<Widget> layers;
  final TapCallback? onTap;
  final LongPressCallback? onLongPress;
  final PositionCallback? onPositionChanged;
  final VoidCallback? onMapReady;
  final bool interactive;

  const BaseMap({
    super.key,
    this.controller,
    this.initialCenter = const LatLng(48.5, 9.0),
    this.initialZoom = 5,
    this.initialFit,
    this.layers = const [],
    this.onTap,
    this.onLongPress,
    this.onPositionChanged,
    this.onMapReady,
    this.interactive = true,
  });

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<Settings>();
    final style = settings.mapStyle;
    return FlutterMap(
      mapController: controller,
      options: MapOptions(
        initialCenter: initialCenter,
        initialZoom: initialZoom,
        initialCameraFit: initialFit,
        minZoom: 3,
        maxZoom: 19,
        onTap: onTap,
        onLongPress: onLongPress,
        onPositionChanged: onPositionChanged,
        onMapReady: onMapReady,
        interactionOptions: InteractionOptions(
          flags: interactive
              ? InteractiveFlag.all & ~InteractiveFlag.rotate
              : InteractiveFlag.none,
        ),
      ),
      children: [
        TileLayer(
          urlTemplate: style.url,
          subdomains: style.subdomains,
          maxNativeZoom: style.maxZoom,
          userAgentPackageName: 'app.velosm.velosm',
        ),
        if (settings.cycleRoutesOverlay)
          TileLayer(
            urlTemplate: MapStyle.cycleRoutesOverlay.url,
            maxNativeZoom: 17,
            userAgentPackageName: 'app.velosm.velosm',
          ),
        ...layers,
        RichAttributionWidget(
          alignment: AttributionAlignment.bottomLeft,
          attributions: [
            TextSourceAttribution(
              style.attribution,
              onTap: () => launchUrl(Uri.parse('https://www.openstreetmap.org/copyright')),
            ),
            if (settings.cycleRoutesOverlay)
              TextSourceAttribution(
                MapStyle.cycleRoutesOverlay.attribution,
                onTap: () => launchUrl(Uri.parse('https://cycling.waymarkedtrails.org')),
              ),
            const TextSourceAttribution('Routing: BRouter'),
          ],
        ),
      ],
    );
  }
}

/// Fits the camera to [points] (no-op for fewer than two distinct points).
void fitTo(MapController c, List<LatLng> points, {EdgeInsets padding = const EdgeInsets.all(48)}) {
  if (points.isEmpty) return;
  if (points.length == 1) {
    c.move(points.first, 13);
    return;
  }
  c.fitCamera(CameraFit.coordinates(coordinates: points, padding: padding, maxZoom: 16));
}
