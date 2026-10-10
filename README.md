# Chair Legacy

A Legacy tracker for WoW Forever, in the spirit of Attune: every Legacy challenge
with its steps, and a walking route through every zone map with an arrow to each
spot that uncovers it.

Type `/legacy`.

## What it does

- **Every Legacy challenge** (65 of them, or the Hardcore set on a Hardcore realm),
  grouped like the game's own Legacy window: Classes, Tradeskills, Dungeons, Raids,
  Player vs. Player and Adventure. Each shows whether it is done and which of its
  steps are left: which dungeons, which raid bosses, and so on.
- **Track anything.** Tick the box beside a challenge or a zone, and it shows in a
  small tracker on screen with the steps still to do.
- **Exploration, area by area.** All 43 zone maps the Explorer challenge needs,
  including Riverglades, Mount Hyjal and Shen'dralas, with each of their 549 map
  areas and whether this character has uncovered it.
- **Shortest route.** Press Route on a zone (or `/legacy route`) and it plans the
  shortest walk from where you stand through every area still covered. An arrow
  points at each stop in turn, and the stops are numbered on the world map. Each
  time an area is uncovered, including one you crossed on the way to another, the
  route is planned again from where you are.

## Where the spots come from

From the game's own files, not from guesses. Each "Explore <zone>" achievement
names the map overlays it needs, and each overlay names the areas that uncover it.
The terrain tags every 33-yard square of ground with the area it belongs to, which
is what the server checks when you discover a place. `tools/build_data.py` reads
the terrain of both continents and, for every area, picks spots that are:

- inside the area, as far from its edge as the area allows;
- on flat ground, not a cliff face;
- spread out, up to five per area, so the route can take whichever is on its way.

The one exception is **Undercity**, which has no terrain of its own (it is all
underground building). Its spot is the middle of its map art, marked
"approximate".

## Commands

| Command | |
|---|---|
| `/legacy` | open or close the window |
| `/legacy route [zone]` | walk this zone (or the one named) |
| `/legacy next` | the next stop and its coordinates |
| `/legacy skip` | leave the current stop for the end (or right-click the arrow) |
| `/legacy stop` | stop the route |
| `/legacy tracker` | show or hide the tracker |
| `/legacy arrow 1.5` | arrow size, 0.5 to 2 |
| `/legacy probe` | what the client says, for bug reports |

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
