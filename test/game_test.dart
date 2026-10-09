import 'package:castlegps/game/castle.dart';
import 'package:castlegps/game/game_state.dart';
import 'package:castlegps/game/geo.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

const center = LatLng(35.6812, 139.7671);

/// Offset [p] by meters east/north.
LatLng offset(LatLng p, double east, double north) => LatLng(
      p.latitude + north / 111320,
      p.longitude + east / (111320 * 0.8131), // cos(35.68°)
    );

/// A square loop around [c] with the given half side, walked in [step] m steps.
List<LatLng> squareLoop(LatLng c, double half, {double step = 5}) {
  final corners = [
    offset(c, -half, -half),
    offset(c, half, -half),
    offset(c, half, half),
    offset(c, -half, half),
    offset(c, -half, -half),
  ];
  final out = <LatLng>[corners.first];
  for (var i = 1; i < corners.length; i++) {
    final n = (half * 2 / step).round();
    for (var k = 1; k <= n; k++) {
      out.add(lerp(corners[i - 1], corners[i], k / n));
    }
  }
  return out;
}

void main() {
  const rules = WallRules();
  final t0 = DateTime(2026, 10, 9, 12);

  group('geo', () {
    test('metersBetween is about right', () {
      expect(metersBetween(center, offset(center, 100, 0)), closeTo(100, 1));
      expect(metersBetween(center, offset(center, 0, 100)), closeTo(100, 1));
    });

    test('distanceToSegment', () {
      final a = offset(center, -50, 0);
      final b = offset(center, 50, 0);
      expect(distanceToSegment(offset(center, 0, 10), a, b), closeTo(10, 0.5));
      expect(distanceToSegment(offset(center, 80, 0), a, b), closeTo(30, 0.5));
    });

    test('resample spaces points evenly', () {
      final pts = resample([center, offset(center, 100, 0)], 25);
      expect(pts.length, 5);
      expect(metersBetween(pts[0], pts[1]), closeTo(25, 0.5));
    });

    test('containsPoint', () {
      final loop = squareLoop(center, 50);
      expect(containsPoint(loop, center), isTrue);
      expect(containsPoint(loop, offset(center, 200, 0)), isFalse);
    });
  });

  group('buildWall', () {
    test('a closed loop around the castle becomes segments', () {
      final r = buildWall(squareLoop(center, 50), center, t0, rules);
      expect(r.error, isNull);
      // 400 m loop / 25 m segments.
      expect(r.segments!.length, closeTo(16, 1));
      expect(r.segments!.first.strengthAt(t0, rules), rules.initialStrength);
    });

    test('rejects short, open, or non-enclosing loops', () {
      expect(buildWall(squareLoop(center, 10), center, t0, rules).error, WallBuildError.tooShort);
      final open = squareLoop(center, 50)..removeRange(60, 81);
      expect(buildWall(open, center, t0, rules).error, WallBuildError.notClosed);
      expect(buildWall(squareLoop(offset(center, 300, 0), 50), center, t0, rules).error,
          WallBuildError.doesNotEnclose);
    });
  });

  group('walls', () {
    test('decay over time and become a ruin', () {
      final castle = Castle(
        id: 1,
        position: center,
        wall: buildWall(squareLoop(center, 50), center, t0, rules).segments,
      );
      expect(castle.averageStrength(t0.add(const Duration(hours: 10)), rules), closeTo(30, 0.01));
      expect(castle.isRuin(t0.add(const Duration(hours: 39)), rules), isFalse);
      expect(castle.isRuin(t0.add(const Duration(hours: 40)), rules), isTrue);
    });

    test('walking near a segment reinforces only nearby segments, capped', () {
      final castle = Castle(
        id: 1,
        position: center,
        wall: buildWall(squareLoop(center, 50), center, t0, rules).segments,
      );
      final p = offset(center, 0, -50); // middle of the south side
      final n = castle.reinforceNear(p, 10, t0, rules);
      expect(n, inInclusiveRange(1, 2));
      final strengths = castle.wall.map((s) => s.strengthAt(t0, rules)).toList();
      expect(strengths.where((s) => s == 45).length, n);
      castle.reinforceNear(p, 1000, t0, rules);
      expect(castle.wall.map((s) => s.strengthAt(t0, rules)).reduce((a, b) => a > b ? a : b),
          rules.maxStrength);
    });

    test('json round trip', () {
      final castle = Castle(
        id: 1,
        position: center,
        wall: buildWall(squareLoop(center, 50), center, t0, rules).segments,
      );
      final copy = Castle.fromJson(castle.toJson());
      expect(copy.wall.length, castle.wall.length);
      expect(copy.averageStrength(t0, rules), castle.averageStrength(t0, rules));
    });
  });

  group('GameState', () {
    test('place castle, walk a loop, wall forms, walking it reinforces', () {
      var now = t0;
      final game = GameState(clock: () => now);
      game.onPosition(center);
      expect(game.placeCastle(), isTrue);

      final loop = squareLoop(center, 50);
      game.onPosition(loop.first);
      game.startWall(game.castles.first);
      for (final p in loop.skip(1)) {
        game.onPosition(p);
      }
      expect(game.drawingWall, isFalse);
      expect(game.castles.first.hasWall, isTrue);

      now = t0.add(const Duration(hours: 5));
      final before = game.castles.first.averageStrength(now, game.rules);
      for (final p in loop.skip(1)) {
        game.onPosition(p);
      }
      expect(game.castles.first.averageStrength(now, game.rules), greaterThan(before));
    });

    test('GPS jumps earn nothing', () {
      final game = GameState(clock: () => t0);
      game.onPosition(center);
      game.placeCastle();
      game.castles.first.wall = buildWall(squareLoop(center, 50), center, t0, game.rules).segments!;
      game.position = offset(center, 0, -50);
      game.onPosition(offset(center, 0, -50 + 0.5)); // jitter
      game.onPosition(offset(center, 500, -50)); // jump
      expect(game.castles.first.averageStrength(t0, game.rules), game.rules.initialStrength);
    });

    test('simulated long-press walks far targets in small steps', () {
      final game = GameState(clock: () => t0);
      game.onPosition(center);
      game.placeCastle();
      game.onPosition(offset(center, -50, -50));
      game.startWall(game.castles.first);
      // Four corner taps, each about 100 m apart, then back to the start.
      game.simulateWalkTo(offset(center, 50, -50));
      game.simulateWalkTo(offset(center, 50, 50));
      game.simulateWalkTo(offset(center, -50, 50));
      expect(game.walkedPath.length, greaterThan(50));
      game.simulateWalkTo(offset(center, -50, -50));
      expect(game.castles.first.hasWall, isTrue);
    });
  });
}
