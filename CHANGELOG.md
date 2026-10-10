# Changelog

## Unreleased

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
