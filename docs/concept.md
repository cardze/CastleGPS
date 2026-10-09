# CastleGPS: Concept Draft v0.1

*A location-based hunting game where the castles you build on the real map are the reason you go out.*

## What we borrow from Monster Hunter Now

Monster Hunter Now (Niantic + Capcom, 2023) works because of a few specific choices:

- **Short, skill-based fights.** A hunt lasts about 75 seconds of tapping and dodging, so you can play it while standing on a street corner.
- **Paintballing.** You can tag a monster you walk past and fight it later at home. That removes the "I must stop walking right now" friction.
- **Gear as progression.** Monsters drop parts, parts craft weapons and armor, and better gear lets you hunt harder monsters. The loop is simple and it's addictive.
- **Biomes on a real map.** Forest, desert, and swamp zones rotate across real neighborhoods, so different places give different loot.
- **Light co-op.** Players nearby can join a hunt together.

**The gap CastleGPS can fill:** in MH Now you leave nothing behind on the map. Castles give the world persistent things that players own.

## Core loop

1. **Explore:** walk the real map and find monsters, resource nodes, and other players' castles.
2. **Hunt:** fight in short sessions (MH Now style) to get monster materials, plus stone, timber, and ore from nodes.
3. **Build:** spend materials to place and upgrade your castle on a real-world location.
4. **Defend and raid:** monsters, and possibly other players, attack castles. A strong castle generates resources and lets you hunt harder monsters nearby.
5. **Return:** the castle gives you a reason to come back to a place every day, and hunting gives you a reason to leave it.

The tension between staying home to build and going out to hunt is the heart of the game.

## How castles on the map could work

- **Placement:** you claim a map cell (for example an S2/H3 hex about 100–200 m across) near where you physically are. Only one castle can exist per cell.
- **Territory:** the castle projects a zone. Monsters that spawn in it are tougher but drop more loot, and the zone can carry a bonus such as faster crafting.
- **Growth:** tiers run Outpost → Keep → Castle → Citadel. Higher tiers need rarer monster parts, so the hunt feeds the build.
- **Monster sieges:** a big monster periodically attacks your castle. You or your allies have to fight it, either physically nearby or remotely within a time window.
- **Visiting:** other players can see your castle on the map, trade with it, or join its defense. Players can't raid castles; they're PvE only.
- **Walls you walk (idea from 上澤):** the castle's wall is a real route around it. Each time you walk it, that stretch gets stronger, and walls slowly wear down if nobody walks them. Some possible extensions:
  - Walking a closed loop draws the wall and sets your territory, so a bigger loop means a bigger territory with more to maintain.
  - Each wall segment shows its strength, and siege monsters attack the weakest one.
  - Friends or guildmates can walk your walls to help, which makes co-op useful without any PvP.
  - It rewards daily walks and uses real streets, while hunting still rewards going farther out.
- **Guilds and kingdoms:** neighboring castles can ally into a shared territory, which gives a reason for local communities to form.

## Main open design questions

1. ~~**PvP or PvE castles?**~~ **Decided: PvE.** Only monsters attack castles. Other players can visit, trade with, and help defend castles. Friendly competition, such as leaderboards or castle rankings, is an option for later.
2. **Do you have to be there?** *Direction: walking the walls* (see "Walls you walk" above). Being there matters through walking: you strengthen your walls by physically walking them. Upgrades with materials might still be possible from anywhere (to decide).
3. **Density problems:** in cities every cell gets claimed, and in the countryside nothing is nearby. How do we handle both?
   - *Idea from 上澤: time as an extra map dimension.* One location holds several castles, each in a different time layer:
     - **Time of day:** dawn, day, dusk, and night realms. You see and work on the castle whose layer is active now, and night castles face tougher monsters for better loot.
     - **Alternative, eras:** the same street exists in an Ancient, Medieval, or Future layer, and players switch between them.
   - Time layers multiply how many castles a city can hold, and each layer gives the same place a different feel.
   - For the countryside, castles could cover every time layer automatically and claim bigger areas, so rural players aren't penalized.
   - *Idea from 上澤: decay.* Walls wear down over time, and walking them is the only repair (see "Walls you walk").
     - An abandoned castle crumbles into a **ruin**, and the cell becomes free again. Cities stay open to new players without anyone being kicked out.
     - Ruins don't just disappear. They become monster lairs or salvage spots for a while, so a dead castle still adds something to the map.
     - Decay can depend on density: fast in crowded cities where others are waiting for space, slow in the countryside where nobody is competing. That one rule handles both ends.
     - Protection for real life: a vacation shield or allies' walks keep a castle alive while its owner is away.
   - To decide (time layers): is the active layer forced by the real clock, or can players choose it? A forced clock is more immersive but locks out people who can only play at certain hours.
4. **Private property and safety:** castles on someone's house, a school, or a dangerous road. Pokémon GO had real trouble here, so we need exclusion zones and a reporting flow.
   - *Idea from 上澤: a "death zone".* Turn exclusion zones into part of the story, for example **Cursed Land** or a **Miasma** that covers schools, highways, railways, private homes, and hospitals.
     - You can't build there, nothing spawns, and you can't place walls through it.
     - Design rule: the zone must be **boring, not dangerous to the player**. If entering it "kills" you or hides a powerful monster, it becomes a dare that pulls players toward exactly the places we want them away from. It should also never punish someone who simply lives or commutes there.
     - So it works as a dead end: no rewards, no fights, and your character just stays out. If your castle's wall loop crosses the zone, it bends around it.
     - Players can report a spot, and a property owner can request that their address be covered.
5. **Real map data source:** Google Maps, Mapbox, or OpenStreetMap, and where monster and node spawn data comes from.
   - *Leaning: OpenStreetMap (free).* Draw it with MapLibre (a free, open-source map renderer) and host the map files ourselves with Protomaps (one file on cheap storage).
     - OSM data also drives gameplay: parks, water, and forest set biomes and spawns, and the tags for schools, hospitals, railways, and motorways generate the Cursed Land zones automatically.
     - Conditions: we must credit "© OpenStreetMap contributors". Its ODbL license is share-alike, which may cover map data we derive from it, so it needs a check before launch. We can't use OSM's own tile servers for an app's traffic.
     - Mapbox and Google both have free tiers, but they charge once the game grows, and their terms restrict how game data can be stored or derived. Pricing needs re-checking when we pick.
6. **Combat style:** real-time action (expensive to build, high skill) or something simpler such as timing or turn-based (cheaper, easier for an MVP)?
   - *Direction from 上澤: strategy, since we're building castles.* That shifts the game's identity from a monster-hunting action game to a hunting-and-castle strategy game.
     - **Sieges are tower defense on the real map.** Monsters march toward your castle along real streets from OSM. You place towers and troops on your wall segments, and the strength you built by walking those walls decides what holds.
     - **Hunts are short tactical battles.** You lead a small squad (hero plus units) in a quick auto-battle or a few turns, choosing formation and skills. It stays playable on a street corner, in a minute or two.
     - Monster parts unlock towers, units, and wall upgrades, so the hunt still feeds the build.
     - Strategy combat is cheaper to build than real-time action, which also suits an MVP.
7. **Monetization:** cosmetic castle skins, build-speed boosts, or remote-play passes, without making it pay-to-win.

## Questions for you before any code

- **Platform:** iOS, Android, or both? Unity, a web/PWA prototype, or something else?
  - *Decided: Android first* (上澤 has an Android phone). No iPhone needed yet, since iOS development also needs a Mac and a $99/yr Apple developer account. Testing your own APK on Android is free, and Google Play costs $25 once.
  - Use a cross-platform tool so iOS comes later without a rewrite. Candidates are Flutter + MapLibre (strong for map-heavy apps) and Unity (strong for game visuals).
  - Walking the walls needs reliable background GPS, which a web app can't do well, so the real game should be a native app.
- **Scope:** a playable prototype for yourself and friends, or a path toward a real release?
- **Team:** just you, or are artists and other developers involved?

## Prototype plan (Flutter + MapLibre, Android)

1. **Map and me:** show an OSM map with your live GPS position and record your walked path in the background.
2. **Claim and wall:** place a castle, walk a loop to draw its wall, and make segments strengthen as you walk them and decay over time.
3. **Hunt:** spawn monsters from OSM biomes and fight a simple squad auto-battle that drops parts.
4. **Siege:** a monster marches along real streets toward the castle and attacks the weakest wall segment, as basic tower defense.
5. **Server:** a backend (Supabase or Firebase free tier) so castles persist and friends can see each other.

Steps 1–2 test the most novel idea, walking the walls, so they come first.

My earlier suggested default was a small MVP: a map with your GPS position, one monster type with a simple fight, two resources, and one castle you can place and upgrade. That's enough to test whether the hunt and build loop is fun.
