"""Build Data/Areas.lua: each map area's real outline, from the terrain.

An area is uncovered by stepping anywhere into it, so a route can head for
the nearest edge of the area rather than one spot in it. From the same
terrain build_data.py reads (the area ID of every 33-yard chunk):

  - rings: the outline of the area's chunks, corner to corner, as closed
    rings on the zone's map (more than one for an area in pieces, or with
    a hole). Inside = inside an odd number of rings;
  - edge: standing points just inside the edge, spread out all the way
    round, so the planner can pick whichever is nearest on the way.

Every zone, or only the ones named.

Usage: python build_areas.py <cache dir> <addon dir> [zone name ...]
"""
import os
import sys

from build_data import (CHUNK, CLIFF, EXPLORE_CATS, TILE, criteria_children, depth_map,
                        leaf_criteria, load, load_terrain, map_only_overlays)

EDGE_GAP = 3          # chunks (~100 yards) at least between edge points
EDGE_MAX = 20         # edge points per area at most


def outline(cells):
    """Closed rings of chunk-grid corners around a set of chunks. Each side
    with no chunk across it is one directed edge; following them gives the
    rings (at a pinch, either way round does: parity is all that counts)."""
    nxt = {}
    for x, y in cells:
        if (x, y - 1) not in cells:
            nxt.setdefault((x, y), []).append((x + 1, y))
        if (x + 1, y) not in cells:
            nxt.setdefault((x + 1, y), []).append((x + 1, y + 1))
        if (x, y + 1) not in cells:
            nxt.setdefault((x + 1, y + 1), []).append((x, y + 1))
        if (x - 1, y) not in cells:
            nxt.setdefault((x, y + 1), []).append((x, y))
    rings = []
    while nxt:
        start = min(nxt)
        ring = [start]
        cur = start
        while True:
            outs = nxt[cur]
            to = outs.pop()
            if not outs:
                del nxt[cur]
            if to == start:
                break
            ring.append(to)
            cur = to
        # corners only: drop points on a straight run
        keep = []
        n = len(ring)
        for i in range(n):
            a, b, c = ring[i - 1], ring[i], ring[(i + 1) % n]
            if (b[0] - a[0]) * (c[1] - b[1]) != (b[1] - a[1]) * (c[0] - b[0]):
                keep.append(b)
        rings.append(keep)
    return rings


def edge_points(cells, terrain):
    """Chunks just inside the area's edge, flat if possible, spread out."""
    depth = depth_map(cells)
    best = max(depth.values())
    want = 2 if best >= 3 else 1
    ring = [c for c in cells if depth[c] == want]
    pool = [c for c in ring if terrain[c][1] < CLIFF] or ring
    pool.sort()
    picked = [pool[0]]
    while len(picked) < EDGE_MAX:
        far = max(pool, key=lambda c: min((c[0] - p[0]) ** 2 + (c[1] - p[1]) ** 2 for p in picked))
        if min((far[0] - p[0]) ** 2 + (far[1] - p[1]) ** 2 for p in picked) < EDGE_GAP ** 2:
            break
        picked.append(far)
    return picked


def main():
    cache, addon = sys.argv[1], sys.argv[2]
    wanted = set(sys.argv[3:])
    ach = load(cache, "Achievement")
    crit = {c["ID"]: c for c in load(cache, "Criteria")}
    kids = criteria_children(load(cache, "CriteriaTree"))
    overlays = {o["ID"]: o for o in load(cache, "WorldMapOverlay")}
    current = {r["UiMapID"]: r["UiMapArtID"] for r in load(cache, "UiMapXMapArt")}
    art_to_map = {r["UiMapArtID"]: r["UiMapID"] for r in load(cache, "UiMapXMapArt_era")}
    art_to_map.update({art: ui for ui, art in current.items()})
    new_by_area = {}
    for o in overlays.values():
        new_by_area.setdefault((o["UiMapArtID"], o["AreaID_0"]), o)
    uimaps = {u["ID"]: u for u in load(cache, "UiMap")}
    areas = {a["ID"]: a for a in load(cache, "AreaTable")}
    tiles = {}
    for t in load(cache, "WorldMapOverlayTile"):
        if t["LayerIndex"] == "0":
            tiles.setdefault(t["WorldMapOverlayID"], []).append(int(t["FileDataID"]))
    art = tiles
    assign = {}
    for r in load(cache, "UiMapAssignment"):
        if r["OrderIndex"] == "0" and r["MapID"] in ("0", "1"):
            assign.setdefault(r["UiMapID"], r)

    terrain, by_area = {}, {}
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
        if wanted and name not in wanted:
            continue
        if mapID not in terrain:
            terrain[mapID] = load_terrain(cache, mapID)
            by_area[mapID] = {}
            for c, (area, _) in terrain[mapID].items():
                by_area[mapID].setdefault(area, set()).add(c)
        asg = assign[ui]
        minX, minY = float(asg["Region_0"]), float(asg["Region_1"])
        maxX, maxY = float(asg["Region_3"]), float(asg["Region_4"])
        w, h = maxY - minY, maxX - minX

        def corner(gx, gy):
            # a chunk-grid corner on the zone's map
            wx, wy = 32 * TILE - gy * CHUNK, 32 * TILE - gx * CHUNK
            return (maxY - wy) / w, (maxX - wx) / h

        def inside(c):
            fx, fy = corner(c[0] + 0.5, c[1] + 0.5)
            return 0 <= fx <= 1 and 0 <= fy <= 1

        print(f"{name}:")
        def area(key, label, ids):
            cells = set()
            for aid in ids:
                cells |= by_area[mapID].get(int(aid), set())
            cells = {x for x in cells if inside(x)}
            if not cells:
                return
            rings = [[corner(*p) for p in r] for r in outline(cells)]
            edge = [corner(x + 0.5, y + 0.5) for x, y in edge_points(cells, terrain[mapID])]
            out.append((key, label, rings, edge))
            print(f"  {label:30} {len(cells):4} chunks, {len(rings)} ring(s), "
                  f"{sum(len(r) for r in rings)} corners, {len(edge)} edge points")

        used_live = set()
        for t, c in leaves:
            o = overlays[c["Asset"]]
            live = new_by_area.get((current.get(ui), o["AreaID_0"]), o)
            used_live.add(live["ID"])
            for n in overlays.values():
                if (n["UiMapArtID"] == current.get(ui) and n["OffsetX"] == o["OffsetX"]
                        and n["OffsetY"] == o["OffsetY"]):
                    used_live.add(n["ID"])
            # the same areas build_data.py takes the spots from
            old_ids = [o[f"AreaID_{i}"] for i in range(4) if o[f"AreaID_{i}"] != "0"]
            live_ids = {live[f"AreaID_{i}"] for i in range(4) if live[f"AreaID_{i}"] != "0"}
            ids = [x for x in old_ids if x in live_ids] or old_ids
            area(int(c["ID"]), t["Description_lang"], ids)
        # the map's pieces no criterion names (build_data.py's mapOnly
        # nodes), by their overlay: "o" .. ID
        for o in map_only_overlays(overlays, current.get(ui), used_live, art):
            ids = [o[f"AreaID_{i}"] for i in range(4) if o[f"AreaID_{i}"] != "0"]
            area(f"o{o['ID']}", areas.get(ids[0], {}).get("AreaName_lang", "?") + " (map only)", ids)

    write(addon, out)
    return 0


def write(addon, areas):
    def flat(pts):
        return ", ".join(f"{round(x * 10000)}, {round(y * 10000)}" for x, y in pts)

    lines = [
        "-- Generated by tools/build_areas.py from the client's terrain. Do not",
        "-- edit by hand.",
        "--",
        "-- Each map area's outline, by its criteria ID (\"o\" .. overlay ID for a",
        "-- piece of the map no criterion names): rings, closed outlines on",
        "-- the zone's map (fractions x 10000, x then y; inside = inside an odd",
        "-- number of them), and edge, standing points just inside the edge all",
        "-- the way round. A route heads for the nearest of those, not one spot.",
        "local _, ns = ...",
        "ns.AREAS = {",
    ]
    for crit, name, rings, edge in areas:
        key = f'"{crit}"' if isinstance(crit, str) else crit
        lines.append(f"    [{key}] = {{ -- {name}")
        lines.append("        rings = {")
        for r in rings:
            lines.append(f"            {{ {flat(r)} }},")
        lines.append("        },")
        lines.append(f"        edge = {{ {flat(edge)} }},")
        lines.append("    },")
    lines.append("}")
    with open(os.path.join(addon, "Data", "Areas.lua"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    sys.exit(main())
