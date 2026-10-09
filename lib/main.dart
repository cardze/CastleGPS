import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'game/castle.dart';
import 'game/combat.dart';
import 'game/game_state.dart';
import 'game/geo.dart';
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
    // Fast enough to animate a marching siege monster.
    _decayTimer = Timer.periodic(const Duration(seconds: 2), (_) => game.tick());
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
    final event = game.pendingEvent;
    if (event != null) {
      game.pendingEvent = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => _showEvent(event));
    }
    setState(() {});
  }

  void _showEvent(GameEvent event) {
    if (!mounted) return;
    final (title, body) = switch (event) {
      SiegeEvent(:final kind, :final outcome) => outcome.held
          ? (
              'The wall held!',
              'A ${kind.name} (attack ${outcome.attack.toStringAsFixed(0)}) hit your weakest wall, '
                  'but wall and garrison defended with ${outcome.defense.toStringAsFixed(0)}. '
                  'Garrison lost: ${outcome.garrisonLost}.'
            )
          : (
              'The wall was breached!',
              'A ${kind.name} (attack ${outcome.attack.toStringAsFixed(0)}) broke through a defense of '
                  '${outcome.defense.toStringAsFixed(0)}. That wall segment is down, '
                  '${outcome.garrisonLost} garrison soldiers fell and '
                  '${outcome.foodLost.toStringAsFixed(0)} food was stolen. Walk it to rebuild it.'
            ),
      HuntEvent(:final kind, :final outcome) => outcome.won
          ? (
              '${kind.name} defeated!',
              'Your squad (${outcome.squadRoll.toStringAsFixed(0)}) beat the ${kind.name} '
                  '(${outcome.monsterRoll.toStringAsFixed(0)}). You got ${outcome.partsGained} monster '
                  'parts. Escorts lost: ${outcome.escortsLost}.'
            )
          : (
              'Retreat!',
              'The ${kind.name} (${outcome.monsterRoll.toStringAsFixed(0)}) was too strong for your squad '
                  '(${outcome.squadRoll.toStringAsFixed(0)}). Escorts lost: ${outcome.escortsLost}. '
                  'Bring more soldiers next time.'
            ),
    };
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
      ),
    );
  }

  Future<void> _onMonsterTap(WildMonster m) async {
    final d = game.distanceTo(m);
    if (d == null) return;
    if (d > game.combatRules.fightRange) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${m.kind.name} (power ${m.kind.power.toStringAsFixed(0)}) is '
            '${d.toStringAsFixed(0)} m away. Walk within '
            '${game.combatRules.fightRange.toStringAsFixed(0)} m to fight.'),
      ));
      return;
    }
    final squad = game.combatRules.heroPower + game.economy.escort * game.combatRules.escortPower;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Fight the ${m.kind.name}?'),
        content: Text('Monster power: ${m.kind.power.toStringAsFixed(0)}\n'
            'Your squad: ${squad.toStringAsFixed(0)} (you + ${game.economy.escort} escorts)'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Leave')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Fight')),
        ],
      ),
    );
    if (ok == true) game.hunt(m);
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
                if (_simulate) game.simulateWalkTo(point);
              },
            ),
            children: [
              TileLayer(
                // OSM's public tiles are fine for a personal prototype. A real
                // release should serve its own tiles (see concept doc).
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.castlegps.castlegps',
              ),
              if (game.drawingWall && game.walkedPath.isNotEmpty)
                CircleLayer(
                  circles: [
                    CircleMarker(
                      point: game.walkedPath.first,
                      radius: game.rules.closeLoopRadius,
                      useRadiusInMeter: true,
                      color: Colors.blue.withValues(alpha: 0.15),
                      borderColor: Colors.blue,
                      borderStrokeWidth: 2,
                    ),
                  ],
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
                  if (game.siege != null)
                    Polyline(
                      points: [game.siege!.positionAt(now, game.combatRules), game.siege!.target],
                      strokeWidth: 3,
                      color: Colors.red,
                      pattern: StrokePattern.dashed(segments: const [8, 6]),
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
                  for (final m in game.monsters)
                    Marker(
                      point: m.position,
                      width: 90,
                      height: 52,
                      child: GestureDetector(
                        onTap: () => _onMonsterTap(m),
                        child: _monsterIcon(m.kind, Colors.deepPurple),
                      ),
                    ),
                  if (game.siege != null)
                    Marker(
                      point: game.siege!.positionAt(now, game.combatRules),
                      width: 90,
                      height: 52,
                      child: _monsterIcon(game.siege!.kind, Colors.red),
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
      if (castle != null && !ruin && castle.hasWall)
        'Food ${game.economy.food.toStringAsFixed(0)} · Garrison ${game.economy.garrison}'
            ' · Escort ${game.economy.escort} · Parts ${game.economy.parts}',
      if (game.siege != null)
        'Siege! A ${game.siege!.kind.name} (attack ${game.siege!.kind.power.toStringAsFixed(0)}) is '
            '${(game.siege!.distance * (1 - game.siege!.progress(now, game.combatRules))).toStringAsFixed(0)} m '
            'from your weakest wall.',
      if (game.drawingWall) _wallProgress(),
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

  String _wallProgress() {
    final path = game.walkedPath;
    final walked = pathLength(path);
    final min = game.rules.minLoopLength;
    if (walked < min) {
      return 'Walk a loop around your castle: ${walked.toStringAsFixed(0)} m of at least ${min.toStringAsFixed(0)} m';
    }
    final back = path.isEmpty ? 0.0 : metersBetween(path.last, path.first);
    return 'Wall walked: ${walked.toStringAsFixed(0)} m. Return to the blue circle '
        '(${back.toStringAsFixed(0)} m away) to close it.';
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
          if (castle != null && !ruin && castle.hasWall && !game.drawingWall)
            FilledButton.tonalIcon(
              onPressed: _openCastlePanel,
              icon: const Icon(Icons.agriculture),
              label: const Text('Castle'),
            ),
          if (castle != null)
            TextButton(onPressed: _confirmAbandon, child: const Text('Abandon')),
          FilterChip(
            label: const Text('Simulate'),
            tooltip: 'Long-press the map to move there',
            selected: _simulate,
            onSelected: (v) => setState(() => _simulate = v),
          ),
          if (_simulate) ...[
            ActionChip(
              label: const Text('+1 h'),
              tooltip: 'Skip time forward',
              onPressed: () => game.skipTime(const Duration(hours: 1)),
            ),
            if (castle != null && castle.hasWall && game.siege == null)
              ActionChip(label: const Text('Siege now'), onPressed: game.siegeNow),
          ],
        ],
      ),
    );
  }

  void _openCastlePanel() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => ListenableBuilder(
        listenable: game,
        builder: (context, _) => _CastlePanel(game: game),
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

Widget _monsterIcon(MonsterKind kind, Color color) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.pest_control, size: 30, color: color),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text('${kind.name} ${kind.power.toStringAsFixed(0)}',
              style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.bold)),
        ),
      ],
    );

/// Red (0) through yellow to green (full strength).
Color _strengthColor(double fraction) {
  final f = fraction.clamp(0.0, 1.0);
  if (f <= 0) return Colors.grey;
  return f < 0.5
      ? Color.lerp(Colors.red, Colors.amber, f * 2)!
      : Color.lerp(Colors.amber, Colors.green, (f - 0.5) * 2)!;
}

/// Zones, army and upgrades for the player's castle.
class _CastlePanel extends StatelessWidget {
  const _CastlePanel({required this.game});

  final GameState game;

  @override
  Widget build(BuildContext context) {
    final castle = game.castle;
    if (castle == null || !castle.hasWall) return const SizedBox(height: 120);
    final now = game.now;
    final e = game.economy;
    final r = e.rates(
      hectares: castle.hectares,
      farmShare: castle.farmShare,
      wallFraction: castle.wallEfficiency(now, game.rules),
      rules: game.economyRules,
    );
    final farmPct = (castle.farmShare * 100).round();
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Your land: ${castle.hectares.toStringAsFixed(2)} ha', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Row(
              children: [
                Text('Farmland $farmPct%'),
                Expanded(
                  child: Slider(
                    value: castle.farmShare,
                    divisions: 10,
                    onChanged: game.setFarmShare,
                  ),
                ),
                Text('Barracks ${100 - farmPct}%'),
              ],
            ),
            Text('Food +${r.food.toStringAsFixed(1)}/h, upkeep -${r.upkeep.toStringAsFixed(1)}/h · '
                'Soldiers +${r.soldiers.toStringAsFixed(1)}/h '
                '(${game.economyRules.foodPerSoldier.toStringAsFixed(0)} food each)'),
            Text('Weak walls slow production. Walk them to keep it up.', style: theme.textTheme.bodySmall),
            const Divider(height: 24),
            Text('Food ${e.food.toStringAsFixed(0)} · Parts ${e.parts}', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: Text('Garrison ${e.garrison}\nDefends walls in sieges')),
                IconButton.filledTonal(
                  tooltip: 'Send one to escort',
                  onPressed: e.garrison > 0 ? () => game.reassign(1) : null,
                  icon: const Icon(Icons.arrow_forward),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: 'Bring one home',
                  onPressed: e.escort > 0 ? () => game.reassign(-1) : null,
                  icon: const Icon(Icons.arrow_back),
                ),
                Expanded(
                  child: Text('Escort ${e.escort}\nFights with you in hunts', textAlign: TextAlign.end),
                ),
              ],
            ),
            const Divider(height: 24),
            FilledButton.icon(
              onPressed: game.canFortify ? game.fortify : null,
              icon: const Icon(Icons.shield),
              label: Text('Fortify all walls +${game.combatRules.fortifyAmount.toStringAsFixed(0)} '
                  '(${game.combatRules.fortifyCost} parts)'),
            ),
          ],
        ),
      ),
    );
  }
}
