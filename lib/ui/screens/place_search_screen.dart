import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../services/geocoding_service.dart';
import '../../state/app_state.dart';

class PlaceResult {
  final String name;
  final LatLng position;

  const PlaceResult(this.name, this.position);
}

/// Place search (Nominatim). Searches on submit only, as the service's usage
/// policy forbids search-as-you-type.
class PlaceSearchScreen extends StatefulWidget {
  const PlaceSearchScreen({super.key});

  @override
  State<PlaceSearchScreen> createState() => _PlaceSearchScreenState();
}

class _PlaceSearchScreenState extends State<PlaceSearchScreen> {
  final _ctrl = TextEditingController();
  List<Place> _results = const [];
  bool _loading = false;
  String? _error;

  Future<void> _search(String q) async {
    if (q.trim().isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await context.read<AppState>().geocoding.search(q.trim());
      setState(() => _results = r);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
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
                hintText: 'Town, address, landmark…', border: InputBorder.none),
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
                : ListView(children: [
                    for (final p in _results)
                      ListTile(
                        leading: const Icon(Icons.place),
                        title: Text(p.name),
                        subtitle: Text(p.detail, maxLines: 2, overflow: TextOverflow.ellipsis),
                        onTap: () => Navigator.pop(context, PlaceResult(p.name, p.position)),
                      ),
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('Search by Nominatim · © OpenStreetMap contributors',
                          style: TextStyle(fontSize: 11)),
                    ),
                  ]),
      );
}
