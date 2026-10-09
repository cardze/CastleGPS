import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import 'castle.dart';
import 'geo.dart';

/// Saves and loads the game. The app uses SharedPreferences; tests use memory.
abstract class GameStorage {
  Future<String?> load();
  Future<void> save(String json);
}

/// Holds the player's castle and turns GPS updates into wall drawing and
/// reinforcement.
class GameState extends ChangeNotifier {
  GameState({this.rules = const WallRules(), this.storage, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final WallRules rules;
  final GameStorage? storage;
  final DateTime Function() _clock;

  /// GPS steps longer than this are treated as jumps and earn nothing.
  static const double maxStepMeters = 60;

  /// Steps shorter than this are GPS jitter while standing still.
  static const double minStepMeters = 2;

  Castle? castle;
  LatLng? position;
  bool drawingWall = false;
  final List<LatLng> walkedPath = [];
  String? message;

  DateTime get now => _clock();

  Future<void> load() async {
    final raw = await storage?.load();
    if (raw == null) return;
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final castleJson = json['castle'];
    castle = castleJson == null ? null : Castle.fromJson(castleJson as Map<String, dynamic>);
    notifyListeners();
  }

  Future<void> _save() async {
    await storage?.save(jsonEncode({'castle': castle?.toJson()}));
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
    cancelWall();
    _save();
  }

  /// Call periodically so decaying strength shows on screen.
  void tick() => notifyListeners();
}
