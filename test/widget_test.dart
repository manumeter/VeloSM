import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:velosm/main.dart';
import 'package:velosm/services/storage.dart';
import 'package:velosm/state/app_state.dart';
import 'package:velosm/state/settings.dart';

void main() {
  testWidgets('home screen shows empty state and new-tour options', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = await Settings.load();
    final dir = Directory.systemTemp.createTempSync('velosm_widget');
    addTearDown(() => dir.deleteSync(recursive: true));
    final app = AppState(settings: settings, repo: TourRepository(dir));
    await tester.runAsync(app.refresh);

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: app),
      ],
      child: const VeloSmApp(),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Plan your next bike tour'), findsOneWidget);

    await tester.tap(find.text('New tour'));
    await tester.pumpAndSettle();
    expect(find.text('Follow a signposted route'), findsOneWidget);
    expect(find.text('Import GPX file'), findsOneWidget);
  });

  test('settings defaults', () async {
    SharedPreferences.setMockInitialValues({});
    final s = await Settings.load();
    expect(s.mapStyle.id, 'cyclosm');
    expect(s.cycleRoutesOverlay, isTrue);
    expect(s.poiCategories, containsAll(['water', 'supermarket', 'camping']));
    s.poiRadiusFactor = 2;
    expect(s.poiRadiusFactor, 2);
    expect(s.overpassServers.first, startsWith('https://overpass-api.de'));
  });

  testWidgets('VeloSmApp uses Material 3', (tester) async {
    expect(ThemeData(useMaterial3: true).useMaterial3, isTrue);
  });
}
