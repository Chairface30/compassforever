-- Compass Forever: Data/Ledges.lua
-- Ledges drawn by hand (Pathing.lua): one-way walls along cliffs and ridges
-- you can jump down but not climb. Each is drawn with the high ground on its
-- left (walking along it from its first corner); paths cross it only from
-- the left side to the right. Per zone, by its achievement ID: a list of
-- lines, each a flat list of the zone map's fractions, x1, y1, x2, y2, ...
-- Drawn in the window's Ledges mode, then copied here from CompassForeverDB.

local _, ns = ...

ns.LEDGES = {
}
