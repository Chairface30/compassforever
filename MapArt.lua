-- Compass Forever: MapArt.lua
-- Drawing map art onto our own frames, for the window and the world map.
--
-- An overlay (one part of a zone map) is a grid of tiles: tileW x tileH
-- pixels each, the last column and row cut to what is left of the overlay's
-- width and height, their files rounded up to a power of two. This is the
-- same sum Blizzard's map exploration provider does.
--
-- Covered areas are drawn from our own data (Data/Exploration.lua: each
-- node's ox, oy, tw, th, files), because the client only hands out the art of
-- uncovered ones.

local _, ns = ...

local function FileSize(px)
    local f = 16
    while f < px do f = f * 2 end
    return f
end

-- Call draw(file, x, y, w, h, u, v) for every tile of an overlay: x, y, w, h
-- in map art pixels, u, v the right and bottom texture coordinates.
function ns.EachTile(ox, oy, texW, texH, files, tileW, tileH, draw)
    tileW, tileH = tileW or 256, tileH or 256
    local wide = math.ceil(texW / tileW)
    local tall = math.ceil(texH / tileH)
    for j = 1, tall do
        local ph, fh = tileH, tileH
        if j == tall then
            ph = texH - tileH * (tall - 1)
            fh = FileSize(ph)
        end
        for k = 1, wide do
            local pw, fw = tileW, tileW
            if k == wide then
                pw = texW - tileW * (wide - 1)
                fw = FileSize(pw)
            end
            local file = files[(j - 1) * wide + k]
            if file then
                draw(file, ox + tileW * (k - 1), oy + tileH * (j - 1), pw, ph, pw / fw, ph / fh)
            end
        end
    end
end

-- The size of a map's art in pixels, and its tile size.
function ns.ArtLayer(mapID)
    local ok, layers = ns.Ask(ns.API("C_Map", "GetMapArtLayers"), mapID)
    local layer = ok and type(layers) == "table" and layers[1]
    local lw = layer and ns.Num(layer.layerWidth) or 1002
    local lh = layer and ns.Num(layer.layerHeight) or 668
    local tw = layer and ns.Num(layer.tileWidth) or 256
    local th = layer and ns.Num(layer.tileHeight) or 256
    return lw, lh, tw, th
end

-- A pool of textures on `parent`, all in one draw layer. Begin() hides them
-- all; Next() hands out the next one, shown.
function ns.TexturePool(parent, layer, sub)
    local pool = { list = {}, used = 0 }
    function pool:Begin()
        for _, t in ipairs(self.list) do t:Hide() end
        self.used = 0
    end
    function pool:Next()
        self.used = self.used + 1
        local t = self.list[self.used]
        if not t then
            t = parent:CreateTexture(nil, layer, nil, sub or 0)
            self.list[self.used] = t
        end
        t:Show()
        return t
    end
    return pool
end

-- Draw a zone's still-covered areas, gray, into `pool`. `scale` is screen
-- units per map art pixel. Only the areas not uncovered are drawn: the
-- uncovered ones are already on the map in color.
function ns.DrawCoveredGray(pool, zone, scale)
    local state = ns.ZoneState(zone).state
    local _, _, tileW, tileH = ns.ArtLayer(zone.map)
    for i, node in ipairs(zone.nodes) do
        if state[i] ~= true and node.files and #node.files > 0 then
            ns.EachTile(node.ox, node.oy, node.tw, node.th, node.files, tileW, tileH,
                function(file, x, y, w, h, u, v)
                    local t = pool:Next()
                    t:SetTexture(file)
                    t:SetTexCoord(0, u, 0, v)
                    t:SetSize(w * scale, h * scale)
                    t:ClearAllPoints()
                    t:SetPoint("TOPLEFT", x * scale, -y * scale)
                    if t.SetDesaturated then t:SetDesaturated(true) end
                    t:SetVertexColor(0.75, 0.75, 0.75, 0.9)
                end)
        end
    end
end
