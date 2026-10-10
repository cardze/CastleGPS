# CastleGPS

A location-based game where you build a castle on the real map and keep its walls standing by walking them. See [docs/concept.md](docs/concept.md) for the full concept.

## Prototype step 1: walls you walk

- Shows an OpenStreetMap map with your live GPS position.
- **Place castle here** puts your castle where you stand.
- **Draw wall** records your walk. Walk a loop of at least 150 m around the castle and return to where you started; the loop becomes the wall, split into ~25 m segments.
- Walking within 15 m of a segment strengthens it (colored red → yellow → green). Walls lose strength every hour nobody walks them; when every segment reaches zero, the castle becomes a ruin and you can place a new one.
- Tracking keeps running with the screen off (Android foreground service with a notification).
- **Simulate** (debug): long-press the map to walk there in a straight line, for testing without walking. Press at each corner of your loop.

## Prototype step 2: regions, soldiers, sieges, hunting, restaurants

- **New region here** places a castle. Walk 25 m away, then walk a loop around it. When the wall closes you choose the region's type: **Farming** makes food, and **Military** trains soldiers (10 food each, plus food upkeep). You can build several regions, each at least 80 m apart, and change a region's type from its button. Bigger loops make more, and weak walls slow production down.
- **Garrison** soldiers defend your walls. **Escort** soldiers walk with you and fight in hunts. Move soldiers between them in the region panel.
- **Sieges:** 15 minutes after your first wall is built, and every 6 hours after that, a monster marches on the weakest wall segment across all your regions. Wall strength plus 5 per garrison soldier must beat its attack. If it breaks through, that segment drops to zero, half the garrison falls and some food is stolen.
- **Hunting:** monsters roam within a few hundred meters. Walk within 40 m and tap one to fight. Your strength is 22 plus 6 per escort, with some luck. Wins give monster parts; 3 parts fortify a region's walls by +30.
- **Restaurants:** real restaurants and cafes from OpenStreetMap (via the Overpass API) show as orange circles. Walk into one for +15 food and 1.5x production for an hour. Each place can be collected again after 2 hours.
- In Simulate mode, **+1 h** skips time forward and **Siege now** starts a siege right away.

Tuning numbers live in `WallRules` (`lib/game/castle.dart`), `EconomyRules` (`lib/game/economy.dart`) and `CombatRules` (`lib/game/combat.dart`) and `BonusRules` (`lib/game/bonus.dart`).

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
