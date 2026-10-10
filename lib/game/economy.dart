import 'dart:math' as math;

/// Tunable numbers for zones and soldiers.
class EconomyRules {
  const EconomyRules({
    this.foodPerHectareHour = 20,
    this.soldiersPerHectareHour = 2,
    this.foodPerSoldier = 10,
    this.upkeepPerSoldierHour = 0.5,
    this.maxOfflineHours = 72,
  });

  /// Food per hour from one hectare of farmland at full wall strength.
  final double foodPerHectareHour;

  /// Soldiers trained per hour by one hectare of barracks at full wall strength.
  final double soldiersPerHectareHour;

  /// Food it costs to train one soldier.
  final double foodPerSoldier;

  /// Food each soldier eats per hour.
  final double upkeepPerSoldierHour;

  /// Production stops accumulating after this long away.
  final double maxOfflineHours;

  /// Weak walls slow production; ruined walls still give a quarter.
  double efficiency(double wallFraction) => 0.25 + 0.75 * wallFraction.clamp(0.0, 1.0);
}

/// The castle's stores and army.
class Economy {
  Economy({
    this.food = 20,
    this.training = 0,
    this.garrison = 0,
    this.escort = 0,
    this.parts = 0,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  double food;

  /// Progress toward the next trained soldier (0..1).
  double training;

  /// Soldiers defending the walls at home.
  int garrison;

  /// Soldiers walking with the player and fighting in hunts.
  int escort;

  /// Monster parts from hunts, spent on upgrades.
  int parts;

  DateTime updatedAt;

  int get soldiers => garrison + escort;

  /// Runs production from [updatedAt] up to [now] in small slices, given the
  /// food and soldier output per hour of all regions together.
  void advance(
    DateTime now, {
    required double foodPerHour,
    required double soldiersPerHour,
    required EconomyRules rules,
  }) {
    var hours = now.difference(updatedAt).inSeconds / 3600.0;
    updatedAt = now;
    if (hours <= 0) return;
    hours = math.min(hours, rules.maxOfflineHours);
    const slice = 1 / 12; // five minutes
    var remaining = hours;
    while (remaining > 0) {
      final dt = math.min(slice, remaining);
      remaining -= dt;
      final upkeep = soldiers * rules.upkeepPerSoldierHour;
      food = math.max(0, food + (foodPerHour - upkeep) * dt);
      training += soldiersPerHour * dt;
      while (training >= 1 - 1e-9 && food >= rules.foodPerSoldier) {
        training = math.max(0, training - 1);
        food -= rules.foodPerSoldier;
        garrison++;
      }
      // Without food, barracks wait at "ready" instead of piling up recruits.
      training = math.min(training, 1);
    }
  }

  /// Moves [n] soldiers between garrison and escort. Positive moves to escort.
  void reassign(int n) {
    if (n > 0) {
      final moved = math.min(n, garrison);
      garrison -= moved;
      escort += moved;
    } else if (n < 0) {
      final moved = math.min(-n, escort);
      escort -= moved;
      garrison += moved;
    }
  }

  Map<String, dynamic> toJson() => {
        'food': food,
        'training': training,
        'garrison': garrison,
        'escort': escort,
        'parts': parts,
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory Economy.fromJson(Map<String, dynamic> json) => Economy(
        food: (json['food'] as num).toDouble(),
        training: (json['training'] as num).toDouble(),
        garrison: json['garrison'] as int,
        escort: json['escort'] as int,
        parts: json['parts'] as int,
        updatedAt: DateTime.parse(json['updatedAt'] as String),
      );
}
