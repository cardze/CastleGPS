import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'geo.dart';

/// Tunable numbers for walls. Kept in one place so playtests can adjust them.
class WallRules {
  const WallRules({
    this.maxStrength = 100,
    this.initialStrength = 40,
    this.decayPerHour = 1.0,
    this.reinforcePerMeter = 0.5,
    this.reinforceRadius = 15,
    this.segmentLength = 25,
    this.minLoopLength = 150,
    this.closeLoopRadius = 40,
  });

  final double maxStrength;

  /// Strength of a freshly drawn segment.
  final double initialStrength;

  /// Strength lost per hour when nobody walks a segment.
  /// The concept calls for this to scale with local player density later.
  final double decayPerHour;

  /// Strength gained per meter walked along a segment.
  final double reinforcePerMeter;

  /// How close (meters) you must be to a segment to reinforce it.
  final double reinforceRadius;

  /// Approximate length (meters) of one wall segment.
  final double segmentLength;

  /// Shortest walk (meters) that can close into a wall.
  final double minLoopLength;

  /// How close (meters) to the starting point you must return to close a loop.
  final double closeLoopRadius;
}

/// One stretch of wall. Strength decays lazily: it is stored with the time it
/// was last set and computed for any later time.
class WallSegment {
  WallSegment({
    required this.start,
    required this.end,
    required double strength,
    required DateTime updatedAt,
  })  : _strength = strength,
        _updatedAt = updatedAt;

  final LatLng start;
  final LatLng end;
  double _strength;
  DateTime _updatedAt;

  double strengthAt(DateTime now, WallRules rules) {
    final hours = now.difference(_updatedAt).inSeconds / 3600.0;
    return math.max(0, _strength - rules.decayPerHour * math.max(0, hours));
  }

  void reinforce(double amount, DateTime now, WallRules rules) {
    _strength = math.min(rules.maxStrength, strengthAt(now, rules) + amount);
    _updatedAt = now;
  }

  double distanceTo(LatLng p) => distanceToSegment(p, start, end);

  Map<String, dynamic> toJson() => {
        'start': [start.latitude, start.longitude],
        'end': [end.latitude, end.longitude],
        'strength': _strength,
        'updatedAt': _updatedAt.toIso8601String(),
      };

  factory WallSegment.fromJson(Map<String, dynamic> json) => WallSegment(
        start: _latLng(json['start']),
        end: _latLng(json['end']),
        strength: (json['strength'] as num).toDouble(),
        updatedAt: DateTime.parse(json['updatedAt'] as String),
      );
}

class Castle {
  Castle({required this.position, List<WallSegment>? wall})
      : wall = wall ?? [];

  final LatLng position;
  List<WallSegment> wall;

  bool get hasWall => wall.isNotEmpty;

  /// A castle whose whole wall has decayed to nothing is a ruin.
  bool isRuin(DateTime now, WallRules rules) =>
      hasWall && wall.every((s) => s.strengthAt(now, rules) <= 0);

  double averageStrength(DateTime now, WallRules rules) {
    if (!hasWall) return 0;
    final total = wall.fold<double>(0, (sum, s) => sum + s.strengthAt(now, rules));
    return total / wall.length;
  }

  /// Strengthens every segment within reach of [p] after walking [meters].
  /// Returns how many segments were reinforced.
  int reinforceNear(LatLng p, double meters, DateTime now, WallRules rules) {
    var count = 0;
    for (final s in wall) {
      if (s.distanceTo(p) <= rules.reinforceRadius) {
        s.reinforce(meters * rules.reinforcePerMeter, now, rules);
        count++;
      }
    }
    return count;
  }

  Map<String, dynamic> toJson() => {
        'position': [position.latitude, position.longitude],
        'wall': wall.map((s) => s.toJson()).toList(),
      };

  factory Castle.fromJson(Map<String, dynamic> json) => Castle(
        position: _latLng(json['position']),
        wall: (json['wall'] as List)
            .map((s) => WallSegment.fromJson(s as Map<String, dynamic>))
            .toList(),
      );
}

enum WallBuildError { tooShort, notClosed, doesNotEnclose }

/// Turns a walked loop into wall segments around [castle].
/// Returns the segments, or the reason the loop can't become a wall.
({List<WallSegment>? segments, WallBuildError? error}) buildWall(
  List<LatLng> walked,
  LatLng castle,
  DateTime now,
  WallRules rules,
) {
  if (walked.length < 3 || pathLength(walked) < rules.minLoopLength) {
    return (segments: null, error: WallBuildError.tooShort);
  }
  if (metersBetween(walked.first, walked.last) > rules.closeLoopRadius) {
    return (segments: null, error: WallBuildError.notClosed);
  }
  if (!containsPoint(walked, castle)) {
    return (segments: null, error: WallBuildError.doesNotEnclose);
  }
  final points = resample(walked, rules.segmentLength);
  // Close the ring: the last point joins back to the first.
  if (metersBetween(points.last, points.first) > 0.5) points.add(points.first);
  final segments = <WallSegment>[
    for (var i = 1; i < points.length; i++)
      WallSegment(
        start: points[i - 1],
        end: points[i],
        strength: rules.initialStrength,
        updatedAt: now,
      ),
  ];
  return (segments: segments, error: null);
}

LatLng _latLng(dynamic json) {
  final list = json as List;
  return LatLng((list[0] as num).toDouble(), (list[1] as num).toDouble());
}
