import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import 'bonus.dart';
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

/// A wall just closed; the player picks what the new region is for.
class RegionBuiltEvent extends GameEvent {
  RegionBuiltEvent(this.castle);
  final Castle castle;
}

class BonusEvent extends GameEvent {
  BonusEvent(this.point, this.food, this.boostUntil);
  final BonusPoint point;
  final double food;
  final DateTime boostUntil;
}

/// Holds the player's regions, stores and army, and turns GPS updates and time
/// into wall drawing, production, sieges, hunts and bonus visits.
class GameState extends ChangeNotifier {
  GameState({
    this.rules = const WallRules(),
    this.economyRules = const EconomyRules(),
    this.combatRules = const CombatRules(),
    this.bonusRules = const BonusRules(),
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
  final BonusRules bonusRules;
  final GameStorage? storage;
  final DateTime Function() _clock;
  final math.Random _rng;

  /// Debug: time skipped forward by the player.
  Duration _timeOffset = Duration.zero;

  /// How many wild monsters roam near the player.
  static const int wildMonsterCount = 4;

  /// GPS steps longer than this are treated as jumps and earn nothing.
  static const double maxStepMeters = 60;

  /// Steps shorter than this are GPS jitter while standing still.
  static const double minStepMeters = 2;

  /// The wall starts recording once you are this far from the castle, so the
  /// castle ends up inside the loop rather than on it.
  static const double wallStartDistance = 25;

  /// New castles must be at least this far from existing ones.
  static const double minCastleSpacing = 80;

  final List<Castle> castles = [];
  int _nextCastleId = 1;
  late Economy economy;
  Siege? siege;
  DateTime? nextSiegeAt;
  final List<WildMonster> monsters = [];
  int _nextMonsterId = 0;

  /// Nearby bonus places (restaurants) loaded from map data.
  List<BonusPoint> bonusPoints = [];

  /// When each bonus place was last collected, by id.
  final Map<String, DateTime> bonusCollectedAt = {};

  /// Production is boosted until this time after visiting a bonus place.
  DateTime? boostUntil;

  LatLng? position;

  /// The region whose wall is being walked, if any.
  Castle? drawingFor;
  final List<LatLng> walkedPath = [];
  String? message;

  /// Set when something happens that the screen should show; it clears it.
  GameEvent? pendingEvent;

  DateTime get now => _clock().add(_timeOffset);

  bool get drawingWall => drawingFor != null;

  Castle? castleById(int id) {
    for (final c in castles) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// The region the player is standing in or nearest to.
  Castle? get nearestCastle {
    final p = position;
    if (p == null || castles.isEmpty) return null;
    for (final c in castles) {
      if (c.hasWall && containsPoint(c.ring, p)) return c;
    }
    Castle? best;
    var bestDistance = double.infinity;
    for (final c in castles) {
      final d = metersBetween(c.position, p);
      if (d < bestDistance) {
        best = c;
        bestDistance = d;
      }
    }
    return best;
  }

  bool _isLive(Castle c) => c.hasWall && !c.isRuin(now, rules);

  Iterable<Castle> get liveCastles => castles.where(_isLive);

  bool get boosted {
    final until = boostUntil;
    return until != null && now.isBefore(until);
  }

  /// Total output per hour of all regions, including any bonus boost.
  ({double food, double soldiers, double upkeep}) get rates {
    var food = 0.0;
    var soldiers = 0.0;
    final t = now;
    for (final c in castles) {
      if (!c.hasWall) continue;
      final out = regionOutput(c, t);
      food += out.food;
      soldiers += out.soldiers;
    }
    final boost = boosted ? bonusRules.boostMultiplier : 1.0;
    return (
      food: food * boost,
      soldiers: soldiers * boost,
      upkeep: economy.soldiers * economyRules.upkeepPerSoldierHour,
    );
  }

  /// What one region makes per hour, before any bonus boost.
  ({double food, double soldiers}) regionOutput(Castle c, [DateTime? at]) {
    final eff = economyRules.efficiency(c.wallEfficiency(at ?? now, rules));
    final ha = c.hectares;
    return switch (c.type) {
      RegionType.farming => (food: ha * economyRules.foodPerHectareHour * eff, soldiers: 0.0),
      RegionType.military => (food: 0.0, soldiers: ha * economyRules.soldiersPerHectareHour * eff),
    };
  }

  Future<void> load() async {
    final raw = await storage?.load();
    if (raw == null) return;
    final json = jsonDecode(raw) as Map<String, dynamic>;
    castles.clear();
    final list = json['castles'] as List?;
    if (list != null) {
      castles.addAll(list.map((c) => Castle.fromJson(c as Map<String, dynamic>)));
    } else if (json['castle'] != null) {
      // Saves from before regions had types.
      castles.add(Castle.fromJson(json['castle'] as Map<String, dynamic>));
    }
    _nextCastleId = castles.fold(0, (m, c) => math.max(m, c.id)) + 1;
    final economyJson = json['economy'];
    if (economyJson != null) economy = Economy.fromJson(economyJson as Map<String, dynamic>);
    final siegeJson = json['siege'];
    siege = siegeJson == null ? null : Siege.fromJson(siegeJson as Map<String, dynamic>);
    final next = json['nextSiegeAt'];
    nextSiegeAt = next == null ? null : DateTime.parse(next as String);
    final boost = json['boostUntil'];
    boostUntil = boost == null ? null : DateTime.parse(boost as String);
    final collected = json['bonusCollectedAt'] as Map<String, dynamic>?;
    if (collected != null) {
      bonusCollectedAt.addAll(collected.map((k, v) => MapEntry(k, DateTime.parse(v as String))));
    }
    _update();
    notifyListeners();
  }

  Future<void> _save() async {
    await storage?.save(jsonEncode({
      'castles': castles.map((c) => c.toJson()).toList(),
      'economy': economy.toJson(),
      'siege': siege?.toJson(),
      'nextSiegeAt': nextSiegeAt?.toIso8601String(),
      'boostUntil': boostUntil?.toIso8601String(),
      'bonusCollectedAt': bonusCollectedAt.map((k, v) => MapEntry(k, v.toIso8601String())),
    }));
  }

  /// Brings production and sieges up to the current time.
  void _update() {
    final t = now;
    final r = rates;
    economy.advance(
      t,
      foodPerHour: r.food,
      soldiersPerHour: r.soldiers,
      rules: economyRules,
    );
    final s = siege;
    if (s != null) {
      final target = castleById(s.castleId);
      if (target == null || !_isLive(target)) {
        siege = null;
      } else if (s.arrived(t, combatRules)) {
        _resolveSiege(s, target);
      }
    }
    final next = nextSiegeAt;
    if (siege == null && next != null && !t.isBefore(next) && liveCastles.isNotEmpty) {
      _startSiege();
    }
  }

  /// Sends a monster at the weakest wall segment across all regions.
  void _startSiege() {
    Castle? target;
    var index = -1;
    var weakest = double.infinity;
    for (final c in liveCastles) {
      final i = c.weakestSegment(now, rules);
      final s = c.wall[i].strengthAt(now, rules);
      if (s < weakest) {
        weakest = s;
        target = c;
        index = i;
      }
    }
    if (target == null) return;
    final segment = target.wall[index];
    final point = lerp(segment.start, segment.end, 0.5);
    final outward = bearingBetween(target.position, point);
    siege = Siege(
      castleId: target.id,
      kind: MonsterKind.random(_rng),
      start: offsetBy(point, combatRules.siegeSpawnMeters, outward),
      target: point,
      segmentIndex: index,
      startedAt: now,
    );
    nextSiegeAt = null;
    message = 'A monster is marching on your weakest wall!';
    _save();
  }

  void _resolveSiege(Siege s, Castle c) {
    final segment = c.wall[s.segmentIndex.clamp(0, c.wall.length - 1)];
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

  double? distanceTo(LatLng point) {
    final p = position;
    return p == null ? null : metersBetween(p, point);
  }

  /// Fights [monster] with the hero and escort. Returns null if too far away.
  HuntOutcome? hunt(WildMonster monster) {
    final d = distanceTo(monster.position);
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

  /// Replaces the nearby bonus places, keeping their collection cooldowns.
  void setBonusPoints(List<BonusPoint> points) {
    bonusPoints = points;
    final p = position;
    if (p != null) _collectBonuses(p);
    notifyListeners();
  }

  /// Whether [point] can be collected now (its cooldown has passed).
  bool bonusReady(BonusPoint point) {
    final last = bonusCollectedAt[point.id];
    return last == null || !now.isBefore(last.add(bonusRules.cooldown));
  }

  void _collectBonuses(LatLng p) {
    for (final b in bonusPoints) {
      if (!bonusReady(b) || metersBetween(p, b.position) > bonusRules.radius) continue;
      _update(); // settle production before the boost starts
      bonusCollectedAt[b.id] = now;
      economy.food += bonusRules.foodGain;
      boostUntil = now.add(bonusRules.boostDuration);
      pendingEvent = BonusEvent(b, bonusRules.foodGain, boostUntil!);
      _save();
    }
  }

  /// Sets what a region's land is used for.
  void setRegionType(Castle c, RegionType type) {
    _update();
    c.type = type;
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

  bool canFortify(Castle c) => _isLive(c) && economy.parts >= combatRules.fortifyCost;

  /// Spends monster parts to strengthen every wall segment of [c].
  void fortify(Castle c) {
    if (!canFortify(c)) return;
    _update();
    economy.parts -= combatRules.fortifyCost;
    c.fortify(combatRules.fortifyAmount, now, rules);
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
    if (liveCastles.isEmpty || siege != null) return;
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
      _recordWallPoint(p);
    }
    _collectBonuses(p);
    notifyListeners();
  }

  void _onStep(LatLng p, double step) {
    final live = liveCastles.toList();
    if (live.isNotEmpty) {
      _update(); // settle production at the old wall strength first
      var reinforced = false;
      for (final c in live) {
        if (c.reinforceNear(p, step, now, rules) > 0) reinforced = true;
      }
      if (reinforced) _save();
    }
    if (drawingWall) {
      _recordWallPoint(p);
      _tryCloseLoop();
    }
  }

  /// Adds [p] to the wall being walked, once the player has left the castle.
  void _recordWallPoint(LatLng p) {
    final c = drawingFor!;
    if (walkedPath.isEmpty && metersBetween(p, c.position) < wallStartDistance) return;
    walkedPath.add(p);
  }

  void _tryCloseLoop() {
    final c = drawingFor;
    if (c == null || walkedPath.length < 3) return;
    if (pathLength(walkedPath) < rules.minLoopLength) return;
    if (metersBetween(walkedPath.first, walkedPath.last) > rules.closeLoopRadius) return;
    final result = buildWall(walkedPath, c.position, now, rules);
    if (result.segments != null) {
      _update();
      final firstWall = !c.hasWall;
      c.wall = result.segments!;
      drawingFor = null;
      walkedPath.clear();
      nextSiegeAt ??= now.add(const Duration(minutes: 15));
      message = null;
      if (firstWall) {
        pendingEvent = RegionBuiltEvent(c);
      } else {
        message = 'Wall rebuilt: ${c.wall.length} segments.';
      }
      _save();
    } else if (result.error == WallBuildError.doesNotEnclose) {
      walkedPath.clear();
      _recordWallPoint(position!);
      message = 'That loop did not go around your castle. Start again from here.';
    }
  }

  /// Why a castle can't be placed here, or null if it can.
  String? get placeBlockedReason {
    final p = position;
    if (p == null) return 'Waiting for GPS...';
    for (final c in castles) {
      if (c.hasWall && !c.isRuin(now, rules) && containsPoint(c.ring, p)) {
        return 'You are inside one of your regions. Walk outside its walls to start a new one.';
      }
      if (metersBetween(c.position, p) < minCastleSpacing) {
        return 'Too close to another castle. Walk at least ${minCastleSpacing.toStringAsFixed(0)} m away.';
      }
    }
    return null;
  }

  /// Places a new castle at the current position.
  bool placeCastle() {
    final reason = placeBlockedReason;
    if (reason != null) {
      message = reason;
      notifyListeners();
      return false;
    }
    final c = Castle(id: _nextCastleId++, position: position!);
    castles.add(c);
    message = null;
    startWall(c);
    _save();
    return true;
  }

  /// Starts recording the wall for [c] from the current position.
  void startWall(Castle c) {
    final p = position;
    if (p == null) return;
    drawingFor = c;
    walkedPath.clear();
    _recordWallPoint(p);
    notifyListeners();
  }

  void cancelWall() {
    final c = drawingFor;
    drawingFor = null;
    walkedPath.clear();
    message = null;
    // A castle that never got a wall isn't worth keeping.
    if (c != null && !c.hasWall) castles.remove(c);
    _save();
    notifyListeners();
  }

  void abandonCastle(Castle c) {
    if (drawingFor == c) {
      drawingFor = null;
      walkedPath.clear();
    }
    castles.remove(c);
    if (siege?.castleId == c.id) siege = null;
    if (liveCastles.isEmpty) nextSiegeAt = null;
    message = null;
    _save();
    notifyListeners();
  }

  /// Call periodically so production, sieges and decay show on screen.
  void tick() {
    _update();
    notifyListeners();
  }
}
