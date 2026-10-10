"""Download the game's own tables and terrain files for one client build.

Everything comes from wago.tools, which mirrors the client's files:
  - the DB2 tables (as CSV) that describe achievements, criteria, map overlays
    and areas;
  - each continent's WDT, which lists its terrain tiles;
  - every root ADT terrain tile of Eastern Kingdoms (map 0) and Kalimdor (1).

A root ADT tags each of its 16x16 chunks (33.3 yards a side) with an area ID.
That tag is what the server reads to decide which area you are standing in, so
it is the ground truth for "where do I have to stand to uncover this part of
the map". build_data.py turns it into Data/Exploration.lua.

Usage: python fetch_terrain.py <cache dir> [--build 1.60.1.70334]
Files already in the cache are not downloaded again.
"""
import argparse
import concurrent.futures as cf
import os
import struct
import sys
import time
import urllib.request

BUILD = "1.60.1.70334"
TABLES = [
    "Achievement", "Criteria", "CriteriaTree", "WorldMapOverlay", "UiMap",
    "UiMapXMapArt", "UiMapAssignment", "AreaTable", "Map", "Achievement_Category",
]
WDT = {0: 775971, 1: 782779}  # world/maps/azeroth/azeroth.wdt, kalimdor.wdt
UA = {"User-Agent": "CompassForever data build"}


def get(url, dest, tries=4):
    if os.path.exists(dest) and os.path.getsize(dest) > 0:
        return dest
    for attempt in range(tries):
        try:
            req = urllib.request.Request(url, headers=UA)
            with urllib.request.urlopen(req, timeout=60) as r:
                data = r.read()
            tmp = dest + ".part"
            with open(tmp, "wb") as f:
                f.write(data)
            os.replace(tmp, dest)
            return dest
        except Exception as e:  # noqa: BLE001 -- retried, then reported
            if attempt == tries - 1:
                raise RuntimeError(f"{url}: {e}") from e
            time.sleep(2 * (attempt + 1))
    return dest


def chunks(data):
    """Yield (magic, payload) for each top-level chunk. Magic is stored
    reversed in the file ("REVM" for MVER)."""
    pos = 0
    while pos + 8 <= len(data):
        magic = data[pos:pos + 4][::-1].decode("latin-1")
        size = struct.unpack_from("<I", data, pos + 4)[0]
        yield magic, data[pos + 8:pos + 8 + size]
        pos += 8 + size


def wdt_tiles(path):
    """(tileX, tileY, rootADTFileDataID) for every tile the WDT says exists."""
    data = open(path, "rb").read()
    out = []
    for magic, payload in chunks(data):
        if magic == "MAID":
            for i in range(64 * 64):
                root = struct.unpack_from("<I", payload, i * 32)[0]
                if root:
                    # The MAID grid is row-major by Y: entry i is tile (i % 64, i // 64).
                    out.append((i % 64, i // 64, root))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cache")
    ap.add_argument("--build", default=BUILD)
    args = ap.parse_args()
    build = args.build
    os.makedirs(os.path.join(args.cache, "db2"), exist_ok=True)

    for t in TABLES:
        get(f"https://wago.tools/db2/{t}/csv?build={build}",
            os.path.join(args.cache, "db2", t + ".csv"))
    # The Classic Era build still lists the old map art the achievements use.
    get("https://wago.tools/db2/UiMapXMapArt/csv?build=1.15.9.70003",
        os.path.join(args.cache, "db2", "UiMapXMapArt_era.csv"))
    print("tables ok")

    jobs = []
    for mapID, fdid in WDT.items():
        d = os.path.join(args.cache, f"map{mapID}")
        os.makedirs(d, exist_ok=True)
        wdt = get(f"https://wago.tools/api/casc/{fdid}?version={build}", os.path.join(d, "map.wdt"))
        tiles = wdt_tiles(wdt)
        print(f"map {mapID}: {len(tiles)} tiles")
        for tx, ty, root in tiles:
            jobs.append((f"https://wago.tools/api/casc/{root}?version={build}",
                         os.path.join(d, f"{tx}_{ty}.adt")))

    done = 0
    with cf.ThreadPoolExecutor(max_workers=6) as pool:
        for fut in cf.as_completed([pool.submit(get, u, p) for u, p in jobs]):
            fut.result()
            done += 1
            if done % 100 == 0:
                print(f"  {done}/{len(jobs)}", flush=True)
    print(f"terrain ok: {len(jobs)} tiles")
    return 0


if __name__ == "__main__":
    sys.exit(main())
