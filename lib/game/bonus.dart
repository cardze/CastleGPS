import 'package:latlong2/latlong.dart';

/// A real-world place, such as a restaurant, that rewards visiting it.
class BonusPoint {
  const BonusPoint({required this.id, required this.name, required this.position});

  /// Stable id from the map data (for example `node/123`).
  final String id;
  final String name;
  final LatLng position;
}

class BonusRules {
  const BonusRules({
    this.radius = 30,
    this.foodGain = 15,
    this.boostMultiplier = 1.5,
    this.boostDuration = const Duration(hours: 1),
    this.cooldown = const Duration(hours: 2),
  });

  /// How close (meters) you must walk to collect a bonus point.
  final double radius;

  /// Food you get on the spot.
  final double foodGain;

  /// Production multiplier while the boost lasts.
  final double boostMultiplier;

  /// How long one visit boosts production.
  final Duration boostDuration;

  /// How long before the same place can be collected again.
  final Duration cooldown;
}
