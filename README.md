# CastleGPS

A location-based game where you build a castle on the real map and keep its walls standing by walking them. See [docs/concept.md](docs/concept.md) for the full concept.

## Prototype step 1: walls you walk

- Shows an OpenStreetMap map with your live GPS position.
- **Place castle here** puts your castle where you stand.
- **Draw wall** records your walk. Walk a loop of at least 150 m around the castle and return to where you started; the loop becomes the wall, split into ~25 m segments.
- Walking within 15 m of a segment strengthens it (colored red → yellow → green). Walls lose strength every hour nobody walks them; when every segment reaches zero, the castle becomes a ruin and you can place a new one.
- Tracking keeps running with the screen off (Android foreground service with a notification).
- **Simulate** (debug): long-press the map to walk there in a straight line, for testing without walking. Press at each corner of your loop.

Tuning numbers live in `WallRules` in `lib/game/castle.dart`.

## Run it

Requires the [Flutter SDK](https://docs.flutter.dev/get-started/install) and an Android phone with USB debugging on.

```sh
flutter pub get
flutter test        # game logic tests
flutter run         # install on the connected phone
```

Map tiles come from OSM's public tile server, which is fine for personal testing only. A public release should host its own tiles (MapLibre + Protomaps, see the concept doc).

## License

[GNU Affero General Public License v3.0](LICENSE).
