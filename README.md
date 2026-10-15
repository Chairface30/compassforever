# Compass Forever

Uncover every zone map for the Explorer Legacy challenge on WoW Forever: a
route through each zone, one nearest area after another, with each area's real
outline on the map and an arrow to the nearest edge of every area.

Type `/cf` (or `/compassforever`), or click the map icon on the minimap.

## How it works

- **Open the world map** on any zone. Areas you haven't uncovered yet are drawn
  in gray, so you see the whole zone. With *World map markers* on (Options,
  off by default), a bar at the top says how many areas are left, with
  **Start route**, and each area still to find has a marker.
- **Or let it run itself.** Tick *Route me automatically* under Options in the window.
  Every time you enter a zone with areas still covered, a route starts and a
  banner tells you where to run: "Duskwood: 7 areas to uncover. Head northwest
  to Raven Hill, 420 yd". Leaving the zone ends that route.
- **The arrow** points at the next stop with the distance. Right-click it to
  skip that stop: the route heads for another, and comes back to the skipped
  one when nothing else is left.
- **As you go**, each area you uncover is announced. The route keeps its stop
  until that one is uncovered, then heads for the nearest area left from where
  you are.
- **The window** lists every zone with how much of it is left, and its map
  works like the world map. Right-click to back out from a zone to its
  continent and then to Azeroth; click a continent or a zone to open it.
  Scroll the mouse wheel to zoom in and out, and drag a zoomed map to move
  around it.
  Zones light up as you point at them and show how many areas they have left.
  A zone's own map shows what you have uncovered in color and the rest in
  gray, each area's outline, the route as a line, and you. Point at an area
  for its name; click it to go there next.

The route doesn't plan the whole zone ahead. It starts with the area nearest
to where you are (where you walk in from outside the zone, or where a flight
lands when flying there saves the run), and each time an area is uncovered it
picks the nearest one left.

## Around mountains, and by air

Routes go round what can't be walked. Every zone's terrain is mapped every 8
yards from the game's own height data: slopes too steep to climb (over 50
degrees), sheer drops, lava and slime are avoided, and deep water is swum. The
arrow follows the
walking path, aiming a little way ahead along it, so it bends round a cliff
instead of pointing through it. Bridges and buildings aren't terrain, so a
gorge with a bridge over it counts as hard going rather than impossible: the
path will still cross where there's no other way.

Routes keep to the roads where they can: a road is any ground painted with
a road texture (cobblestone, brick, stone or dirt road, zone by zone), and a
walk along one counts as 30% shorter, so the route takes the road when it's
not much longer. You don't move faster on a road, but roads skirt cliffs,
woods and camps. Paths are drawn as a few waypoints, not every bend.

Every zone has also been walked and mapped by hand: walls where the ground
can't really be crossed (fences, rock faces the height data misses), lines
that keep a route inside its zone, and roads the textures don't show. They
are built in and steer every route.

When the next stop is far away and a flight would save real running, even
if the flight itself takes longer, the arrow
takes you to the nearest useful flight master first and tells you where to
fly; after you land the route carries on. From another zone, a route can start
where your flight lands rather than at the corner nearest you. Flights only go
between flight points you've learned; the zone's flight masters you haven't
met are stops on its route. Compass Forever learns which flight points each
character knows from the flight map, so open any flight master's map once on
each character.

## The fanfare

Finishing a zone on a route plays `Sounds\fanfare.ogg`, the Final Fantasy VII
victory fanfare. Replace that file with any Ogg clip of your own to change it.

## Where the areas come from

From the game's own files, not from guesses. Each "Explore <zone>" achievement
names the map overlays it needs, and each overlay names the areas that uncover
it. A few pieces of Forever's redrawn maps aren't in any achievement (the
middle of Shen'dralas, New Avalon and five more); they're areas too, so a zone
is done only when its whole map is. The terrain tags every 33-yard square of
ground with the area it belongs to, which is what the server checks when you
discover a place. `tools/build_areas.py` traces each area's squares into its
outline, and picks points just inside the edge all the way round, on flat
ground: the route enters each area at whichever is nearest on its way.

All 43 zones and 556 areas are covered, including Riverglades, Mount Hyjal and
Shen'dralas. The one exception is **Undercity**, which has no terrain of its own
(it is all underground building): it has no outline, and its marker is the
middle of its map art, marked "approximate".

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
python tools/build_areas.py <cache dir> .
python tools/build_terrain.py <cache dir> .
python tests/addon_test.py
```

`build_terrain.py` needs NumPy and SciPy (`pip install numpy scipy`).

`fetch_terrain.py` downloads the tables and about 1,700 terrain tiles (around
800 MB) from wago.tools. `tools/exploration_report.txt` lists every area, how
many terrain squares it has, and where its middle point is.
