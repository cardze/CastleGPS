import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

const double _earthRadius = 6371000.0;

/// Great-circle distance in meters (haversine).
double metersBetween(LatLng a, LatLng b) {
  final lat1 = a.latitude * math.pi / 180;
  final lat2 = b.latitude * math.pi / 180;
  final dLat = lat2 - lat1;
  final dLon = (b.longitude - a.longitude) * math.pi / 180;
  final h = math.pow(math.sin(dLat / 2), 2) +
      math.cos(lat1) * math.cos(lat2) * math.pow(math.sin(dLon / 2), 2);
  return 2 * _earthRadius * math.asin(math.min(1.0, math.sqrt(h)));
}

/// Total length of a polyline in meters.
double pathLength(List<LatLng> path) {
  var total = 0.0;
  for (var i = 1; i < path.length; i++) {
    total += metersBetween(path[i - 1], path[i]);
  }
  return total;
}

/// Local flat projection (meters east/north of [origin]). Accurate enough at
/// the scale of a castle wall (a few hundred meters).
({double x, double y}) _project(LatLng p, LatLng origin) {
  final cosLat = math.cos(origin.latitude * math.pi / 180);
  return (
    x: (p.longitude - origin.longitude) * math.pi / 180 * _earthRadius * cosLat,
    y: (p.latitude - origin.latitude) * math.pi / 180 * _earthRadius,
  );
}

/// Shortest distance in meters from [p] to the segment [a]-[b].
double distanceToSegment(LatLng p, LatLng a, LatLng b) {
  final pp = _project(p, a);
  final bb = _project(b, a);
  final lenSq = bb.x * bb.x + bb.y * bb.y;
  if (lenSq == 0) return math.sqrt(pp.x * pp.x + pp.y * pp.y);
  final t = ((pp.x * bb.x + pp.y * bb.y) / lenSq).clamp(0.0, 1.0);
  final dx = pp.x - t * bb.x;
  final dy = pp.y - t * bb.y;
  return math.sqrt(dx * dx + dy * dy);
}

/// Point along the segment [a]-[b] at fraction [t] (0..1).
LatLng lerp(LatLng a, LatLng b, double t) => LatLng(
      a.latitude + (b.latitude - a.latitude) * t,
      a.longitude + (b.longitude - a.longitude) * t,
    );

/// Re-samples [path] into points spaced roughly [spacing] meters apart.
/// The first and last points of [path] are kept.
List<LatLng> resample(List<LatLng> path, double spacing) {
  if (path.length < 2) return List.of(path);
  final out = <LatLng>[path.first];
  var carried = 0.0; // distance since the last emitted point
  for (var i = 1; i < path.length; i++) {
    final a = path[i - 1];
    final b = path[i];
    final len = metersBetween(a, b);
    if (len == 0) continue;
    var pos = spacing - carried; // distance along a-b of the next point
    while (pos <= len) {
      out.add(lerp(a, b, pos / len));
      pos += spacing;
    }
    carried = len - (pos - spacing);
  }
  if (metersBetween(out.last, path.last) > spacing * 0.3) {
    out.add(path.last);
  }
  return out;
}

/// Whether [p] lies inside the closed polygon [ring] (ray casting).
bool containsPoint(List<LatLng> ring, LatLng p) {
  if (ring.length < 3) return false;
  final pts = ring.map((q) => _project(q, p)).toList();
  var inside = false;
  for (var i = 0, j = pts.length - 1; i < pts.length; j = i++) {
    final a = pts[i];
    final b = pts[j];
    if ((a.y > 0) != (b.y > 0) && 0 < (b.x - a.x) * (0 - a.y) / (b.y - a.y) + a.x) {
      inside = !inside;
    }
  }
  return inside;
}

/// Area in square meters enclosed by [ring] (shoelace formula on a local
/// projection).
double polygonArea(List<LatLng> ring) {
  if (ring.length < 3) return 0;
  final origin = ring.first;
  final pts = ring.map((q) => _project(q, origin)).toList();
  var sum = 0.0;
  for (var i = 0, j = pts.length - 1; i < pts.length; j = i++) {
    sum += (pts[j].x * pts[i].y) - (pts[i].x * pts[j].y);
  }
  return sum.abs() / 2;
}

/// The point [meters] away from [from] in direction [bearingRadians]
/// (0 = north, clockwise).
LatLng offsetBy(LatLng from, double meters, double bearingRadians) {
  final north = meters * math.cos(bearingRadians);
  final east = meters * math.sin(bearingRadians);
  final cosLat = math.cos(from.latitude * math.pi / 180);
  return LatLng(
    from.latitude + north / _earthRadius * 180 / math.pi,
    from.longitude + east / (_earthRadius * cosLat) * 180 / math.pi,
  );
}

/// Compass bearing in radians from [a] to [b] (0 = north, clockwise).
double bearingBetween(LatLng a, LatLng b) {
  final p = _project(b, a);
  return math.atan2(p.x, p.y);
}
