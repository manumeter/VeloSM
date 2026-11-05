# VeloSM

Bicycle touring navigation based on OpenStreetMap, built for **long multi-day tours**
(hundreds to thousands of kilometers). Flutter app for Android; the same code base
builds for iOS.

## Features

- **Plan multi-day tours** on the map: search places or long-press to add waypoints.
  Routing uses [BRouter](https://brouter.de) with the touring profile and *stick to
  signposted cycle routes* switched on, so routes follow the local lcn/rcn/ncn/EuroVelo
  network wherever possible. Other profiles: safety, road bike, gravel, shortest.
- **Follow signposted routes**: search EuroVelo, national, regional and local cycle
  routes (via [Waymarked Trails](https://cycling.waymarkedtrails.org)) and import one
  as a tour. Super-routes like EuroVelo 6 are assembled into one line: VeloSM picks one
  path through parallel alternatives (e.g. both Danube banks), drops stray mapping
  fragments, and turns unmapped gaps into legs that are routed automatically.
- **Days (stages)**: mark any waypoint as an overnight stop, use "End day here" on a
  campsite, or let *Split into days* divide the tour into ~N km days. Optionally, splits
  snap to nearby campsites or hotels. Each day shows distance, climbing, an elevation
  profile and dates (if a start date is set).
- **Places along the route**: drinking water, toilets, showers, supermarkets, bakeries,
  restaurants, campsites, accommodation, shelters, bike shops/repair stations,
  pharmacies, ATMs and train stations, from OpenStreetMap via the Overpass API. They are
  downloaded per route section and **stored on the device**, so they work offline.
- **Navigation**: GPS position matched to the tour, turn hints, off-route warning,
  remaining distance and climbing for the day, and a **"Coming up" list**. For each
  place it shows how far ahead it is, how far off the route, and the estimated detour
  there and back. "Exact detour" calculates the real cycling distance. Places for the
  next 60 km load automatically while online. A *Simulate ride* option lets you try
  this without GPS.
- **GPX import/export**: each track in a GPX file becomes one day; export writes one
  track per day plus overnight stops and (optionally) the downloaded places.
- Map styles: CyclOSM, OpenStreetMap, OpenTopoMap, or a custom tile URL (e.g.
  Thunderforest OpenCycleMap with your API key), plus a signposted-routes overlay.

## Development

```bash
flutter pub get
flutter analyze
flutter test                                  # unit + widget tests (offline)
flutter test --run-skipped -t network         # checks against the live services
flutter run                                   # on a connected device / emulator
flutter build apk --release                   # Android
flutter build ipa                             # iOS (on macOS with Xcode)
```

### Code layout

| Path | Contents |
| --- | --- |
| `lib/core/` | Pure Dart logic: geo math, route matching + spatial index (`route_track.dart`), day planning, GPX, compact polyline storage, assembly of route relations |
| `lib/models/` | Tour / waypoint / leg / stage, POI categories |
| `lib/services/` | BRouter, Overpass, Nominatim, Waymarked Trails clients; JSON file storage |
| `lib/state/` | App state, settings, tour editor (background routing), POI download/cache, navigation |
| `lib/ui/` | Screens and widgets |

A tour is a list of waypoints with one *leg* between each pair. Legs are either routed
(recalculated when waypoints move), imported tracks (kept as they are), or straight lines.
Overnight waypoints divide the tour into days. Tours are stored as JSON with
polyline-encoded geometry (a 4,000 km tour is about 300 KB).

## Releasing on iOS

No code changes are needed; the platform setup is already in place:

- `ios/Runner/Info.plist` has the location usage strings and the `location` background
  mode (navigation keeps tracking with the screen off).
- Set the bundle id / team in Xcode (`ios/Runner.xcworkspace`), then `flutter build ipa`.

On Android, the app uses a foreground service notification while navigating
(`FOREGROUND_SERVICE_LOCATION`). Before publishing, set up a release signing key in
`android/app/build.gradle.kts`; it currently signs release builds with the debug key.

## Services and usage policies

VeloSM uses free community services by default. Before a public release, read their
policies and consider your own instances. All of these can be changed in Settings:

- **Map tiles**: the OSM, CyclOSM and OpenTopoMap tile servers allow light interactive
  use only. Bulk/offline prefetching is **not** allowed, so the app only caches tiles
  you have viewed. For a large user base, use a commercial or self-hosted tile provider
  (custom tile URL setting).
- **BRouter** (`brouter.de`): public instance; self-hosting is easy (BRouter server +
  rd5 segment files). The server URL is configurable.
- **Overpass API**: list of servers is configurable; requests are batched (about 120 km
  of route per request) and results are cached per tour.
- **Nominatim**: used only for explicit searches (no search-as-you-type), as its
  policy requires.
- **Waymarked Trails**: used for route search and import.

Map data © OpenStreetMap contributors (ODbL).
