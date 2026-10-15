"""Build Data/MapData.lua: what the game's own data says about each zone's
map, for the window's layers (Layers.lua, the map's authors only).

From the client's tables and terrain (the cache fetch_terrain.py fills, plus
AreaPOI.csv and AreaTrigger.csv from wago.tools for the same build):

  border    - the zone's real edge: the outline of every terrain chunk whose
              area is the zone or one of its subzones (closed rings);
  crossings - where walkable ground crosses that edge into a neighbour's
              (both chunks under CLIFF yards of height across): the ways in
              and out the terrain itself has, one per stretch, with the
              neighbour's name and how many chunks (33 yards each) wide;
  places    - the world map's own place names (AreaPOI) on the zone's map;
  triggers  - the game's area triggers (AreaTrigger) on it: a circle of a
              radius, or a box, in yards;
  hits      - each area's hover box on the world map (WorldMapOverlay's
              HitRect, in the 1002 x 668 map art), with its name.

Usage: python build_mapdata.py <cache dir> <addon dir>
"""
import math
import os
import sys

from build_areas import outline
from build_data import (CHUNK, CLIFF, EXPLORE_CATS, TILE, criteria_children, leaf_criteria, load,
                        load_terrain)

ART_W, ART_H = 1002.0, 668.0


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    cache, addon = sys.argv[1], sys.argv[2]
    ach = load(cache, "Achievement")
    crit = {c["ID"]: c for c in load(cache, "Criteria")}
    kids = criteria_children(load(cache, "CriteriaTree"))
    overlays = {o["ID"]: o for o in load(cache, "WorldMapOverlay")}
    current = {r["UiMapID"]: r["UiMapArtID"] for r in load(cache, "UiMapXMapArt")}
    art_to_map = {r["UiMapArtID"]: r["UiMapID"] for r in load(cache, "UiMapXMapArt_era")}
    art_to_map.update({art: ui for ui, art in current.items()})
    uimaps = {u["ID"]: u for u in load(cache, "UiMap")}
    areas = {int(a["ID"]): a for a in load(cache, "AreaTable")}
    parent = {k: int(a["ParentAreaID"]) for k, a in areas.items()}
    pois = load(cache, "AreaPOI")
    triggers = load(cache, "AreaTrigger")
    assign = {}
    for r in load(cache, "UiMapAssignment"):
        if r["OrderIndex"] == "0" and r["MapID"] in ("0", "1"):
            assign.setdefault(r["UiMapID"], r)

    def root(aid):
        seen = set()
        while parent.get(aid, 0) and aid not in seen:
            seen.add(aid)
            aid = parent[aid]
        return aid

    def name_of(aid):
        return areas.get(aid, {}).get("AreaName_lang", "?")

    terrain, rooted = {}, {}
    out = []
    for a in sorted(ach, key=lambda a: a["Title_lang"]):
        if a["Category"] not in map(str, EXPLORE_CATS):
            continue
        leaves = leaf_criteria(a["Criteria_tree"], kids, crit)
        if not leaves or any(c["Type"] != "43" for _, c in leaves):
            continue
        mapID = EXPLORE_CATS[int(a["Category"])]
        first = overlays[leaves[0][1]["Asset"]]
        ui = art_to_map[first["UiMapArtID"]]
        name = uimaps[ui]["Name_lang"]
        if mapID not in terrain:
            terrain[mapID] = load_terrain(cache, mapID)
            rooted[mapID] = {c: root(area) for c, (area, _) in terrain[mapID].items()}
        ter, rt = terrain[mapID], rooted[mapID]
        roots = set()
        for _, c in leaves:
            o = overlays[c["Asset"]]
            for i in range(4):
                if o[f"AreaID_{i}"] != "0":
                    roots.add(root(int(o[f"AreaID_{i}"])))
        asg = assign[ui]
        minX, minY = float(asg["Region_0"]), float(asg["Region_1"])
        maxX, maxY = float(asg["Region_3"]), float(asg["Region_4"])
        w, h = maxY - minY, maxX - minX

        def frac(wx, wy):
            return (maxY - wy) / w, (maxX - wx) / h

        def corner(gx, gy):
            return frac(32 * TILE - gy * CHUNK, 32 * TILE - gx * CHUNK)

        mine = {c for c, r in rt.items() if r in roots}
        border = [[corner(*p) for p in ring] for ring in outline(mine)] if mine else []

        # crossings: walkable chunk pairs across the edge, grouped by the
        # neighbour and by touching
        pairs = {}
        for c in mine:
            if ter[c][1] >= CLIFF:
                continue
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                n = (c[0] + dx, c[1] + dy)
                r = rt.get(n)
                if n in ter and r and r not in roots and ter[n][1] < CLIFF:
                    pairs.setdefault(r, {})[c] = n
        crossings = []
        for r, edge in pairs.items():
            left = set(edge)
            while left:
                start = left.pop()
                group, todo = [start], [start]
                while todo:
                    c = todo.pop()
                    for dx in (-1, 0, 1):
                        for dy in (-1, 0, 1):
                            n = (c[0] + dx, c[1] + dy)
                            if n in left:
                                left.remove(n)
                                group.append(n)
                                todo.append(n)
                if len(group) < 2:
                    continue
                gx = sum(c[0] + 0.5 + (edge[c][0] - c[0]) * 0.5 for c in group) / len(group)
                gy = sum(c[1] + 0.5 + (edge[c][1] - c[1]) * 0.5 for c in group) / len(group)
                x, y = corner(gx, gy)
                if -0.05 <= x <= 1.05 and -0.05 <= y <= 1.05:
                    crossings.append((x, y, name_of(r), len(group)))

        places = []
        for p in pois:
            if p["ContinentID"] != str(mapID):
                continue
            x, y = frac(float(p["Pos_0"]), float(p["Pos_1"]))
            if 0 <= x <= 1 and 0 <= y <= 1 and p["Name_lang"]:
                places.append((x, y, p["Name_lang"]))

        trigs = []
        for t in triggers:
            if t["ContinentID"] != str(mapID):
                continue
            x, y = frac(float(t["Pos_0"]), float(t["Pos_1"]))
            if 0 <= x <= 1 and 0 <= y <= 1:
                trigs.append((x, y, float(t["Radius"]), float(t["Box_length"]), float(t["Box_width"]),
                              float(t["Box_yaw"]), int(t["ID"])))

        hits = []
        art = current.get(ui)
        for o in overlays.values():
            if o["UiMapArtID"] == art:
                t, b = float(o["HitRectTop"]) / ART_H, float(o["HitRectBottom"]) / ART_H
                l, r = float(o["HitRectLeft"]) / ART_W, float(o["HitRectRight"]) / ART_W
                if r > l and b > t:
                    hits.append((l, t, r, b, name_of(int(o["AreaID_0"]))))

        out.append((int(a["ID"]), name, border, crossings, places, trigs, hits))
        print(f"{name:24} border {sum(len(r) for r in border)} corners, {len(crossings)} crossings, "
              f"{len(places)} places, {len(trigs)} triggers, {len(hits)} hover boxes")

    write(addon, out)
    return 0


def n4(v):
    return round(v * 10000)


def write(addon, zones):
    lines = [
        "-- Generated by tools/build_mapdata.py from the client's own tables and",
        "-- terrain. Do not edit by hand.",
        "--",
        "-- What the game's data says about each zone's map (by its Explore",
        "-- achievement), drawn by the window's layers (Layers.lua). Positions are",
        "-- the zone map's fractions x 10000.",
        "--   border    the zone's real edge: closed rings of its terrain chunks",
        "--   crossings { x, y, neighbour, chunks wide }: walkable ground over the edge",
        "--   places    { x, y, name }: the world map's place names (AreaPOI)",
        "--   triggers  { x, y, radius, box length, box width, yaw, ID } (AreaTrigger), yards",
        "--   hits      { left, top, right, bottom, name }: each area's hover box",
        "local _, ns = ...",
        "ns.MAPDATA = {",
    ]
    for ach, name, border, crossings, places, trigs, hits in zones:
        lines.append(f"    [{ach}] = {{ -- {name}")
        lines.append("        border = {")
        for ring in border:
            lines.append("            { " + ", ".join(f"{n4(x)}, {n4(y)}" for x, y in ring) + " },")
        lines.append("        },")
        lines.append("        crossings = {")
        for x, y, nb, n in crossings:
            lines.append(f"            {{ {n4(x)}, {n4(y)}, {lua_str(nb)}, {n} }},")
        lines.append("        },")
        lines.append("        places = {")
        for x, y, nm in places:
            lines.append(f"            {{ {n4(x)}, {n4(y)}, {lua_str(nm)} }},")
        lines.append("        },")
        lines.append("        triggers = {")
        for x, y, rad, bl, bw, yaw, tid in trigs:
            lines.append(f"            {{ {n4(x)}, {n4(y)}, {rad:g}, {bl:g}, {bw:g}, {yaw:.3f}, {tid} }},")
        lines.append("        },")
        lines.append("        hits = {")
        for l, t, r, b, nm in hits:
            lines.append(f"            {{ {n4(l)}, {n4(t)}, {n4(r)}, {n4(b)}, {lua_str(nm)} }},")
        lines.append("        },")
        lines.append("    },")
    lines.append("}")
    with open(os.path.join(addon, "Data", "MapData.lua"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    sys.exit(main())
