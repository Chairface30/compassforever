-- Compass Forever: Share.lua
-- Route editing shared between players: a player's own walls, roads and
-- spots (CompassForeverDB) written out as one line of text, copied, sent to a
-- friend any way they like, and read back in on their side.
--
-- The text: "CF1:" zones ":" checksum, with zones split by "|", each
-- ach/walls/roads/spots/zone lines (the last left off when there are none). Walls and roads split by "_", their numbers by ".";
-- a circle starts with "o" (middle x, y and its radius in yards). Spots are
-- criteria.x.y, split by "_". Fractions are whole ten-thousandths; every
-- number is in base 36.

local _, ns = ...

local PREFIX = "CF1"
local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"

local function B36(n)
    n = math.floor(n + 0.5)
    local neg = n < 0
    if neg then n = -n end
    local out = ""
    repeat
        local d = n % 36
        out = DIGITS:sub(d + 1, d + 1) .. out
        n = (n - d) / 36
    until n == 0
    return (neg and "-" or "") .. out
end

local function Num36(s)
    if not s or s == "" then return nil end
    local neg = s:sub(1, 1) == "-"
    local v = tonumber(neg and s:sub(2) or s, 36)
    if not v then return nil end
    return neg and -v or v
end

local function Frac(v) return B36(v * 10000) end

local function Checksum(s)
    local sum = 0
    for i = 1, #s do sum = (sum * 31 + s:byte(i)) % 1679616 end   -- 36^4
    return B36(sum)
end

local function Split(s, sep)
    local out = {}
    if s == "" then return out end
    for part in (s .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do out[#out + 1] = part end
    return out
end

-------------------------------------------------------------------------------
-- Writing
-------------------------------------------------------------------------------

local function LineText(line)
    if line.circle then
        local c = line.circle
        return "o" .. Frac(c[1]) .. "." .. Frac(c[2]) .. "." .. B36(c[3])
    end
    local nums = {}
    for i, v in ipairs(line) do nums[i] = Frac(v) end
    return table.concat(nums, ".")
end

local function LinesText(lines)
    local out = {}
    for i, line in ipairs(lines or {}) do out[i] = LineText(line) end
    return table.concat(out, "_")
end

-- What a zone of the player's own holds: walls, roads, spots (counts).
function ns.OwnEditCounts(zone)
    local db = ns.db
    local w = db.walls and db.walls[zone.ach]
    local r = db.roads and db.roads[zone.ach]
    local z = db.zonelines and db.zonelines[zone.ach]
    local s = 0
    for _, node in ipairs(zone.nodes) do
        if node.criteria and db.spots and db.spots[node.criteria] then s = s + 1 end
    end
    return w and #w or 0, r and #r or 0, s, z and #z or 0
end

-- The share text for the zones given (all with edits of the player's own
-- when nil), and how many zones went in.
function ns.ExportEdits(zones)
    local db = ns.db
    local parts = {}
    for _, zone in ipairs(zones or ns.ZONES) do
        local w, r, s, z = ns.OwnEditCounts(zone)
        if w + r + s + z > 0 then
            local spots = {}
            for _, node in ipairs(zone.nodes) do
                local xy = node.criteria and db.spots and db.spots[node.criteria]
                if xy then spots[#spots + 1] = B36(node.criteria) .. "." .. Frac(xy[1]) .. "." .. Frac(xy[2]) end
            end
            parts[#parts + 1] = B36(zone.ach) .. "/" .. LinesText(db.walls and db.walls[zone.ach])
                .. "/" .. LinesText(db.roads and db.roads[zone.ach]) .. "/" .. table.concat(spots, "_")
                .. (z > 0 and ("/" .. LinesText(db.zonelines[zone.ach])) or "")
        end
    end
    if #parts == 0 then return nil, 0 end
    local body = table.concat(parts, "|")
    return PREFIX .. ":" .. body .. ":" .. Checksum(body), #parts
end

-------------------------------------------------------------------------------
-- Reading
-------------------------------------------------------------------------------

local function ReadLine(text)
    local circle = text:sub(1, 1) == "o"
    local nums = Split(circle and text:sub(2) or text, ".")
    if circle then
        local x, y, r = Num36(nums[1]), Num36(nums[2]), Num36(nums[3])
        if not (x and y and r) or #nums ~= 3 or r <= 0 then return nil end
        return { circle = { x / 10000, y / 10000, r } }
    end
    if #nums < 4 or #nums % 2 ~= 0 then return nil end
    local line = {}
    for i, s in ipairs(nums) do
        local v = Num36(s)
        if not v or v < -5000 or v > 15000 then return nil end
        line[i] = v / 10000
    end
    return line
end

local function ReadLines(text)
    local out = {}
    for _, part in ipairs(Split(text, "_")) do
        local line = ReadLine(part)
        if not line then return nil end
        out[#out + 1] = line
    end
    return out
end

-- Share text read back: { { zone, walls, roads, spots = { [criteria] = { x, y } } } ... },
-- or nil and what's wrong with it.
function ns.ParseEdits(text)
    text = (text or ""):gsub("%s+", "")
    local prefix, body, sum = text:match("^(CF%d+):(.*):(%w+)$")
    if not prefix then return nil, "That isn't Compass Forever share text." end
    if prefix ~= PREFIX then return nil, "That share text is from a newer Compass Forever." end
    if Checksum(body) ~= sum then return nil, "The text is cut short or changed: copy all of it again." end
    local out = {}
    for _, part in ipairs(Split(body, "|")) do
        local f = Split(part, "/")
        local zone = ns.ZoneByAch(Num36(f[1]) or -1)
        if not zone or (#f ~= 4 and #f ~= 5) then return nil, "The text names a zone this version doesn't know." end
        local walls, roads, zonelines = ReadLines(f[2]), ReadLines(f[3]), ReadLines(f[5] or "")
        if not (walls and roads and zonelines) then return nil, "A line in " .. zone.name .. " can't be read." end
        local crits = {}
        for _, node in ipairs(zone.nodes) do if node.criteria then crits[node.criteria] = true end end
        local spots, n = {}, 0
        for _, s in ipairs(Split(f[4], "_")) do
            local v = Split(s, ".")
            local c, x, y = Num36(v[1]), Num36(v[2]), Num36(v[3])
            if not (c and x and y and crits[c]) then return nil, "A spot in " .. zone.name .. " can't be read." end
            spots[c] = { x / 10000, y / 10000 }
            n = n + 1
        end
        out[#out + 1] = { zone = zone, walls = walls, roads = roads, zonelines = zonelines, spots = spots, spotCount = n }
    end
    return out
end

local function Same(a, b)
    if a.circle or b.circle then
        if not (a.circle and b.circle) then return false end
        a, b = a.circle, b.circle
    end
    if #a ~= #b then return false end
    for i = 1, #a do
        if math.abs(a[i] - b[i]) > 1e-6 then return false end
    end
    return true
end

-- Put read share text into the player's own edits. "add" keeps what they
-- have and adds what's new (a spot in both takes the shared one); "replace"
-- swaps each shared zone's walls, roads and spots for the shared ones.
function ns.ImportEdits(list, mode)
    local db = ns.db
    db.walls, db.roads, db.spots = db.walls or {}, db.roads or {}, db.spots or {}
    db.zonelines = db.zonelines or {}
    for _, z in ipairs(list) do
        local ach = z.zone.ach
        for _, kind in ipairs({ "walls", "roads", "zonelines" }) do
            local mine = mode == "replace" and {} or (db[kind][ach] or {})
            for _, line in ipairs(z[kind]) do
                local dup = false
                for _, have in ipairs(mine) do
                    if Same(have, line) then dup = true break end
                end
                if not dup then mine[#mine + 1] = line end
            end
            db[kind][ach] = #mine > 0 and mine or nil
        end
        if mode == "replace" then
            for _, node in ipairs(z.zone.nodes) do
                if node.criteria then db.spots[node.criteria] = nil end
            end
        end
        for crit, xy in pairs(z.spots) do db.spots[crit] = xy end
    end
    ns.WallsChanged()
    local r = ns.route
    if r then ns.StartRoute(r.zone, { quiet = true, skipped = r.skipped, auto = r.auto }) end
    ns.Fire("spots")
    ns.Fire("settings")
end

-- "Durotar: 3 walls, 2 roads, 4 spots" for each zone of read share text.
function ns.DescribeEdits(list)
    local out = {}
    for _, z in ipairs(list) do
        local zl = #(z.zonelines or {})
        out[#out + 1] = string.format("%s: %d wall%s, %d road%s, %d spot%s%s", z.zone.name,
            #z.walls, #z.walls == 1 and "" or "s", #z.roads, #z.roads == 1 and "" or "s",
            z.spotCount, z.spotCount == 1 and "" or "s",
            zl > 0 and string.format(", %d zone line%s", zl, zl == 1 and "" or "s") or "")
    end
    return table.concat(out, "\n")
end

-------------------------------------------------------------------------------
-- The Share window
-------------------------------------------------------------------------------

local win

local function Say(text, r, g, b)
    win.info:SetText(text)
    win.info:SetTextColor(r or 1, g or 0.82, b or 0)
end

-- Pasted or typed text: say what it holds, and allow taking it in.
local function Check()
    local text = win.edit:GetText() or ""
    win.parsed = nil
    win.add:Disable()
    win.replace:Disable()
    if text:gsub("%s+", "") == "" then
        Say("Paste share text here to use a friend's walls, roads and spots.", 0.8, 0.8, 0.8)
        return
    end
    local list, err = ns.ParseEdits(text)
    if not list then
        Say(err, 1, 0.4, 0.4)
        return
    end
    win.parsed = list
    win.add:Enable()
    win.replace:Enable()
    Say(ns.DescribeEdits(list), 0.4, 1, 0.4)
end

local function ShowText(text, count)
    win.exporting = true
    win.edit:SetText(text)
    win.exporting = false
    win.edit:SetFocus()
    win.edit:HighlightText()
    win.parsed = nil
    win.add:Disable()
    win.replace:Disable()
    Say(string.format("%d zone%s. Press Ctrl+C to copy, then send it to a friend (Discord, a forum...). "
        .. "They paste it here and click Add or Replace.", count, count == 1 and "" or "s"), 0.4, 1, 0.4)
end

local function Export(zones)
    local text, count = ns.ExportEdits(zones)
    if not text then
        win.edit:SetText("")
        Say(zones and "You haven't drawn or moved anything in this zone yet."
            or "You haven't drawn or moved anything yet.", 1, 0.4, 0.4)
        return
    end
    ShowText(text, count)
end

local function Button(text, width, onClick)
    local b = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

local function Build()
    if win then return end
    win = CreateFrame("Frame", "CompassForeverShare", UIParent, "BackdropTemplate")
    win:SetSize(470, 330)
    win:SetPoint("CENTER")
    win:SetFrameStrata("DIALOG")
    win:SetToplevel(true)
    win:SetClampedToScreen(true)
    win:SetMovable(true)
    win:EnableMouse(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", function(self) self:StartMoving() end)
    win:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    if win.SetBackdrop then
        win:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 14,
            insets = { left = 4, right = 4, top = 4, bottom = 4 } })
        win:SetBackdropColor(0.06, 0.05, 0.04, 0.97)
        win:SetBackdropBorderColor(0.8, 0.65, 0.3)
    end
    tinsert(UISpecialFrames, "CompassForeverShare")

    local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 14, -12)
    title:SetText("Share routes")
    local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)

    local about = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    about:SetPoint("TOPLEFT", 14, -36)
    about:SetWidth(442)
    about:SetJustifyH("LEFT")
    about:SetText("Your walls, roads and spots as text, to send to friends. Their routes then go your way.")

    win.zoneButton = Button("This zone", 90, function() if win.zone then Export({ win.zone }) end end)
    win.zoneButton:SetPoint("TOPLEFT", 12, -56)
    local all = Button("All zones", 90, function() Export(nil) end)
    all:SetPoint("LEFT", win.zoneButton, "RIGHT", 4, 0)

    local box = CreateFrame("Frame", nil, win, "BackdropTemplate")
    box:SetPoint("TOPLEFT", 12, -84)
    box:SetPoint("BOTTOMRIGHT", -12, 86)
    if box.SetBackdrop then
        box:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 10,
            insets = { left = 2, right = 2, top = 2, bottom = 2 } })
        box:SetBackdropColor(0, 0, 0, 0.6)
        box:SetBackdropBorderColor(0.5, 0.5, 0.5)
    end
    local scroll = CreateFrame("ScrollFrame", nil, box, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 6, -6)
    scroll:SetPoint("BOTTOMRIGHT", -26, 6)
    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetMaxLetters(0)
    edit:SetAutoFocus(false)
    edit:SetFontObject("ChatFontSmall")
    edit:SetWidth(410)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    edit:SetScript("OnTextChanged", function() if not win.exporting then Check() end end)
    scroll:SetScrollChild(edit)
    box:EnableMouse(true)
    box:SetScript("OnMouseDown", function() edit:SetFocus() end)
    win.edit = edit

    win.info = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    win.info:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 2, -6)
    win.info:SetWidth(442)
    win.info:SetJustifyH("LEFT")

    win.replace = Button("Replace mine", 110, function()
        if not win.parsed then return end
        ns.ImportEdits(win.parsed, "replace")
        Say("Done: those zones now use the shared walls, roads and spots.", 0.4, 1, 0.4)
        ns.Print("Shared edits taken in, replacing yours: " .. ns.DescribeEdits(win.parsed):gsub("\n", "; "))
    end)
    win.replace:SetPoint("BOTTOMRIGHT", -12, 12)
    win.add = Button("Add to mine", 110, function()
        if not win.parsed then return end
        ns.ImportEdits(win.parsed, "add")
        Say("Done: the shared walls, roads and spots were added to yours.", 0.4, 1, 0.4)
        ns.Print("Shared edits added: " .. ns.DescribeEdits(win.parsed):gsub("\n", "; "))
    end)
    win.add:SetPoint("RIGHT", win.replace, "LEFT", -4, 0)
    local clear = Button("Clear", 60, function() win.edit:SetText("") win.edit:SetFocus() end)
    clear:SetPoint("BOTTOMLEFT", 12, 12)
end

-- Open the Share window, ready to export `zone` (the zone the map shows).
function ns.ShowShare(zone)
    Build()
    win.zone = zone
    win.zoneButton:SetEnabled(zone and true or false)
    win:Show()
    if zone then Export({ zone }) else Check() end
end
