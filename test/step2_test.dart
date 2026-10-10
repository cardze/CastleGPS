import 'dart:math' as math;

import 'package:castlegps/game/bonus.dart';
import 'package:castlegps/game/castle.dart';
import 'package:castlegps/game/combat.dart';
import 'package:castlegps/game/economy.dart';
import 'package:castlegps/game/game_state.dart';
import 'package:castlegps/game/geo.dart';
import 'package:castlegps/services/poi_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

const center = LatLng(35.6812, 139.7671);

LatLng offset(LatLng p, double east, double north) => LatLng(
      p.latitude + north / 111320,
      p.longitude + east / (111320 * 0.8131),
    );

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

/// A game with a 100 m x 100 m (1 ha) walled castle at [center].
GameState walledGame(DateTime Function() clock, {int seed = 1}) {
  final game = GameState(clock: clock, random: math.Random(seed));
  game.onPosition(center);
  game.placeCastle();
  final loop = squareLoop(center, 50);
  game.onPosition(loop.first);
  game.startWall(game.castles.first);
  for (final p in loop.skip(1)) {
    game.onPosition(p);
  }
  expect(game.castles.first.hasWall, isTrue);
  return game;
}

void main() {
  final t0 = DateTime(2026, 10, 9, 12);

  group('geo', () {
    test('polygonArea of a 100 m square is about 1 ha', () {
      expect(polygonArea(squareLoop(center, 50)), closeTo(10000, 150));
    });

    test('offsetBy and bearingBetween agree', () {
      final p = offsetBy(center, 200, math.pi / 2); // east
      expect(metersBetween(center, p), closeTo(200, 1));
      expect(bearingBetween(center, p), closeTo(math.pi / 2, 0.01));
    });
  });

  group('economy', () {
    const rules = EconomyRules();

    test('farmland makes food, barracks turn food into soldiers', () {
      final e = Economy(food: 0, updatedAt: t0);
      e.advance(t0.add(const Duration(hours: 1)),
          foodPerHour: 20, soldiersPerHour: 0, rules: rules);
      expect(e.food, closeTo(20, 0.01));
      expect(e.garrison, 0);

      final b = Economy(food: 100, updatedAt: t0);
      b.advance(t0.add(const Duration(hours: 1)),
          foodPerHour: 0, soldiersPerHour: 2, rules: rules);
      expect(b.garrison, 2);
      expect(b.food, lessThan(100 - 2 * rules.foodPerSoldier + 0.01));
    });

    test('no food means no new soldiers', () {
      final e = Economy(food: 0, updatedAt: t0);
      e.advance(t0.add(const Duration(hours: 5)),
          foodPerHour: 0, soldiersPerHour: 2, rules: rules);
      expect(e.garrison, 0);
      expect(e.training, 1);
    });

    test('weak walls slow production', () {
      final strong = Economy(food: 0, updatedAt: t0);
      final weak = Economy(food: 0, updatedAt: t0);
      final later = t0.add(const Duration(hours: 1));
      strong.advance(later, foodPerHour: 20 * rules.efficiency(1), soldiersPerHour: 0, rules: rules);
      weak.advance(later, foodPerHour: 20 * rules.efficiency(0), soldiersPerHour: 0, rules: rules);
      expect(weak.food, closeTo(strong.food * 0.25, 0.01));
    });

    test('reassign moves soldiers both ways within limits', () {
      final e = Economy(garrison: 3, updatedAt: t0);
      e.reassign(5);
      expect((e.garrison, e.escort), (0, 3));
      e.reassign(-1);
      expect((e.garrison, e.escort), (1, 2));
    });
  });

  group('combat', () {
    const rules = CombatRules();

    test('garrison helps a weak wall hold', () {
      final alone = resolveSiege(
          attack: 60, segmentStrength: 30, garrison: 0, food: 50, rules: rules);
      expect(alone.held, isFalse);
      expect(alone.foodLost, closeTo(15, 0.01));
      expect(alone.wallDamage, 30);

      final defended = resolveSiege(
          attack: 60, segmentStrength: 30, garrison: 6, food: 50, rules: rules);
      expect(defended.held, isTrue);
      expect(defended.foodLost, 0);
      expect(defended.garrisonLost, lessThanOrEqualTo(6));
    });

    test('escorts make hunts winnable', () {
      var soloWins = 0, squadWins = 0;
      const ogre = MonsterKind('Ogre', 60, 1);
      for (var i = 0; i < 200; i++) {
        final rng = math.Random(i);
        if (resolveHunt(monster: ogre, escort: 0, rng: rng, rules: rules).won) soloWins++;
        if (resolveHunt(monster: ogre, escort: 10, rng: rng, rules: rules).won) squadWins++;
      }
      expect(soloWins, 0);
      expect(squadWins, greaterThan(140)); // about 80% with 10 escorts
    });
  });

  group('GameState', () {
    test('a farming and a military region together make food and soldiers', () {
      var now = t0;
      final game = walledGame(() => now);
      expect(game.pendingEvent, isA<RegionBuiltEvent>());
      game.setRegionType(game.castles.first, RegionType.farming);

      // A second region 300 m east, set to military.
      final east = offset(center, 300, 0);
      game.simulateWalkTo(east);
      expect(game.placeCastle(), isTrue);
      final loop = squareLoop(east, 50);
      game.simulateWalkTo(loop.first);
      game.startWall(game.castles.last);
      for (final p in loop.skip(1)) {
        game.onPosition(p);
      }
      expect(game.castles.length, 2);
      game.setRegionType(game.castles.last, RegionType.military);

      now = t0.add(const Duration(hours: 4));
      game.tick();
      expect(game.economy.garrison, greaterThan(0));
      expect(game.rates.food, greaterThan(0));
      expect(game.rates.soldiers, greaterThan(0));
    });

    test('placing a castle and just walking a loop builds the wall', () {
      final game = GameState(clock: () => t0, random: math.Random(1));
      game.onPosition(center);
      expect(game.placeCastle(), isTrue);
      expect(game.walkedPath, isEmpty); // waits until you leave the castle
      final loop = squareLoop(center, 50);
      game.simulateWalkTo(loop.first);
      for (final p in loop.skip(1)) {
        game.onPosition(p);
      }
      expect(game.castles.single.hasWall, isTrue);
      expect(game.pendingEvent, isA<RegionBuiltEvent>());
    });

    test('farming alone makes no soldiers', () {
      var now = t0;
      final game = walledGame(() => now);
      now = t0.add(const Duration(hours: 4));
      game.tick();
      expect(game.economy.garrison, 0);
      expect(game.economy.food, greaterThan(20));
    });

    test('new castles must be outside other regions and spaced apart', () {
      final game = walledGame(() => t0);
      game.simulateWalkTo(center);
      expect(game.placeCastle(), isFalse);
      expect(game.placeBlockedReason, contains('inside'));
      game.simulateWalkTo(offset(center, 90, 0));
      expect(game.placeCastle(), isTrue);
      expect(game.drawingWall, isTrue);
      game.cancelWall();
      expect(game.castles.length, 1); // a castle without a wall is dropped
    });

    test('walking into a restaurant circle gives food and a boost once per cooldown', () {
      var now = t0;
      final game = walledGame(() => now);
      final spot = offset(center, 200, 200);
      game.setBonusPoints([BonusPoint(id: 'node/1', name: 'Ramen Ya', position: spot)]);
      final foodBefore = game.economy.food;

      game.simulateWalkTo(spot);
      expect(game.pendingEvent, isA<BonusEvent>());
      expect(game.economy.food, closeTo(foodBefore + 15, 1));
      expect(game.boosted, isTrue);
      expect(game.rates.food, closeTo(game.regionOutput(game.castles.first).food * 1.5, 0.01));

      // Walking out and back in right away gives nothing more.
      game.pendingEvent = null;
      game.simulateWalkTo(offset(spot, 60, 0));
      game.simulateWalkTo(spot);
      expect(game.pendingEvent, isNull);

      now = t0.add(const Duration(hours: 3));
      expect(game.boosted, isFalse);
      expect(game.bonusReady(game.bonusPoints.first), isTrue);
    });

    test('Overpass responses become bonus points', () {
      const body = '{"elements":['
          '{"type":"node","id":1,"lat":35.68,"lon":139.76,"tags":{"name":"Ramen Ya","amenity":"restaurant"}},'
          '{"type":"way","id":2,"center":{"lat":35.69,"lon":139.77},"tags":{"amenity":"cafe"}},'
          '{"type":"node","id":3}]}';
      final points = PoiService.parseOverpass(body);
      expect(points.length, 2);
      expect(points.first.name, 'Ramen Ya');
      expect(points.last.id, 'way/2');
      expect(points.last.name, 'Restaurant');
    });

    test('a siege marches to the weakest wall and resolves', () {
      var now = t0;
      final game = walledGame(() => now);
      game.siegeNow();
      final siege = game.siege!;
      final weakest = game.castles.first.weakestSegment(now, game.rules);
      expect(siege.segmentIndex, weakest);
      expect(metersBetween(siege.start, siege.target), closeTo(250, 2));

      now = now.add(const Duration(minutes: 5)); // 250 m at 2 m/s is ~2 min
      game.tick();
      expect(game.siege, isNull);
      expect(game.pendingEvent, isA<SiegeEvent>());
      expect(game.nextSiegeAt, isNotNull);
    });

    test('the first siege comes on its own after the wall is built', () {
      var now = t0;
      final game = walledGame(() => now);
      now = now.add(const Duration(minutes: 16));
      game.tick();
      expect(game.siege, isNotNull);
    });

    test('hunting needs you to be close, and wins give parts', () {
      var now = t0;
      final game = walledGame(() => now);
      expect(game.monsters.length, GameState.wildMonsterCount);
      final monster = game.monsters.first;
      expect(game.hunt(monster), isNull);

      game.economy.escort = 20;
      game.simulateWalkTo(monster.position);
      final outcome = game.hunt(monster)!;
      expect(outcome.won, isTrue);
      expect(game.economy.parts, greaterThan(0));
      expect(game.monsters.contains(monster), isFalse);
    });

    test('fortify spends parts to strengthen walls', () {
      var now = t0;
      final game = walledGame(() => now);
      expect(game.canFortify(game.castles.first), isFalse);
      game.economy.parts = 3;
      final before = game.castles.first.averageStrength(now, game.rules);
      game.fortify(game.castles.first);
      expect(game.economy.parts, 0);
      expect(game.castles.first.averageStrength(now, game.rules), closeTo(before + 30, 0.01));
    });

    test('state survives save and load', () async {
      var now = t0;
      final storage = MemoryStorage();
      final game = GameState(clock: () => now, storage: storage, random: math.Random(1));
      game.onPosition(center);
      game.placeCastle();
      game.castles.first.wall = buildWall(squareLoop(center, 50), center, now, game.rules).segments!;
      game.economy
        ..food = 42
        ..garrison = 3
        ..parts = 2;
      game.siegeNow();
      await Future<void>.delayed(Duration.zero);

      final loaded = GameState(clock: () => now, storage: storage);
      await loaded.load();
      expect(loaded.economy.food, closeTo(42, 0.1));
      expect(loaded.economy.garrison, 3);
      expect(loaded.siege, isNotNull);
    });
  });
}

class MemoryStorage implements GameStorage {
  String? data;

  @override
  Future<String?> load() async => data;

  @override
  Future<void> save(String json) async => data = json;
}
