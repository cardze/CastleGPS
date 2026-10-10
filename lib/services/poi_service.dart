import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../game/bonus.dart';

/// Finds real restaurants and cafes near the player from OpenStreetMap, via
/// the public Overpass API. Fine for a prototype; a public release should run
/// its own copy of the data.
class PoiService {
  PoiService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  static const _endpoint = 'https://overpass-api.de/api/interpreter';

  Future<List<BonusPoint>> restaurantsNear(LatLng center, {double radiusMeters = 600}) async {
    final query = '[out:json][timeout:15];'
        'nwr["amenity"~"^(restaurant|cafe|fast_food)\$"]'
        '(around:${radiusMeters.round()},${center.latitude},${center.longitude});'
        'out center 60;';
    final response = await _client.post(
      Uri.parse(_endpoint),
      body: {'data': query},
      headers: {'User-Agent': 'CastleGPS prototype (com.castlegps.castlegps)'},
    );
    if (response.statusCode != 200) {
      throw Exception('Overpass returned ${response.statusCode}');
    }
    return parseOverpass(response.body);
  }

  /// Turns an Overpass JSON response into bonus points.
  static List<BonusPoint> parseOverpass(String body) {
    final json = jsonDecode(body) as Map<String, dynamic>;
    final out = <BonusPoint>[];
    for (final e in (json['elements'] as List? ?? const [])) {
      final m = e as Map<String, dynamic>;
      final center = m['center'] as Map<String, dynamic>?;
      final lat = (m['lat'] ?? center?['lat']) as num?;
      final lon = (m['lon'] ?? center?['lon']) as num?;
      if (lat == null || lon == null) continue;
      final tags = (m['tags'] as Map<String, dynamic>?) ?? const {};
      out.add(BonusPoint(
        id: '${m['type']}/${m['id']}',
        name: (tags['name'] as String?) ?? 'Restaurant',
        position: LatLng(lat.toDouble(), lon.toDouble()),
      ));
    }
    return out;
  }
}
