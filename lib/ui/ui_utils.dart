import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/gpx.dart';
import '../models/tour.dart';
import '../state/app_state.dart';

void showError(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(message),
    backgroundColor: Theme.of(context).colorScheme.error,
    duration: const Duration(seconds: 6),
  ));
}

void showInfo(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

Future<bool> confirm(BuildContext context, String title, String message,
    {String ok = 'Delete'}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ok)),
      ],
    ),
  );
  return r ?? false;
}

Future<String?> promptText(BuildContext context, String title,
    {String initial = '', String? hint, TextInputType? keyboard}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        keyboardType: keyboard,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('OK')),
      ],
    ),
  );
}

/// Runs [task] behind a modal progress dialog.
Future<T> runWithProgress<T>(BuildContext context, String message, Future<T> Function() task) async {
  final nav = Navigator.of(context, rootNavigator: true);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(children: [
          const CircularProgressIndicator(),
          const SizedBox(width: 20),
          Expanded(child: Text(message)),
        ]),
      ),
    ),
  );
  try {
    return await task();
  } finally {
    nav.pop();
  }
}

Future<void> shareGpx(BuildContext context, Tour tour) async {
  final app = context.read<AppState>();
  final pois = await app.repo.loadPois(tour.id);
  if (!context.mounted) return;
  final includePois = pois.pois.isNotEmpty &&
      await confirm(context, 'Include places?',
          'Add the ${pois.pois.length} downloaded places (water, campsites, …) as waypoints?',
          ok: 'Include');
  final xml = Gpx.write(tour, pois: includePois ? pois.pois.values.toList() : const []);
  final dir = await getTemporaryDirectory();
  final safe = tour.name.replaceAll(RegExp(r'[^\w\- ]+'), '').trim();
  final file = File('${dir.path}/${safe.isEmpty ? 'tour' : safe}.gpx');
  await file.writeAsString(xml);
  await SharePlus.instance.share(ShareParams(
    files: [XFile(file.path, mimeType: 'application/gpx+xml')],
    subject: tour.name,
  ));
}
