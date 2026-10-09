import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'geo.dart';

/// Tunable numbers for sieges and hunts.
class CombatRules {
  const CombatRules({
    this.siegeIntervalHours = 6,
    this.siegeSpawnMeters = 250,
    this.siegeSpeed = 2,
    this.garrisonPower = 5,
    this.heroPower = 22,
    this.escortPower = 6,
    this.fightRange = 40,
    this.fortifyCost = 3,
    this.fortifyAmount = 30,
  });

  /// Hours between sieges once a castle has a wall.
  final double siegeIntervalHours;

  /// How far from the castle a siege monster appears.
  final double siegeSpawnMeters;

  /// Siege monster speed in meters per second.
  final double siegeSpeed;

  /// Defense each garrison soldier adds to the attacked wall segment.
  final double garrisonPower;

  /// The player's own strength in a hunt.
  final double heroPower;

  /// Strength each escort soldier adds in a hunt.
  final double escortPower;

  /// How close (meters) you must be to a monster to fight it.
  final double fightRange;

  /// Monster parts needed to fortify every wall segment.
  final int fortifyCost;

  /// Strength fortifying adds to every segment.
  final double fortifyAmount;
}

class MonsterKind {
  const MonsterKind(this.name, this.power, this.weight);

  final String name;
  final double power;

  /// Relative spawn chance.
  final int weight;

  static const all = [
    MonsterKind('Goblin', 20, 5),
    MonsterKind('Wolf pack', 35, 4),
    MonsterKind('Ogre', 60, 2),
    MonsterKind('Wyvern', 100, 1),
  ];

  static MonsterKind random(math.Random rng) {
    final total = all.fold<int>(0, (sum, k) => sum + k.weight);
    var roll = rng.nextInt(total);
    for (final k in all) {
      if (roll < k.weight) return k;
      roll -= k.weight;
    }
    return all.first;
  }
}

/// A monster roaming the map that the player can hunt.
class WildMonster {
  WildMonster({required this.id, required this.kind, required this.position});

  final int id;
  final MonsterKind kind;
  final LatLng position;
}

/// A monster marching on the castle to attack its weakest wall segment.
class Siege {
  Siege({
    required this.kind,
    required this.start,
    required this.target,
    required this.segmentIndex,
    required this.startedAt,
  });

  final MonsterKind kind;
  final LatLng start;
  final LatLng target;
  final int segmentIndex;
  final DateTime startedAt;

  double get distance => metersBetween(start, target);

  double progress(DateTime now, CombatRules rules) {
    if (distance == 0) return 1;
    final walked = now.difference(startedAt).inMilliseconds / 1000 * rules.siegeSpeed;
    return (walked / distance).clamp(0.0, 1.0);
  }

  LatLng positionAt(DateTime now, CombatRules rules) =>
      lerp(start, target, progress(now, rules));

  bool arrived(DateTime now, CombatRules rules) => progress(now, rules) >= 1;

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'start': [start.latitude, start.longitude],
        'target': [target.latitude, target.longitude],
        'segmentIndex': segmentIndex,
        'startedAt': startedAt.toIso8601String(),
      };

  factory Siege.fromJson(Map<String, dynamic> json) {
    LatLng ll(dynamic v) => LatLng((v[0] as num).toDouble(), (v[1] as num).toDouble());
    return Siege(
      kind: MonsterKind.all.firstWhere((k) => k.name == json['kind'],
          orElse: () => MonsterKind.all.first),
      start: ll(json['start']),
      target: ll(json['target']),
      segmentIndex: json['segmentIndex'] as int,
      startedAt: DateTime.parse(json['startedAt'] as String),
    );
  }
}

class SiegeOutcome {
  const SiegeOutcome({
    required this.held,
    required this.attack,
    required this.defense,
    required this.garrisonLost,
    required this.foodLost,
    required this.wallDamage,
  });

  final bool held;
  final double attack;
  final double defense;
  final int garrisonLost;
  final double foodLost;
  final double wallDamage;
}

/// The wall segment's strength plus the garrison defends against the monster.
/// Holding still costs some wall strength; a breach knocks the segment to zero,
/// loses half the garrison and lets the monster raid the food stores.
SiegeOutcome resolveSiege({
  required double attack,
  required double segmentStrength,
  required int garrison,
  required double food,
  required CombatRules rules,
}) {
  final defense = segmentStrength + garrison * rules.garrisonPower;
  if (defense >= attack) {
    final lost = math.min(garrison, (attack / (rules.garrisonPower * 6)).floor());
    return SiegeOutcome(
      held: true,
      attack: attack,
      defense: defense,
      garrisonLost: lost,
      foodLost: 0,
      wallDamage: math.min(segmentStrength, attack * 0.3),
    );
  }
  return SiegeOutcome(
    held: false,
    attack: attack,
    defense: defense,
    garrisonLost: (garrison / 2).ceil(),
    foodLost: food * 0.3,
    wallDamage: segmentStrength,
  );
}

class HuntOutcome {
  const HuntOutcome({
    required this.won,
    required this.squadRoll,
    required this.monsterRoll,
    required this.escortsLost,
    required this.partsGained,
  });

  final bool won;
  final double squadRoll;
  final double monsterRoll;
  final int escortsLost;
  final int partsGained;
}

/// A quick auto-battle: the hero plus escorts against one monster, with some
/// luck on both sides.
HuntOutcome resolveHunt({
  required MonsterKind monster,
  required int escort,
  required math.Random rng,
  required CombatRules rules,
}) {
  final squad = rules.heroPower + escort * rules.escortPower;
  final squadRoll = squad * (0.7 + rng.nextDouble() * 0.6);
  final monsterRoll = monster.power * (0.8 + rng.nextDouble() * 0.4);
  if (squadRoll >= monsterRoll) {
    // Close fights cost more soldiers.
    final closeness = (monsterRoll / squadRoll).clamp(0.0, 1.0);
    final lost = (escort * closeness * 0.3 * rng.nextDouble()).round();
    return HuntOutcome(
      won: true,
      squadRoll: squadRoll,
      monsterRoll: monsterRoll,
      escortsLost: lost,
      partsGained: 1 + (monster.power / 30).floor(),
    );
  }
  return HuntOutcome(
    won: false,
    squadRoll: squadRoll,
    monsterRoll: monsterRoll,
    escortsLost: (escort / 2).ceil(),
    partsGained: 0,
  );
}
