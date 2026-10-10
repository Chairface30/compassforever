# Compass Forever

Uncover every zone map for the Explorer Legacy challenge on WoW Forever: the
shortest route through each zone, an arrow to every spot, and markers on the
world map.

Type `/cf` (or `/compassforever`), or click the map icon on the minimap.

## How it works

- **Open the world map** on any zone. A bar at the top says how many areas are
  left, with **Start route**. Each area still to find has a marker; click one to
  head there next.
- **Or let it run itself.** Tick *Route me automatically when I enter a zone*.
  Every time you enter a zone with areas still covered, a route starts and a
  banner tells you where to run: "Duskwood: 7 areas to uncover. Head northwest
  to Raven Hill, 420 yd". Leaving the zone ends that route.
- **The arrow** points at the next stop with the distance. Right-click it to
  skip a stop to the end of the route.
- **As you go**, each area you uncover is announced with the next stop, and the
  route is planned again from where you are, including areas you crossed on the
  way to another.
- **The window** lists every zone with how much of it is left. Pick one to see
  its own map: the parts you have uncovered, the fog over the rest, a marker on
  each area still to find, the route as a line, and you. Click a marker to go
  there next.

The route is the shortest walk from where you stand: exact for up to 11 areas,
and very close beyond that.

## Where the spots come from

From the game's own files, not from guesses. Each "Explore <zone>" achievement
names the map overlays it needs, and each overlay names the areas that uncover
it. The terrain tags every 33-yard square of ground with the area it belongs
to, which is what the server checks when you discover a place.
`tools/build_data.py` reads the terrain of both continents and, for every area,
picks spots that are:

- inside the area, as far from its edge as the area allows;
- on flat ground, not a cliff face;
- spread out, up to five per area, so the route can take whichever is on its way.

All 43 zones and 549 areas are covered, including Riverglades, Mount Hyjal and
Shen'dralas. The one exception is **Undercity**, which has no terrain of its own
(it is all underground building): its spot is the middle of its map art, marked
"approximate".

## Commands

| Command | |
|---|---|
| `/cf` | open or close the window |
| `/cf route [zone]` | route through this zone (or the one named) |
| `/cf auto` | automatic routes on entering a zone, on or off |
| `/cf next` | the next stop and its coordinates |
| `/cf skip` | leave the current stop for the end |
| `/cf stop` | stop the route |
| `/cf banner` | the big on-screen messages, on or off |
| `/cf arrow 1.5` | arrow size, 0.5 to 2 |
| `/cf probe` | what the client says, for bug reports |

## Rebuilding the data

After a client patch:

```
python tools/fetch_terrain.py <cache dir> --build <new build>
python tools/build_data.py <cache dir> .
python tests/addon_test.py
```

`fetch_terrain.py` downloads the tables and about 1,700 terrain tiles (around
800 MB) from wago.tools. `tools/exploration_report.txt` lists every area, how
many terrain squares it has, and where its first spot is.
