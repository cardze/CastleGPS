import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'game/castle.dart';
import 'game/game_state.dart';
import 'services/location_service.dart';

void main() {
  runApp(const CastleGpsApp());
}

class CastleGpsApp extends StatelessWidget {
  const CastleGpsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CastleGPS',
      theme: ThemeData(colorSchemeSeed: Colors.brown, useMaterial3: true),
      home: const MapScreen(),
    );
  }
}

class PrefsStorage implements GameStorage {
  static const _key = 'castlegps.save';

  @override
  Future<String?> load() async => (await SharedPreferences.getInstance()).getString(_key);

  @override
  Future<void> save(String json) async =>
      (await SharedPreferences.getInstance()).setString(_key, json);
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final game = GameState(storage: PrefsStorage());
  final location = LocationService();
  final mapController = MapController();
  StreamSubscription<LatLng>? _positionSub;
  Timer? _decayTimer;
  bool _followPlayer = true;
  bool _mapReady = false;

  /// Debug: long-press the map to move there, for testing without walking.
  bool _simulate = false;

  @override
  void initState() {
    super.initState();
    game.addListener(_onGameChanged);
    game.load();
    _startLocation();
    _decayTimer = Timer.periodic(const Duration(seconds: 30), (_) => game.tick());
  }

  Future<void> _startLocation() async {
    final error = await location.ensurePermission();
    if (error != null) {
      game.message = error;
      game.tick();
      return;
    }
    _positionSub = location.positions().listen((p) {
      if (!_simulate) game.onPosition(p);
    });
  }

  void _onGameChanged() {
    final p = game.position;
    if (_mapReady && _followPlayer && p != null) {
      mapController.move(p, mapController.camera.zoom);
    }
    setState(() {});
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _decayTimer?.cancel();
    game.removeListener(_onGameChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = game.now;
    final castle = game.castle;
    final ruin = castle?.isRuin(now, game.rules) ?? false;

    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: mapController,
            options: MapOptions(
              initialCenter: const LatLng(35.6812, 139.7671),
              initialZoom: 17,
              onMapReady: () => _mapReady = true,
              onPositionChanged: (_, hasGesture) {
                if (hasGesture) _followPlayer = false;
              },
              onLongPress: (_, point) {
                if (_simulate) game.onPosition(point);
              },
            ),
            children: [
              TileLayer(
                // OSM's public tiles are fine for a personal prototype. A real
                // release should serve its own tiles (see concept doc).
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.castlegps.castlegps',
              ),
              PolylineLayer(
                polylines: [
                  if (castle != null)
                    for (final s in castle.wall)
                      Polyline(
                        points: [s.start, s.end],
                        strokeWidth: 7,
                        color: _strengthColor(s.strengthAt(now, game.rules) / game.rules.maxStrength),
                      ),
                  if (game.walkedPath.length > 1)
                    Polyline(
                      points: game.walkedPath,
                      strokeWidth: 4,
                      color: Colors.blueAccent,
                      pattern: StrokePattern.dashed(segments: const [10, 6]),
                    ),
                ],
              ),
              MarkerLayer(
                markers: [
                  if (castle != null)
                    Marker(
                      point: castle.position,
                      width: 44,
                      height: 44,
                      child: Icon(
                        ruin ? Icons.broken_image : Icons.castle,
                        size: 40,
                        color: ruin ? Colors.grey : Colors.brown.shade700,
                      ),
                    ),
                  if (game.position != null)
                    Marker(
                      point: game.position!,
                      width: 22,
                      height: 22,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.blue,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 3),
                        ),
                      ),
                    ),
                ],
              ),
              RichAttributionWidget(
                attributions: [TextSourceAttribution('OpenStreetMap contributors')],
              ),
            ],
          ),
          SafeArea(child: _statusCard(castle, ruin, now)),
        ],
      ),
      floatingActionButton: FloatingActionButton.small(
        tooltip: 'Center on me',
        onPressed: () {
          _followPlayer = true;
          final p = game.position;
          if (_mapReady && p != null) mapController.move(p, mapController.camera.zoom);
        },
        child: const Icon(Icons.my_location),
      ),
      bottomNavigationBar: SafeArea(child: _actions(castle, ruin)),
    );
  }

  Widget _statusCard(Castle? castle, bool ruin, DateTime now) {
    final lines = <String>[
      if (castle == null) 'No castle yet. Go somewhere and place one.',
      if (castle != null && ruin) 'Your castle has fallen into ruin.',
      if (castle != null && !ruin && castle.hasWall)
        'Wall strength: ${castle.averageStrength(now, game.rules).toStringAsFixed(0)}'
            ' / ${game.rules.maxStrength.toStringAsFixed(0)} · ${castle.wall.length} segments',
      if (game.drawingWall) 'Wall walked: ${game.walkedPath.length} points',
      if (game.message != null) game.message!,
    ];
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [for (final l in lines) Text(l)],
        ),
      ),
    );
  }

  Widget _actions(Castle? castle, bool ruin) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Wrap(
        spacing: 8,
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (castle == null || ruin)
            FilledButton.icon(
              onPressed: game.placeCastle,
              icon: const Icon(Icons.castle),
              label: const Text('Place castle here'),
            ),
          if (castle != null && !ruin && !game.drawingWall)
            FilledButton.icon(
              onPressed: game.startWall,
              icon: const Icon(Icons.route),
              label: Text(castle.hasWall ? 'Redraw wall' : 'Draw wall'),
            ),
          if (game.drawingWall)
            OutlinedButton(onPressed: game.cancelWall, child: const Text('Cancel wall')),
          if (castle != null)
            TextButton(onPressed: _confirmAbandon, child: const Text('Abandon')),
          FilterChip(
            label: const Text('Simulate'),
            tooltip: 'Long-press the map to move there',
            selected: _simulate,
            onSelected: (v) => setState(() => _simulate = v),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmAbandon() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Abandon castle?'),
        content: const Text('Your castle and its walls will be removed.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Abandon')),
        ],
      ),
    );
    if (ok == true) game.abandonCastle();
  }
}

/// Red (0) through yellow to green (full strength).
Color _strengthColor(double fraction) {
  final f = fraction.clamp(0.0, 1.0);
  if (f <= 0) return Colors.grey;
  return f < 0.5
      ? Color.lerp(Colors.red, Colors.amber, f * 2)!
      : Color.lerp(Colors.amber, Colors.green, (f - 0.5) * 2)!;
}
