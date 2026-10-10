import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'game/bonus.dart';
import 'game/castle.dart';
import 'game/combat.dart';
import 'game/game_state.dart';
import 'game/geo.dart';
import 'services/location_service.dart';
import 'services/poi_service.dart';

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
  final poi = PoiService();
  final mapController = MapController();
  StreamSubscription<LatLng>? _positionSub;
  Timer? _tickTimer;
  bool _followPlayer = true;
  bool _mapReady = false;

  /// Debug: long-press the map to move there, for testing without walking.
  bool _simulate = false;

  /// Where restaurants were last loaded around, and whether a load is running.
  LatLng? _poiCenter;
  bool _poiLoading = false;

  @override
  void initState() {
    super.initState();
    game.addListener(_onGameChanged);
    game.load();
    _startLocation();
    // Fast enough to animate a marching siege monster.
    _tickTimer = Timer.periodic(const Duration(seconds: 2), (_) => game.tick());
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

  /// Loads restaurants when the player first appears or moves 300 m away.
  Future<void> _maybeLoadRestaurants(LatLng p) async {
    final last = _poiCenter;
    if (_poiLoading || (last != null && metersBetween(last, p) < 300)) return;
    _poiLoading = true;
    _poiCenter = p;
    try {
      game.setBonusPoints(await poi.restaurantsNear(p));
    } catch (_) {
      _poiCenter = last; // try again on the next move
    } finally {
      _poiLoading = false;
    }
  }

  void _onGameChanged() {
    final p = game.position;
    if (p != null) {
      if (_mapReady && _followPlayer) mapController.move(p, mapController.camera.zoom);
      _maybeLoadRestaurants(p);
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
    final String title;
    final String body;
    switch (event) {
      case RegionBuiltEvent(:final castle):
        _chooseRegionType(castle);
        return;
      case BonusEvent(:final point, :final food):
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${point.name}: +${food.toStringAsFixed(0)} food and '
              '${game.bonusRules.boostMultiplier}x production for '
              '${game.bonusRules.boostDuration.inMinutes} minutes!'),
        ));
        return;
      case SiegeEvent(:final kind, :final outcome):
        if (outcome.held) {
          title = 'The wall held!';
          body = 'A ${kind.name} (attack ${outcome.attack.toStringAsFixed(0)}) hit your weakest wall, '
              'but wall and garrison defended with ${outcome.defense.toStringAsFixed(0)}. '
              'Garrison lost: ${outcome.garrisonLost}.';
        } else {
          title = 'The wall was breached!';
          body = 'A ${kind.name} (attack ${outcome.attack.toStringAsFixed(0)}) broke through a defense of '
              '${outcome.defense.toStringAsFixed(0)}. That wall segment is down, '
              '${outcome.garrisonLost} garrison soldiers fell and '
              '${outcome.foodLost.toStringAsFixed(0)} food was stolen. Walk it to rebuild it.';
        }
      case HuntEvent(:final kind, :final outcome):
        if (outcome.won) {
          title = '${kind.name} defeated!';
          body = 'Your squad (${outcome.squadRoll.toStringAsFixed(0)}) beat the ${kind.name} '
              '(${outcome.monsterRoll.toStringAsFixed(0)}). You got ${outcome.partsGained} monster '
              'parts. Escorts lost: ${outcome.escortsLost}.';
        } else {
          title = 'Retreat!';
          body = 'The ${kind.name} (${outcome.monsterRoll.toStringAsFixed(0)}) was too strong for your squad '
              '(${outcome.squadRoll.toStringAsFixed(0)}). Escorts lost: ${outcome.escortsLost}. '
              'Bring more soldiers next time.';
        }
    }
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
      ),
    );
  }

  Future<void> _chooseRegionType(Castle castle) async {
    final r = game.economyRules;
    // Effective hectares at today's wall strength.
    final ha = castle.hectares * r.efficiency(castle.wallEfficiency(game.now, game.rules));
    final type = await showDialog<RegionType>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Wall complete! What is this region for?'),
        content: Text('Your new region is ${castle.hectares.toStringAsFixed(2)} ha. Walk its walls to make '
            'it produce more. You can change the type later from the region button.'),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: _regionColor(RegionType.farming)),
            onPressed: () => Navigator.pop(context, RegionType.farming),
            icon: Icon(_regionIcon(RegionType.farming)),
            label: Text('Farming\n+${(ha * r.foodPerHectareHour).toStringAsFixed(1)} food/h'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: _regionColor(RegionType.military)),
            onPressed: () => Navigator.pop(context, RegionType.military),
            icon: Icon(_regionIcon(RegionType.military)),
            label: Text('Military\n+${(ha * r.soldiersPerHectareHour).toStringAsFixed(1)} soldiers/h'),
          ),
        ],
      ),
    );
    if (type != null) game.setRegionType(castle, type);
  }

  Future<void> _onMonsterTap(WildMonster m) async {
    final d = game.distanceTo(m.position);
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

  void _onBonusTap(BonusPoint b) {
    final d = game.distanceTo(b.position);
    final ready = game.bonusReady(b);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ready
          ? '${b.name}: walk inside the circle${d == null ? '' : ' (${d.toStringAsFixed(0)} m away)'} '
              'for +${game.bonusRules.foodGain.toStringAsFixed(0)} food and a production boost.'
          : '${b.name}: already visited. Come back later.'),
    ));
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _tickTimer?.cancel();
    game.removeListener(_onGameChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = game.now;
    final nearest = game.nearestCastle;

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
              PolygonLayer(
                polygons: [
                  for (final c in game.castles)
                    if (c.hasWall)
                      Polygon(
                        points: c.ring,
                        color: (c.isRuin(now, game.rules) ? Colors.grey : _regionColor(c.type))
                            .withValues(alpha: 0.18),
                      ),
                ],
              ),
              CircleLayer(
                circles: [
                  for (final b in game.bonusPoints)
                    CircleMarker(
                      point: b.position,
                      radius: game.bonusRules.radius,
                      useRadiusInMeter: true,
                      color: (game.bonusReady(b) ? Colors.orange : Colors.grey).withValues(alpha: 0.25),
                      borderColor: game.bonusReady(b) ? Colors.orange : Colors.grey,
                      borderStrokeWidth: 2,
                    ),
                  if (game.drawingWall && game.walkedPath.isNotEmpty)
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
                  for (final c in game.castles)
                    for (final s in c.wall)
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
                      points: List.of(game.walkedPath),
                      strokeWidth: 4,
                      color: Colors.blueAccent,
                      pattern: StrokePattern.dashed(segments: const [10, 6]),
                    ),
                ],
              ),
              MarkerLayer(
                markers: [
                  for (final b in game.bonusPoints)
                    Marker(
                      point: b.position,
                      width: 110,
                      height: 44,
                      child: GestureDetector(
                        onTap: () => _onBonusTap(b),
                        child: _labeledIcon(
                          Icons.restaurant,
                          b.name,
                          game.bonusReady(b) ? Colors.deepOrange : Colors.grey,
                        ),
                      ),
                    ),
                  for (final c in game.castles)
                    Marker(
                      point: c.position,
                      width: 44,
                      height: 44,
                      child: Icon(
                        c.isRuin(now, game.rules) ? Icons.broken_image : Icons.castle,
                        size: 40,
                        color: c.isRuin(now, game.rules)
                            ? Colors.grey
                            : c.hasWall
                                ? _regionColor(c.type)
                                : Colors.brown.shade700,
                      ),
                    ),
                  for (final m in game.monsters)
                    Marker(
                      point: m.position,
                      width: 90,
                      height: 52,
                      child: GestureDetector(
                        onTap: () => _onMonsterTap(m),
                        child: _labeledIcon(Icons.pest_control,
                            '${m.kind.name} ${m.kind.power.toStringAsFixed(0)}', Colors.deepPurple),
                      ),
                    ),
                  if (game.siege != null)
                    Marker(
                      point: game.siege!.positionAt(now, game.combatRules),
                      width: 90,
                      height: 52,
                      child: _labeledIcon(Icons.pest_control,
                          '${game.siege!.kind.name} ${game.siege!.kind.power.toStringAsFixed(0)}', Colors.red),
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
          SafeArea(child: _statusCard(now)),
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
      bottomNavigationBar: SafeArea(child: _actions(nearest)),
    );
  }

  Widget _statusCard(DateTime now) {
    final live = game.liveCastles.length;
    final e = game.economy;
    final lines = <String>[
      if (game.castles.isEmpty) 'No regions yet. Tap "New region here" and walk a wall around it.',
      if (live > 0)
        '$live region${live == 1 ? '' : 's'} · Food ${e.food.toStringAsFixed(0)} · '
            'Garrison ${e.garrison} · Escort ${e.escort} · Parts ${e.parts}',
      if (game.boosted)
        'Restaurant boost: ${game.bonusRules.boostMultiplier}x production for '
            '${game.boostUntil!.difference(now).inMinutes + 1} more min',
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
    if (path.isEmpty) {
      return 'Walk ${GameState.wallStartDistance.toStringAsFixed(0)} m away from your castle, '
          'then walk a loop around it to raise its wall.';
    }
    final walked = pathLength(path);
    final min = game.rules.minLoopLength;
    if (walked < min) {
      return 'Walk a loop around your castle: ${walked.toStringAsFixed(0)} m of at least ${min.toStringAsFixed(0)} m';
    }
    final back = path.isEmpty ? 0.0 : metersBetween(path.last, path.first);
    return 'Wall walked: ${walked.toStringAsFixed(0)} m. Return to the blue circle '
        '(${back.toStringAsFixed(0)} m away) to close it.';
  }

  Widget _actions(Castle? nearest) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (!game.drawingWall)
            FilledButton.icon(
              onPressed: game.placeCastle,
              icon: const Icon(Icons.castle),
              label: const Text('New region here'),
            ),
          if (game.drawingWall)
            OutlinedButton(onPressed: game.cancelWall, child: const Text('Cancel wall')),
          if (nearest != null && nearest.hasWall && !game.drawingWall)
            FilledButton.tonalIcon(
              onPressed: () => _openRegionPanel(nearest),
              icon: Icon(_regionIcon(nearest.type)),
              label: Text('${nearest.type.label} region'),
            ),
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
            if (game.liveCastles.isNotEmpty && game.siege == null)
              ActionChip(label: const Text('Siege now'), onPressed: game.siegeNow),
          ],
        ],
      ),
    );
  }

  void _openRegionPanel(Castle castle) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => ListenableBuilder(
        listenable: game,
        builder: (context, _) => _RegionPanel(
          game: game,
          castle: castle,
          onRedraw: () {
            Navigator.pop(sheetContext);
            game.startWall(castle);
          },
          onAbandon: () async {
            final ok = await showDialog<bool>(
              context: sheetContext,
              builder: (context) => AlertDialog(
                title: const Text('Abandon region?'),
                content: const Text('This castle and its walls will be removed.'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep')),
                  TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Abandon')),
                ],
              ),
            );
            if (ok == true && sheetContext.mounted) {
              Navigator.pop(sheetContext);
              game.abandonCastle(castle);
            }
          },
        ),
      ),
    );
  }
}

/// One region's type, plus the shared army and upgrades.
class _RegionPanel extends StatelessWidget {
  const _RegionPanel({
    required this.game,
    required this.castle,
    required this.onRedraw,
    required this.onAbandon,
  });

  final GameState game;
  final Castle castle;
  final VoidCallback onRedraw;
  final VoidCallback onAbandon;

  @override
  Widget build(BuildContext context) {
    if (!game.castles.contains(castle)) return const SizedBox(height: 120);
    final theme = Theme.of(context);
    final now = game.now;
    final e = game.economy;
    final out = game.regionOutput(castle, now);
    final total = game.rates;
    final wallPct = (castle.wallEfficiency(now, game.rules) * 100).round();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('This region: ${castle.hectares.toStringAsFixed(2)} ha · walls $wallPct%',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            SegmentedButton<RegionType>(
              segments: [
                for (final t in RegionType.values)
                  ButtonSegment(value: t, label: Text(t.label), icon: Icon(_regionIcon(t))),
              ],
              selected: {castle.type},
              onSelectionChanged: (s) => game.setRegionType(castle, s.first),
            ),
            const SizedBox(height: 8),
            Text(switch (castle.type) {
              RegionType.farming => 'Makes +${out.food.toStringAsFixed(1)} food/h.',
              RegionType.military => 'Trains +${out.soldiers.toStringAsFixed(1)} soldiers/h '
                  '(${game.economyRules.foodPerSoldier.toStringAsFixed(0)} food each).',
            }),
            Text('Weak walls slow production. Walk them to keep it up.', style: theme.textTheme.bodySmall),
            const Divider(height: 24),
            Text('All regions: food +${total.food.toStringAsFixed(1)}/h, '
                'upkeep -${total.upkeep.toStringAsFixed(1)}/h, '
                'soldiers +${total.soldiers.toStringAsFixed(1)}/h'
                '${game.boosted ? ' (restaurant boost)' : ''}'),
            const SizedBox(height: 4),
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
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: game.canFortify(castle) ? () => game.fortify(castle) : null,
                  icon: const Icon(Icons.shield),
                  label: Text('Fortify +${game.combatRules.fortifyAmount.toStringAsFixed(0)} '
                      '(${game.combatRules.fortifyCost} parts)'),
                ),
                OutlinedButton.icon(
                  onPressed: onRedraw,
                  icon: const Icon(Icons.route),
                  label: const Text('Redraw wall'),
                ),
                TextButton(onPressed: onAbandon, child: const Text('Abandon')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

IconData _regionIcon(RegionType t) => switch (t) {
      RegionType.farming => Icons.agriculture,
      RegionType.military => Icons.shield,
    };

Color _regionColor(RegionType t) => switch (t) {
      RegionType.farming => Colors.green.shade700,
      RegionType.military => Colors.red.shade700,
    };

Widget _labeledIcon(IconData icon, String label, Color color) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 26, color: color),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
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
