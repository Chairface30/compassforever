-- Compass Forever: Data/ZoneLines.lua
-- Zone lines drawn by hand (Pathing.lua): walls for the paths that stay in
-- their zone (stop to stop, or from the player while in it), crossed by
-- paths to or from another zone. Per zone, by its achievement ID: a list of
-- lines, each a flat list of the zone map's fractions, x1, y1, x2, y2, ...
-- Drawn in the window's wall mode with Zone line ticked, then copied here
-- from CompassForeverDB.

local _, ns = ...

ns.ZONELINES = {
}
