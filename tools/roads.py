"""Where the roads are, from the ground's own textures.

Roads in the game are painted onto the terrain: each terrain chunk lists up
to four textures with a 64x64 coverage map each (the first one fills what
the others leave). A road is wherever a road texture covers the ground.
Which textures are roads is decided by name (ROAD_WORDS and ROAD_TEXTURES),
from every texture the two continents use: `python roads.py <cache> --list`
prints them with how much ground each covers, to check the choice.
"""
import json
import os
import re
import struct
import sys
from collections import Counter

import numpy as np

# Texture names (tileset/<zone>/<name>.blp) that are roads or paths.
ROAD_WORDS = ("road", "cobble", "path", "trail", "brick", "street", "paved", "flagstone")
# Roads whose names don't say so (dirt tracks), and words that look like
# roads but aren't.
ROAD_TEXTURES = set()
NOT_ROADS = ("pathway_rock",)


def is_road(name):
    base = os.path.basename(name).lower()
    if any(n in base for n in NOT_ROADS):
        return False
    return base in ROAD_TEXTURES or any(w in base for w in ROAD_WORDS)


def decompress(data, pos):
    """The run-length coded 64x64 coverage map at `pos`."""
    out = bytearray()
    while len(out) < 4096:
        info = data[pos]
        pos += 1
        count = info & 0x7F
        if info & 0x80:
            out.extend(bytes([data[pos]]) * count)
            pos += 1
        else:
            out.extend(data[pos:pos + count])
            pos += count
    return np.frombuffer(bytes(out[:4096]), np.uint8).reshape(64, 64)


def read_tex(path):
    """{(ix, iy): [(texture file ID, coverage 64x64 0..1 or None for the
    first layer)]} for one tex0 file."""
    data = open(path, "rb").read()
    textures = []
    chunks = {}
    index = 0
    pos = 0
    while pos + 8 <= len(data):
        magic = data[pos:pos + 4][::-1]
        size = struct.unpack_from("<I", data, pos + 4)[0]
        body = pos + 8
        if magic == b"MDID":
            textures = list(struct.unpack_from(f"<{size // 4}I", data, body))
        elif magic == b"MCNK":
            layers, mcal = [], None
            sub, end = body, body + size
            while sub + 8 <= end:
                smagic = data[sub:sub + 4][::-1]
                ssize = struct.unpack_from("<I", data, sub + 4)[0]
                if smagic == b"MCLY":
                    for i in range(ssize // 16):
                        tex, flags, offset, _ = struct.unpack_from("<4I", data, sub + 8 + i * 16)
                        layers.append((tex, flags, offset))
                elif smagic == b"MCAL":
                    mcal = sub + 8
                sub += 8 + ssize
            result = []
            for k, (tex, flags, offset) in enumerate(layers):
                fid = textures[tex] if tex < len(textures) else 0
                if k == 0 or mcal is None:
                    result.append((fid, None))
                elif flags & 0x200:
                    result.append((fid, decompress(data, mcal + offset) / 255.0))
                else:
                    raw = data[mcal + offset:mcal + offset + 4096]
                    result.append((fid, np.frombuffer(raw, np.uint8).reshape(64, 64) / 255.0))
            chunks[(index % 16, index // 16)] = result
            index += 1
        pos = body + size
    return chunks


def road_cover(layers, road_ids):
    """How much of each of the chunk's 64x64 spots is road, 0..1."""
    cover = np.zeros((64, 64))
    rest = np.ones((64, 64))
    for fid, alpha in layers[1:]:
        if alpha is None:
            continue
        if fid in road_ids:
            cover = np.maximum(cover, alpha)
        rest = rest - alpha
    if layers and layers[0][0] in road_ids:
        cover = np.maximum(cover, np.clip(rest, 0, 1))
    return cover


def load_names(cache):
    with open(os.path.join(cache, "tilesets.json"), encoding="utf-8") as f:
        return {int(k): v for k, v in json.load(f).items()}


def survey(cache):
    names = load_names(cache)
    use = Counter()
    for m in ("map0", "map1"):
        d = os.path.join(cache, m)
        for f in os.listdir(d):
            if f.endswith("_tex0.tex"):
                for layers in read_tex(os.path.join(d, f)).values():
                    for fid, _ in layers:
                        use[fid] += 1
    return names, use


if __name__ == "__main__":
    cache = sys.argv[1]
    names, use = survey(cache)
    words = sys.argv[3:] if len(sys.argv) > 3 else None
    for fid, n in use.most_common():
        name = names.get(fid, f"<{fid}>")
        if words and not any(w in name for w in words):
            continue
        mark = "ROAD " if is_road(name) else "     "
        print(f"{mark}{n:6} {name}")
