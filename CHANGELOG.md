# Changelog

## Unreleased

- Kalimdor is mapped by hand: every zone's walls, roads and zone lines
  are built in (Data/Walls.lua, Data/Roads.lua, Data/ZoneLines.lua).
- Durotar redone from scratch: its built-in lines are the new ones only.
  Thunder Ridge and Drygulch Ravine's cave can be reached again.
- Thousand Needles is taken back out of the built-in lines too, the same way.
- Un'Goro Crater is taken back out of the built-in lines to be redrawn:
  at login its walls and zone lines become yours again to edit (once), and
  its done mark clears.
- Drygulch Ravine (Durotar) gives credit only in its cave at 51.5, 27.7:
  the route goes there rather than to the ravine's edge.
- Rut'theran Village: routes take the portal between Darnassus (Teldrassil
  23.3, 55.5) and Rut'theran (55.9, 89.3), and the boat from Auberdine,
  instead of finding no way down or swimming the sea. At the portal or the
  boat the arrow says to take it. The boat's docks are placed by eye.
- Spots are gone: the Spots button and mode, Spot here, moving spots by
  hand, learning them from credit (and its option), and the spots built
  into the addon. Routes go by area outlines. Where credit was given is
  still recorded, said in chat and shown as a cyan dot.
- Sharing is gone too: the Share button and window, `/cf share`, and
  importing a friend's walls and roads.
- Seven pieces of the redrawn zone maps that no Explore criterion names
  are areas of their own now, so a zone isn't done until its map is: the
  middle of Shen'dralas, New Avalon (Eastern Plaguelands), Krol'dok
  Stronghold (Riverglades), Whispering Forest (Tirisfal Glades), Skywatcher
  Plateau (Mulgore), Hive'Ashi and Twilight Base Camp (Silithus). They're
  read off the map only, and their tooltip says the achievement doesn't
  count them.
- Right-click a wall, zone line or road to remove just the segment under
  the cursor (the line is split round it). Shift-right-click removes the
  whole line, as right-click used to. Circles still go with a right-click.
- Ctrl-click one segment of a wall to make just that segment a zone line;
  the wall is split round it, so the ends meet exactly. Ctrl-click a zone
  line's segment to make it a wall again.
- Area borders show while drawing walls, zone lines or roads, every
  area's, whatever the border options say.
- A Clear button over the map while drawing walls, zone lines or roads:
  removes all of your lines of that kind in the zone shown (click twice
  to be sure). Lines built into the addon stay.
- Off a zeppelin or boat, the route flies on when that's quicker (for
  example Orgrimmar to Thunder Bluff for Mulgore). It used to plan the way
  before the game could place you on the new continent, then never look
  again, so it walked all the way. Flying is now reconsidered every ten
  seconds on any route, not only while a flight is planned.
- Mulgore (a trial run): each map area's real outline comes from the
  terrain (Data/Areas.lua, built by tools/build_areas.py). The route heads
  for the nearest point just inside each area's edge, over the waypoint
  graph and roads, instead of one spot in its middle. You've arrived as
  soon as you're anywhere inside. The window draws the outlines of the
  areas still covered, with the next stop's in green. Credit no longer
  moves a spot for an area with an outline.
- Mulgore's areas have no markers in the window: hovering over an area
  shows its name (and whether it's uncovered or on the route), and a click
  routes to it. Such an area has no spot to move.
- Every zone now has area outlines (548 areas; Undercity, which has no
  ground of its own, keeps its marker). Uncovered areas keep a faint
  outline. Two new options under Display: "Area borders on the map" and
  "Uncovered area borders".
- World map markers are off by default now, and turned off once for
  everyone; the option is still there to turn them back on.
- Walking paths are found over a waypoint graph (Data/Graph.lua, built
  ahead of time from the terrain by tools/build_graph.py: a waypoint every
  200 yards, along roads, at every area's spots, flight masters and docks,
  with the walking links between them) instead of searching the terrain's
  millions of points in the game. A path takes about a millisecond; the
  searching never takes more than 2 ms of a frame. Walls, zone lines and
  roads drawn by hand are laid over the graph in the game, so they work as
  before and still need no rebuild.
- The route planner orders stops by the same graph costs, walls and roads
  included, once a zone's are worked out (in the background).
- Kills, loot and quest steps no longer replan and redraw everything: a
  progress refresh goes on only when what's uncovered (here or on the
  route) or the flight points known really changed. The world map's
  markers aren't redrawn while it's closed.
- /cf perf [seconds]: measures what each part of the addon costs in time
  and memory, for reporting lag.
- Less lag: the arrow and the minimap button could aim at different
  targets (the flight master and the stop) and threw away each other's
  walking path many times a second, so it was searched for again and
  again. Each target now keeps its own path; the minimap button aims
  where the arrow does; paths and the route's lines aren't rebuilt when
  nothing changed.
- Fixed: every character counted as knowing every flight point, so New
  flight master said you knew them all and Stop at new flight masters
  never added any. The world map's flight point list on Forever calls
  every point discovered; known points now come only from the flight map
  itself. Each character needs to open a flight master's map once to
  fill in its list (the old lists are cleared).
- New flight master (under the window's map, or /cf fp): a route to the
  flight master quickest to reach on your continent whose flight point you
  haven't learned, walking or flying through the points you know (a far
  one a flight away can beat a near one on foot); the route flies when
  that's quicker.
- The continent and Azeroth maps in the window carry no labels now, only
  "I'm here!" on the zone you're in.
- Zone lines: in Walls mode tick Zone line (on the map) to draw purple
  lines that work as walls only for paths that stay in the zone (stop to
  stop, or from you while you're in it); a path coming from another zone
  crosses them. Shared and built in like walls.
- A stop on the other continent: the arrow, the lines and the flight
  planner take you to the nearest zeppelin (Horde) or boat (Alliance;
  Ratchet to Booty Bay for everyone) across, flying to it when that's
  quicker; "Board the zeppelin" at the dock. Once across, they head for
  the stop again.
- Route editing is a feature for everyone: Options, Route editing, Edit
  walls, roads and spots (or /cf edit) shows the Walls, Roads, Spots and
  Share buttons over the window's map (off by default; on already if you
  have drawn or moved anything). Share (or /cf share) writes your walls,
  roads and spots as one line of text for this zone or all of them, to
  copy with Ctrl+C and send to friends; pasting theirs in shows what it
  holds, then Add to mine or Replace mine takes it in.
- Clicking an area's marker routes you to that one area only, uncovered
  or not (even in a fully explored zone); the route ends when you reach it
  or uncover it. Start route gives the whole zone's route.
- Spots mode: a Spot here button moves the spot of the area you're standing
  in to where you are, and Shift-click on a marker moves that area's spot
  to you. Works on any character, uncovered there or not.
- World map: backing out of a city no longer leaves its markers on the
  next map.
- Uncovered areas are per character: read from your own map, not the
  account-wide Explore achievements, so an alt no longer sees its zones
  as explored because another character did them. Spots, walls and roads
  stay account-wide.
- Tirisfal Glades is mapped by hand: 14 walls, 16 roads and its 14 spots
  where the game really gives credit.
- Dead: as a ghost, the arrow, the minimap button and the route lines
  (window, world map, minimap) lead back to your corpse along the walking
  path, in white. Once you're alive the route carries on.
- A Done mapping this zone tick box on a zone's map: ticked, the zone gets a
  gold * in the list, ready to be built in. Zones already mapped by hand
  (built in) show their names in purple.
- Durotar is mapped by hand: walls and roads keep its routes to ground you
  can run, and its spots are where the game really gives credit. Built-in
  walls and roads steer paths without being drawn; only your own show and
  can be edited.
- The minimap button is one and a half times its old size, ring and all.
- After Me, the window's map keeps you in its middle as you move, and opens
  the next map when you cross into one (Me shows blue while it follows).
  Click Me again, drag the map or open another to stop.
- The window opens every map, not only zones with areas to explore: click a
  city (or any map inside a zone) on the map to open it, right-click goes
  back up. Opening the window or pressing Me in a city shows that city,
  with you and any route drawn on it. So it can stand in for the world map.
- A new fanfare for a finished zone (48 seconds). While it plays, a Stop
  music button near the top of the screen stops it; drag it anywhere and
  it stays there. Options, Display: Fanfare turns it off.
- The minimap button is now a compass arrow that turns as you do: green,
  pointing at the route's next stop while a route runs; gold, pointing at
  the nearest area still covered in your zone otherwise; upright when
  there's nothing to point at.
- Options, Display: Walls and roads on the map (on). Off, they're hidden on
  the window's map except while you draw them; they still steer paths.
- Spots: the Spots button over the window's map lets you drag an area's
  marker to move its spot; right-click a marker to put it back. A route
  under way there is planned again at once.
- Where credit is given: whenever an area of the zone you're in is
  uncovered, where you were standing is said in chat and kept, shown as a
  cyan dot on the window's map and in the marker's tooltip. While you run a
  route, the area's spot moves there too (Options, Routes: Learn spots from
  credit, on by default).
- Roads: the Roads button over the window's map draws roads on the zone
  shown, in lime green, the same way as walls (left-click corners,
  right-click to finish, right-click a road to remove it). Walking paths
  keep to a drawn road until they have to leave it for where they're going,
  even over ground the terrain calls too steep. With roads drawn, a path
  takes a little longer to work out.
- Options, Display: Covered areas on the world map (on). The game's world
  map shows a zone's still-covered areas in gray, as the window does, now
  apart from the world map markers, so it can be on with the markers off.
- The window can be resized: drag the grip in its bottom right corner. It
  keeps its shape as it grows or shrinks, and remembers its size.
- Options, Display: Open instead of the world map. Your world map key (M
  unless rebound) opens Compass Forever; the world map still opens from the
  minimap, the quest log and its other buttons. Off by default.
- A Map only button in the window's header hides the zone list and
  everything under the map, shrinking the window to its map; Full view
  brings them back. The window remembers which.
  In Map only the Explorer bar fills the space between the title and the
  buttons, with shorter text, so it no longer runs into Full view.
- Walls: the Walls button over the window's map turns on wall drawing for
  the zone shown. Left-click adds corners, right-click finishes a wall,
  right-click on a wall removes it. Walking paths, the arrow and the drawn
  route never cross a wall (flights still fly straight over them). Walls
  show faintly on the map the rest of the time. They are kept in your
  settings; good ones get built into the addon.
  While wall mode is on, the zone's map is shown fully uncovered, in color,
  so the ground can be seen where walls go. The area markers stay shown but
  let clicks through to the map.
- Circles: in wall mode, Shift-click a circle's middle, then Shift-click its
  edge. No walking path enters a circle. Right-click inside one to remove
  it.
- An area counts as uncovered only once the zone map shows it, not just once
  the achievement ticks it. Forever redrew some zone maps, and the
  achievement can still check an older map piece covering more ground:
  Razorwind Canyon ticked Drygulch Ravine but left a gap on Durotar's map.
  Such an area now stays on the route until the map fills in.
- Spots for 31 areas are now picked only from ground that counts for both
  the achievement and the redrawn map (Drygulch Ravine no longer points into
  Razorwind Canyon).
- A Me button beside the zoom buttons over the window's map: it opens the
  zone you're in, zoomed in, centered on you.
- The route is drawn on the minimap too: the same lines as the world map
  (your walk to the next stop, the stops after it, any flight) around you at
  the minimap's zoom, turning with it if it rotates and cut off at its edge,
  with a dot on each stop in reach (the next one larger). Options, Display:
  Route on the minimap (on by default).
- Fixed a Lua error when starting a route ("attempt to perform arithmetic on
  upvalue 'py'" in MinimapRoute.lua).

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
