-- Chair Legacy: UI.lua
-- The main window. Categories down the left (the six Legacy categories plus
-- Exploration), and on the right every challenge in the chosen one with its
-- steps ticked off, a box to track it, and, for exploration, every zone with
-- its map areas and a button to walk the route.

local _, ns = ...

local WIDTH, HEIGHT = 760, 500
local ROW = 18
local GREEN, GRAY, WHITE, GOLD, RED = "|cff55dd55", "|cff888888", "|cffffffff", "|cffffd100", "|cffff6666"

local frame, list, content, catButtons, summary
local rows, used = {}, 0
local selected = "overview"
local openZones = {}      -- achievement ID -> true: zone expanded

-------------------------------------------------------------------------------
-- Rows: one pool of lines, each with optional check box and button.
-------------------------------------------------------------------------------

local function Row()
    used = used + 1
    local r = rows[used]
    if not r then
        r = CreateFrame("Frame", nil, content)
        r:SetHeight(ROW)
        r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        r.text:SetJustifyH("LEFT")
        r.text:SetWordWrap(false)
        r.check = CreateFrame("CheckButton", nil, r, "UICheckButtonTemplate")
        r.check:SetSize(20, 20)
        r.check:SetPoint("RIGHT", -2, 0)
        r.button = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
        r.button:SetSize(70, 18)
        r.click = CreateFrame("Button", nil, r)
        r.click:SetAllPoints(r.text)
        rows[used] = r
    end
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(used - 1) * ROW)
    r:SetPoint("RIGHT", content, "RIGHT")
    r.text:ClearAllPoints()
    r.text:SetPoint("LEFT", 4, 0)
    r.text:SetPoint("RIGHT", -100, 0)
    r.text:SetFontObject("GameFontHighlight")
    r.check:Hide()
    r.check:SetScript("OnClick", nil)
    r.button:Hide()
    r.button:ClearAllPoints()
    r.button:SetScript("OnClick", nil)
    r.click:SetScript("OnClick", nil)
    r.click:SetScript("OnEnter", nil)
    r.click:SetScript("OnLeave", nil)
    r:Show()
    return r
end

local function Line(text, indent, font)
    local r = Row()
    r.text:SetPoint("LEFT", 4 + (indent or 0) * 16, 0)
    if font then r.text:SetFontObject(font) end
    r.text:SetText(text)
    return r
end

local function TrackBox(r, id)
    r.check:Show()
    r.check:SetChecked(ns.db.tracked[id] and true or false)
    r.check:SetScript("OnClick", function(self)
        ns.SetTracked(id, self:GetChecked())
    end)
end

local function Mark(done)
    if done == true then return GREEN .. "[x]|r " end
    if done == false then return GRAY .. "[  ]|r " end
    return GRAY .. "[?]|r "
end

local function Count(done, total, unknown)
    local color = done == total and GREEN or (done > 0 and GOLD or WHITE)
    local s = color .. done .. "/" .. total .. "|r"
    if unknown and unknown > 0 then s = s .. GRAY .. " (" .. unknown .. " unknown)|r" end
    return s
end

-------------------------------------------------------------------------------
-- Pages
-------------------------------------------------------------------------------

local function ChallengePage(category)
    for _, def in ipairs(ns.ChallengeList()) do
        if def.category == category then
            local c = ns.Challenge(def)
            local r = Line(Mark(c.done) .. (c.done and GREEN or WHITE) .. c.name .. "|r", 0, "GameFontNormal")
            TrackBox(r, def.id)
            r.click:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:AddLine(c.name, 1, 1, 1)
                if c.text and c.text ~= "" then GameTooltip:AddLine(c.text, 1, 0.82, 0, true) end
                GameTooltip:Show()
            end)
            r.click:SetScript("OnLeave", function() GameTooltip:Hide() end)
            if c.text and c.text ~= "" then Line(GRAY .. c.text .. "|r", 1, "GameFontHighlightSmall") end
            -- Steps, unless the one step just repeats the challenge.
            if #c.steps > 1 or (c.steps[1] and c.steps[1].name ~= c.name) then
                for _, step in ipairs(c.steps) do
                    local qty = ""
                    if step.req and step.req > 1 and step.qty then
                        qty = GRAY .. "  " .. step.qty .. "/" .. step.req .. "|r"
                    end
                    Line(Mark(step.done) .. (step.done and GRAY or WHITE) .. step.name .. "|r" .. qty, 1,
                        "GameFontHighlightSmall")
                end
            end
            -- The Explorer challenge points at the exploration page.
            if def.sub == 15607 then
                local r2 = Line(GOLD .. "Every zone map, area by area, is on the Exploration page.|r", 1,
                    "GameFontHighlightSmall")
                r2.button:Show()
                r2.button:SetPoint("RIGHT", -2, 0)
                r2.button:SetText("Open")
                r2.button:SetScript("OnClick", function() ns.SelectPage("explore") end)
            end
        end
    end
end

local function ZoneRows(zone)
    local done, total, unknown = ns.ZoneCounts(zone)
    local open = openZones[zone.ach]
    local r = Line((open and "- " or "+ ") .. (done == total and GREEN or WHITE) .. zone.name .. "|r  "
        .. Count(done, total, unknown), 0, "GameFontNormal")
    r.click:SetScript("OnClick", function()
        openZones[zone.ach] = not openZones[zone.ach]
        ns.RefreshWindow()
    end)
    TrackBox(r, zone.ach)
    if done < total then
        r.button:Show()
        r.button:SetPoint("RIGHT", r.check, "LEFT", -4, 0)
        local active = ns.route and ns.route.zone == zone
        r.button:SetText(active and "Stop" or "Route")
        r.button:SetScript("OnClick", function()
            if ns.route and ns.route.zone == zone then ns.StopRoute() else ns.StartRoute(zone) end
            ns.RefreshWindow()
        end)
    end
    if not open then return end
    local state = ns.ZoneState(zone).state
    -- In route order while this zone is being walked, else the client's order.
    local order = {}
    if ns.route and ns.route.zone == zone then
        local inRoute = {}
        for i, stop in ipairs(ns.route.stops) do
            inRoute[stop.node] = i
            order[#order + 1] = stop.node
        end
        for _, node in ipairs(zone.nodes) do
            if not inRoute[node] then order[#order + 1] = node end
        end
    else
        order = zone.nodes
    end
    local index = {}
    for i, node in ipairs(zone.nodes) do index[node] = i end
    for _, node in ipairs(order) do
        local s = state[index[node]]
        local p = ns.NodePoints(node)[1]
        local where = string.format("%s%.1f, %.1f|r", GRAY, p[1] * 100, p[2] * 100)
        local rough = node.rough and (RED .. " (approximate)|r") or ""
        Line(Mark(s) .. (s and GRAY or WHITE) .. node.name .. "|r  " .. where .. rough, 1, "GameFontHighlightSmall")
    end
end

local function ExplorePage()
    if not ns.HasAchievementAPI() then
        Line(GOLD .. "This client's achievement functions are missing; areas are read from the map instead.|r",
            0, "GameFontHighlightSmall")
    end
    local lastContinent
    for _, zone in ipairs(ns.ZONES) do
        if zone.continent ~= lastContinent then
            lastContinent = zone.continent
            Line(GOLD .. (zone.continent == 0 and "Eastern Kingdoms" or "Kalimdor") .. "|r", 0, "GameFontNormalLarge")
        end
        ZoneRows(zone)
    end
end

local function OverviewPage()
    local done, total, unknown = ns.ChallengeCounts()
    Line(WHITE .. "Legacy challenges: |r" .. Count(done, total, unknown), 0, "GameFontNormalLarge")
    Line(GRAY .. "Each challenge is worth one Legacy point for the whole account.|r", 0, "GameFontHighlightSmall")
    Line(" ")
    for _, cat in ipairs(ns.CHALLENGE_CATEGORIES) do
        local d, t, u = ns.ChallengeCounts(cat.id)
        local r = Line(WHITE .. cat.name .. "|r  " .. Count(d, t, u), 0, "GameFontNormal")
        r.click:SetScript("OnClick", function() ns.SelectPage(cat.id) end)
    end
    Line(" ")
    local zd, zt = 0, #ns.ZONES
    local ad, at = 0, 0
    for _, zone in ipairs(ns.ZONES) do
        local d, t = ns.ZoneCounts(zone)
        ad, at = ad + d, at + t
        if d == t then zd = zd + 1 end
    end
    local r = Line(WHITE .. "Exploration (this character): |r" .. Count(zd, zt) .. " zones, "
        .. Count(ad, at) .. " map areas", 0, "GameFontNormal")
    r.click:SetScript("OnClick", function() ns.SelectPage("explore") end)
    Line(GRAY .. "Every zone map of both continents on one character earns the Explorer challenge.|r", 0,
        "GameFontHighlightSmall")
    local tracked = 0
    for _ in pairs(ns.db.tracked) do tracked = tracked + 1 end
    Line(" ")
    Line(GRAY .. "Tick the box beside any challenge or zone to follow it in the tracker ("
        .. tracked .. " tracked).|r", 0, "GameFontHighlightSmall")
end

-------------------------------------------------------------------------------
-- The window
-------------------------------------------------------------------------------

local PAGES

function ns.RefreshWindow()
    if not frame or not frame:IsShown() then return end
    for i = 1, used do rows[i]:Hide() end
    used = 0
    for _, b in ipairs(catButtons) do
        b:SetEnabled(b.page ~= selected)
        local label = b.label
        if type(b.page) == "number" then
            local d, t = ns.ChallengeCounts(b.page)
            label = label .. " " .. d .. "/" .. t
        end
        b:SetText(label)
    end
    local ok, err = pcall(PAGES[selected] or OverviewPage)
    if not ok then Line(RED .. "Could not draw this page: " .. tostring(err) .. "|r") end
    content:SetHeight(math.max(1, used * ROW))
    local d, t, u = ns.ChallengeCounts()
    summary:SetText("Legacy points earned: " .. Count(d, t, u))
end

function ns.SelectPage(page)
    selected = page
    if list and list.SetVerticalScroll then list:SetVerticalScroll(0) end
    ns.RefreshWindow()
end

local function Build()
    if frame then return end
    frame = CreateFrame("Frame", "ChairLegacyFrame", UIParent, "BackdropTemplate")
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        ns.SavePoint(self, ns.db.window)
    end)
    if frame.SetBackdrop then
        frame:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 8, right = 8, top = 8, bottom = 8 },
        })
    end
    tinsert(UISpecialFrames, "ChairLegacyFrame")

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16)
    title:SetText(ns.title)
    summary = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    summary:SetPoint("TOPLEFT", 20, -20)

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)

    catButtons = {}
    local pages = { { "overview", "Overview" } }
    for _, cat in ipairs(ns.CHALLENGE_CATEGORIES) do pages[#pages + 1] = { cat.id, cat.name } end
    pages[#pages + 1] = { "explore", "Exploration" }
    for i, p in ipairs(pages) do
        local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        b:SetSize(160, 24)
        b:SetPoint("TOPLEFT", 18, -46 - (i - 1) * 28)
        b.page, b.label = p[1], p[2]
        b:SetText(p[2])
        b:SetScript("OnClick", function() ns.SelectPage(p[1]) end)
        catButtons[#catButtons + 1] = b
    end

    local trackerToggle = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    trackerToggle:SetPoint("BOTTOMLEFT", 16, 40)
    trackerToggle:SetChecked(ns.db.trackerShown)
    trackerToggle:SetScript("OnClick", function(self) ns.SetTrackerShown(self:GetChecked()) end)
    local tl = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    tl:SetPoint("LEFT", trackerToggle, "RIGHT", 2, 0)
    tl:SetText("Show the tracker")

    local pinToggle = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    pinToggle:SetPoint("BOTTOMLEFT", 16, 16)
    pinToggle:SetChecked(ns.db.mapPins)
    pinToggle:SetScript("OnClick", function(self)
        ns.db.mapPins = self:GetChecked() and true or false
        ns.Fire("route")
    end)
    local pl = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    pl:SetPoint("LEFT", pinToggle, "RIGHT", 2, 0)
    pl:SetText("Areas on the world map")

    list = CreateFrame("ScrollFrame", "ChairLegacyList", frame, "UIPanelScrollFrameTemplate")
    list:SetPoint("TOPLEFT", 190, -46)
    list:SetPoint("BOTTOMRIGHT", -34, 18)
    content = CreateFrame("Frame", nil, list)
    content:SetSize(WIDTH - 230, 1)
    list:SetScrollChild(content)

    PAGES = { overview = OverviewPage, explore = ExplorePage }
    for _, cat in ipairs(ns.CHALLENGE_CATEGORIES) do
        PAGES[cat.id] = function() ChallengePage(cat.id) end
    end

    frame:SetScript("OnShow", function() ns.RefreshWindow() end)
    ns.RestorePoint(frame, ns.db.window, "CENTER", "CENTER", 0, 0)
end

function ns.ToggleWindow(page)
    Build()
    if page then selected = page end
    if frame:IsShown() and not page then frame:Hide() else frame:Show() ns.RefreshWindow() end
end

ns.On("progress", function() ns.RefreshWindow() end)
ns.On("route", function() ns.RefreshWindow() end)
