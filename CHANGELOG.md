# Changelog

## Unreleased

- Westfall redrawn and built in again: Westfall Lighthouse can be reached.
- Tanaris: 12 more walls and 2 more zone lines built in.
- Zones on the way (Options, Routes, or /cf ontheway; off by default): a
  route to another zone first uncovers every zone with areas left that you
  cross going there, one after another in the order you reach them, then
  the zone (or the area) you picked. Each zone's route starts once the one
  before is done; stopping the route ends the whole trip.

## Compass Forever v1.3 (2026-10-13)

**Every zone mapped by hand.** All of Kalimdor and the Eastern Kingdoms
(Riverglades too) have been walked, and walls, zone lines and roads drawn
where the terrain data alone gets it wrong. They're built in and steer every
route, so paths keep to ground you can really run.

**Area outlines instead of spots.**
- Each map area's real outline comes from the game's terrain. The route
  heads for the nearest point just inside each area, and you've arrived as
  soon as you're anywhere in it.
- The window draws the outlines: covered areas in gold, the next stop in
  green, uncovered ones faintly. Hover over an area for its name; click it
  to go there next. Two options under Display turn the borders and the
  uncovered ones' borders off.
- Seven pieces of the redrawn maps that no Explore criterion names are areas
  of their own now (the middle of Shen'dralas, New Avalon, Krol'dok
  Stronghold, Whispering Forest, Skywatcher Plateau, Hive'Ashi and Twilight
  Base Camp), so a zone isn't done until its map is.
- An area counts as uncovered only once the zone map shows it, not just once
  the achievement ticks it (Razorwind Canyon used to tick Drygulch Ravine).
- Drygulch Ravine's credit is in its cave at 51.5, 27.7: the route goes there.

**Flights.**
- Flights only between flight points you've learned. Forever's flight map
  lists every point of your faction, and every character was counted as
  knowing them all. Known points are read from the flight map again: open
  any flight master's map once on each character.
- From another zone, a route can start where your flight lands rather than
  at the corner nearest you; the chat line says where you'll land. Only the
  zone's own flight points count (Ashenvale's route no longer flies to Sun
  Rock Retreat, which is on Ashenvale's map but in Stonetalon).
- A flight is taken when it saves running, even if it takes longer than
  running there would: a minute in the air counts as a quarter of a minute
  on foot. The flight line says how much running it saves.
- Opening a flight master's map says how many flight points you know, and
  the flight the route plans or why there's none.
- The zone's flight masters you haven't met are always stops on its route
  (Stop at new flight masters), and only the zone's own.
- Off a zeppelin or boat, the route flies on when that's quicker, instead of
  walking all the way.
- A stop on the other continent: the arrow, the lines and the flight planner
  take you to the nearest zeppelin or boat, with "Board the zeppelin" at the
  dock.
- Rut'theran Village: routes take the portal from Darnassus (23.3, 55.5) or
  the boat from Auberdine, and the arrow says to take it.

**Getting around.**
- Walking paths come from a waypoint graph built ahead of time, so finding
  one takes about a millisecond and never more than 2 ms of a frame; the
  route's order uses the same walking costs.
- Less lag: kills, loot and quests no longer replan everything, and the
  arrow and minimap button no longer fight over the walking path.
- Dead: the arrow and the route's lines lead back to your corpse.

**The map window.**
- It opens every map, cities included, and can stand in for the world map
  (Options, Display: Open instead of the world map).
- A Me button opens your zone centered on you and keeps you in the middle as
  you move. Map only shrinks the window to its map; drag the corner grip to
  resize it.
- The route is drawn on the minimap too (Options, Display: Route on the
  minimap).
- The minimap button is a compass arrow pointing at the next stop.
- Uncovered areas are per character, as the Legacy window has them: an
  area counts once this character's Explore challenge has it, and its
  piece of the map shows. Another character's exploration no longer shows
  as uncovered (Moonglade on a character that never went there).
- No more spots: areas have no markers on the world map or dots in the
  window; their outlines show where they are. World map markers (off by
  default) are now the route bar and the route's numbered stops while it
  runs. Still-covered areas show gray on the world map on their own option.
- A new 48-second fanfare for a finished zone, with a Stop music button
  (Options, Display: Fanfare turns it off).
- /cf perf [seconds] measures what the addon costs, for reporting lag.
- Fixed a Lua error when starting a route (MinimapRoute.lua).

## Compass Forever v1.2 (2026-10-12)

- The window is laid out again so nothing overlaps or runs off: the trail
  over the map no longer slides away when the map is zoomed or collides with
  the settings, long route text wraps beside the route buttons instead of
  running under them, and zone names in the list are cut short before they
  reach the count.
- Settings moved into an Options panel (top right), grouped into Routes and
  Display, each with a line saying what it does. New there: routing past new
  flight masters, on-screen messages and the minimap button (also
  /cf minimap).
- Zoom buttons (+ and -) beside the trail, and a line under the map saying
  how to work the map that is shown.
- The zone list: tabs for the continents, a colored stripe and a line for
  the zone you're in and the zone you're routing, and opening a zone scrolls
  it into view.

## Compass Forever v1.1 (2026-10-10)

- The walking path works from anywhere on the continent, not just inside
  the route's zone: every zone's terrain is stitched into one map of the
  continent, so from Undercity to Silverpine (say) the line and the arrow
  follow the way there across zone lines instead of a straight line.
- Routes keep to the roads where they can. Roads are found from the ground's
  own textures (every texture named as a road: cobblestone, brick, stone and
  dirt roads, zone by zone); walking along one counts as 30% shorter, so a
  route takes the road when it's at most about 40% longer. You don't move
  faster on a road, but roads skirt cliffs, woods and camps.
- Routes are drawn and followed as a few waypoints along the way rather than
  every bend: a line within 20 yards of the path is close enough.
- A flight master you haven't met, in the zone you're exploring, joins the
  route as a stop (in blue) when it costs at most 800 yards more walking, so
  you pick up the flight point on the way. Learning it takes it off the
  route. /cf flightpoints turns this off.
- The route is drawn as you'd travel it: a flight straight from flight point
  to flight point, and every walk (to the flight master, from the landing,
  and between stops) along the walking path on the map. The arrow follows
  the walking path to the flight master too.
- Known flight points are read the way the world map reads them, from
  anywhere, so flights are suggested without opening a flight map first
  (before, no flight point was known until one had been opened).
- At the flight master, a "Fly to ..." button by the flight map takes the
  planned flight in one click; with Fly automatically on (in the window, or
  /cf autofly) it's taken as soon as the map opens.
- A flight is suggested when it saves 30 seconds or more (was 45).
- The route line carries on across zone lines. Wherever you are and whatever
  map is open (the route's zone, the zone next door, the continent, Azeroth),
  the world map and the window draw the route from you: the walking path to
  the next stop, any flight (in blue), and the legs between stops, with the
  route's numbered stops.
- Routes go round what can't be walked. The terrain of every zone is mapped
  every 8 yards: slopes too steep to climb (over 50 degrees), sheer drops,
  lava and slime are avoided, deep water is swum. The route's order uses real
  walking distances, the arrow follows the walking path (aiming a little way
  ahead along it), and the window draws that path.
- Flying when it's quicker. Each character's flight points are remembered
  whenever a flight map is open; when the next stop is far and a flight saves
  real time, the arrow takes you to the flight master first and says where to
  fly, and the route carries on from where you land.
- The window's map zooms with the mouse wheel, around the point under the
  cursor, up to 4x. Drag a zoomed map to move around it. Scrolling out past
  full size goes up a level (zone, continent, Azeroth), as the world map does.

## Compass Forever v1.0 (2026-10-09)

The first release.

- All 43 zone maps the Explorer Legacy challenge needs, including Riverglades,
  Mount Hyjal and Shen'dralas, with each of their 549 areas and whether this
  character has uncovered it.
- Exact spots for every area, taken from the game's own terrain: well inside
  the area and on flat ground. Undercity, which has no ground of its own, is
  marked approximate.
- The shortest route through a zone from where you stand (exact for up to 11
  areas), replanned every time an area is uncovered. A waypoint arrow points
  at each stop; right-click it to skip one.
- On the world map: a bar with Start route for the zone on screen, a marker
  on every area still to find (click one to head there next), and the areas
  not yet uncovered drawn in gray. The markers sit above every other pin.
- Route me automatically when I enter a zone: starts the route and a banner
  says which way to run. Each uncovered area is announced with the next stop,
  and finishing a zone plays a victory fanfare (Sounds\fanfare.ogg; replace it
  with your own clip if you like).
- A window whose map works like the world map: right-click backs out from a
  zone to its continent and to Azeroth, clicking a continent or zone opens it,
  and zones light up under the cursor with how many areas they have left. A
  zone's map shows what you have uncovered in color, the rest in gray, a
  marker per area, the route as a line, and you.
- /cf (or /compassforever) opens the window; /cf route, auto, next, skip,
  stop, banner, arrow and probe do the rest.
