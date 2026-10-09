import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import 'castle.dart';
import 'combat.dart';
import 'economy.dart';
import 'geo.dart';

/// Saves and loads the game. The app uses SharedPreferences; tests use memory.
abstract class GameStorage {
  Future<String?> load();
  Future<void> save(String json);
}

/// Something that happened that the screen should announce.
sealed class GameEvent {}

class SiegeEvent extends GameEvent {
  SiegeEvent(this.kind, this.outcome);
  final MonsterKind kind;
  final SiegeOutcome outcome;
}

class HuntEvent extends GameEvent {
  HuntEvent(this.kind, this.outcome);
  final MonsterKind kind;
  final HuntOutcome outcome;
}

/// Holds the player's castle, stores and army, and turns GPS updates and time
/// into wall drawing, production, sieges and hunts.
class GameState extends ChangeNotifier {
  GameState({
    this.rules = const WallRules(),
    this.economyRules = const EconomyRules(),
    this.combatRules = const CombatRules(),
    this.storage,
    DateTime Function()? clock,
    math.Random? random,
  })  : _clock = clock ?? DateTime.now,
        _rng = random ?? math.Random() {
    economy = Economy(updatedAt: now);
  }

  final WallRules rules;
  final EconomyRules economyRules;
  final CombatRules combatRules;
  final GameStorage? storage;
  final DateTime Function() _clock;
  final math.Random _rng;

  /// Debug: time skipped forward by the player.
  Duration _timeOffset = Duration.zero;

  /// How many wild monsters roam near the player.
  static const int wildMonsterCount = 4;

  late Economy economy;
  Siege? siege;
  DateTime? nextSiegeAt;
  final List<WildMonster> monsters = [];
  int _nextMonsterId = 0;

  /// Set when a siege or hunt resolves; the screen shows it and clears it.
  GameEvent? pendingEvent;

  /// GPS steps longer than this are treated as jumps and earn nothing.
  static const double maxStepMeters = 60;

  /// Steps shorter than this are GPS jitter while standing still.
  static const double minStepMeters = 2;

  Castle? castle;
  LatLng? position;
  bool drawingWall = false;
  final List<LatLng> walkedPath = [];
  String? message;

  DateTime get now => _clock().add(_timeOffset);

  Future<void> load() async {
    final raw = await storage?.load();
    if (raw == null) return;
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final castleJson = json['castle'];
    castle = castleJson == null ? null : Castle.fromJson(castleJson as Map<String, dynamic>);
    final economyJson = json['economy'];
    if (economyJson != null) economy = Economy.fromJson(economyJson as Map<String, dynamic>);
    final siegeJson = json['siege'];
    siege = siegeJson == null ? null : Siege.fromJson(siegeJson as Map<String, dynamic>);
    final next = json['nextSiegeAt'];
    nextSiegeAt = next == null ? null : DateTime.parse(next as String);
    _update();
    notifyListeners();
  }

  Future<void> _save() async {
    await storage?.save(jsonEncode({
      'castle': castle?.toJson(),
      'economy': economy.toJson(),
      'siege': siege?.toJson(),
      'nextSiegeAt': nextSiegeAt?.toIso8601String(),
    }));
  }

  bool get _hasLiveCastle {
    final c = castle;
    return c != null && c.hasWall && !c.isRuin(now, rules);
  }

  /// Brings production and sieges up to the current time.
  void _update() {
    final c = castle;
    final t = now;
    if (c == null || !c.hasWall) {
      economy.updatedAt = t;
      return;
    }
    economy.advance(
      t,
      hectares: c.hectares,
      farmShare: c.farmShare,
      wallFraction: c.wallEfficiency(t, rules),
      rules: economyRules,
    );
    if (!_hasLiveCastle) {
      siege = null;
      return;
    }
    final next = nextSiegeAt;
    if (siege == null && next != null && !t.isBefore(next)) _startSiege();
    final s = siege;
    if (s != null && s.arrived(t, combatRules)) _resolveSiege(s);
  }

  void _startSiege() {
    final c = castle!;
    final index = c.weakestSegment(now, rules);
    if (index < 0) return;
    final segment = c.wall[index];
    final target = lerp(segment.start, segment.end, 0.5);
    final outward = bearingBetween(c.position, target);
    siege = Siege(
      kind: MonsterKind.random(_rng),
      start: offsetBy(target, combatRules.siegeSpawnMeters, outward),
      target: target,
      segmentIndex: index,
      startedAt: now,
    );
    nextSiegeAt = null;
    message = 'A monster is marching on your weakest wall!';
    _save();
  }

  void _resolveSiege(Siege s) {
    final c = castle!;
    final index = s.segmentIndex.clamp(0, c.wall.length - 1);
    final segment = c.wall[index];
    final outcome = resolveSiege(
      attack: s.kind.power,
      segmentStrength: segment.strengthAt(now, rules),
      garrison: economy.garrison,
      food: economy.food,
      rules: combatRules,
    );
    segment.reinforce(-outcome.wallDamage, now, rules);
    economy.garrison -= outcome.garrisonLost;
    economy.food -= outcome.foodLost;
    siege = null;
    nextSiegeAt = now.add(Duration(minutes: (combatRules.siegeIntervalHours * 60).round()));
    pendingEvent = SiegeEvent(s.kind, outcome);
    message = null;
    _save();
  }

  /// Keeps a few wild monsters within reach of the player.
  void _ensureMonsters(LatLng p) {
    monsters.removeWhere((m) => metersBetween(m.position, p) > 600);
    while (monsters.length < wildMonsterCount) {
      final distance = 120 + _rng.nextDouble() * 280;
      final bearing = _rng.nextDouble() * 2 * math.pi;
      monsters.add(WildMonster(
        id: _nextMonsterId++,
        kind: MonsterKind.random(_rng),
        position: offsetBy(p, distance, bearing),
      ));
    }
  }

  double? distanceTo(WildMonster m) {
    final p = position;
    return p == null ? null : metersBetween(p, m.position);
  }

  /// Fights [monster] with the hero and escort. Returns null if too far away.
  HuntOutcome? hunt(WildMonster monster) {
    final d = distanceTo(monster);
    if (d == null || d > combatRules.fightRange) {
      message = 'Walk closer to the ${monster.kind.name} to fight it.';
      notifyListeners();
      return null;
    }
    _update();
    final outcome = resolveHunt(
      monster: monster.kind,
      escort: economy.escort,
      rng: _rng,
      rules: combatRules,
    );
    economy.escort -= outcome.escortsLost;
    economy.parts += outcome.partsGained;
    if (outcome.won) monsters.remove(monster);
    pendingEvent = HuntEvent(monster.kind, outcome);
    _save();
    notifyListeners();
    return outcome;
  }

  /// Sets how much of the land inside the walls is farmland (0..1).
  void setFarmShare(double share) {
    final c = castle;
    if (c == null) return;
    _update();
    c.farmShare = share.clamp(0.0, 1.0);
    _save();
    notifyListeners();
  }

  /// Moves soldiers between garrison and escort. Positive moves to escort.
  void reassign(int n) {
    _update();
    economy.reassign(n);
    _save();
    notifyListeners();
  }

  bool get canFortify => _hasLiveCastle && economy.parts >= combatRules.fortifyCost;

  /// Spends monster parts to strengthen every wall segment.
  void fortify() {
    if (!canFortify) return;
    _update();
    economy.parts -= combatRules.fortifyCost;
    castle!.fortify(combatRules.fortifyAmount, now, rules);
    message = 'Walls fortified.';
    _save();
    notifyListeners();
  }

  /// Debug: jumps the clock forward.
  void skipTime(Duration d) {
    _timeOffset += d;
    _update();
    notifyListeners();
  }

  /// Debug: starts a siege right away.
  void siegeNow() {
    if (!_hasLiveCastle || siege != null) return;
    _update();
    _startSiege();
    notifyListeners();
  }

  /// Debug: walks in a straight line from the current position to [target],
  /// in small steps, as if the player had walked there.
  void simulateWalkTo(LatLng target) {
    final from = position;
    if (from == null) {
      onPosition(target);
      return;
    }
    final steps = (metersBetween(from, target) / 5).ceil();
    for (var i = 1; i <= steps; i++) {
      onPosition(lerp(from, target, i / steps));
    }
  }

  void onPosition(LatLng p) {
    final previous = position;
    position = p;
    _ensureMonsters(p);
    if (previous != null) {
      final step = metersBetween(previous, p);
      if (step >= minStepMeters && step <= maxStepMeters) {
        _onStep(p, step);
      }
    } else if (drawingWall) {
      walkedPath.add(p);
    }
    notifyListeners();
  }

  void _onStep(LatLng p, double step) {
    final c = castle;
    if (c != null && c.hasWall && !c.isRuin(now, rules)) {
      _update(); // settle production at the old wall strength first
      if (c.reinforceNear(p, step, now, rules) > 0) _save();
    }
    if (drawingWall) {
      walkedPath.add(p);
      _tryCloseLoop();
    }
  }

  void _tryCloseLoop() {
    final c = castle;
    if (c == null || walkedPath.length < 3) return;
    if (pathLength(walkedPath) < rules.minLoopLength) return;
    if (metersBetween(walkedPath.first, walkedPath.last) > rules.closeLoopRadius) return;
    final result = buildWall(walkedPath, c.position, now, rules);
    if (result.segments != null) {
      c.wall = result.segments!;
      drawingWall = false;
      walkedPath.clear();
      economy.updatedAt = now;
      nextSiegeAt ??= now.add(const Duration(minutes: 15));
      message = 'Wall complete: ${c.wall.length} segments. Walk it to make it stronger.';
      _save();
    } else if (result.error == WallBuildError.doesNotEnclose) {
      walkedPath
        ..clear()
        ..add(position!);
      message = 'That loop did not go around your castle. Start again from here.';
    }
  }

  /// Places a castle at the current position, replacing any ruin.
  bool placeCastle() {
    final p = position;
    if (p == null) {
      message = 'Waiting for GPS...';
      notifyListeners();
      return false;
    }
    final c = castle;
    if (c != null && !c.isRuin(now, rules)) {
      message = 'You already have a castle.';
      notifyListeners();
      return false;
    }
    castle = Castle(position: p);
    message = 'Castle placed. Now walk a loop around it to raise a wall.';
    _save();
    notifyListeners();
    return true;
  }

  void startWall() {
    final p = position;
    if (castle == null || p == null) return;
    drawingWall = true;
    walkedPath
      ..clear()
      ..add(p);
    message = null;
    notifyListeners();
  }

  void cancelWall() {
    drawingWall = false;
    walkedPath.clear();
    message = null;
    notifyListeners();
  }

  void abandonCastle() {
    castle = null;
    siege = null;
    nextSiegeAt = null;
    cancelWall();
    _save();
  }

  /// Call periodically so production, sieges and decay show on screen.
  void tick() {
    _update();
    notifyListeners();
  }
}
