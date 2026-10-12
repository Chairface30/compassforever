-- Compass Forever: Banner.lua
-- Big words in the middle-top of the screen for the moments that matter: a
-- route starting on entering a zone, an area uncovered, a zone finished. Each
-- says where to run next, as a direction and a distance.

local _, ns = ...

local HOLD, FADE = 5, 1.5
local frame, title, line
local shownAt

local function Build()
    if frame then return end
    frame = CreateFrame("Frame", "CompassForeverBanner", UIParent)
    frame:SetSize(600, 60)
    frame:SetPoint("TOP", UIParent, "TOP", 0, -190)
    frame:SetFrameStrata("HIGH")
    title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    title:SetPoint("TOP")
    line = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    line:SetPoint("TOP", title, "BOTTOM", 0, -6)
    frame:SetScript("OnUpdate", function(self)
        local ok, now = pcall(GetTime)
        local age = (ok and now or 0) - (shownAt or 0)
        if age > HOLD + FADE then
            self:Hide()
        elseif age > HOLD then
            self:SetAlpha(1 - (age - HOLD) / FADE)
        end
    end)
end

function ns.Banner(head, sub)
    if not ns.db.banner then return end
    Build()
    title:SetText(head or "")
    line:SetText(sub or "")
    local ok, now = pcall(GetTime)
    shownAt = ok and now or 0
    frame:SetAlpha(1)
    frame:Show()
end

-- "Head northwest to Raven Hill, 420 yd" (the way the walking path starts,
-- and its length), the flight to take when flying is quicker, or just the
-- name when the player cannot be placed.
function ns.NextStopText()
    local stop = ns.CurrentStop()
    if not stop then return nil end
    if ns.travel and ns.TravelText then return ns.TravelText() end
    local bearing, yards = ns.StopVector(ns.route.zone, stop)
    if bearing then
        return string.format("Head %s to |cffffd100%s|r, %s", ns.Compass(bearing), stop.node.name, ns.Yards(yards))
    end
    return "Next: |cffffd100" .. stop.node.name .. "|r"
end

-- A zone finished: Sounds\fanfare.ogg (48 seconds). Anyone can put their
-- own clip there instead. If the file is missing the client says it will
-- not play, and the game's level-up fanfare plays. Off with the fanfare
-- option. While it plays, a speaker button stops it.
local FANFARE = "Interface\\AddOns\\" .. ns.addonName .. "\\Sounds\\fanfare.ogg"
local FANFARE_SECONDS = 48
local mute

local function MuteButton()
    if mute then return mute end
    mute = CreateFrame("Button", "CompassForeverFanfareMute", UIParent)
    mute:SetSize(140, 32)
    mute:SetFrameStrata("HIGH")
    -- it can be dragged anywhere, and stays there
    ns.db.mutePoint = ns.db.mutePoint or {}
    ns.RestorePoint(mute, ns.db.mutePoint, "TOP", "TOP", 0, -270)
    mute:SetMovable(true)
    mute:SetClampedToScreen(true)
    mute:RegisterForDrag("LeftButton")
    mute:SetScript("OnDragStart", function(self) self:StartMoving() end)
    mute:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        ns.SavePoint(self, ns.db.mutePoint)
        local ok, now = pcall(GetTime)
        self.droppedAt = ok and now or nil
    end)
    local bg = mute:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.6)
    local icon = mute:CreateTexture(nil, "ARTWORK")
    icon:SetSize(24, 24)
    icon:SetPoint("LEFT", 6, 0)
    icon:SetTexture("Interface\\Common\\VoiceChat-Speaker")
    local text = mute:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    text:SetText("Stop music")
    local hl = mute:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 0.82, 0, 0.2)
    mute:SetScript("OnClick", function(self)
        -- letting go after a drag isn't a click
        local ok, now = pcall(GetTime)
        if ok and self.droppedAt and now - self.droppedAt < 0.2 then return end
        if self.handle then pcall(StopSound, self.handle) end
        self:Hide()
    end)
    mute:SetScript("OnUpdate", function(self)
        local ok, now = pcall(GetTime)
        if ok and now - (self.started or 0) > FANFARE_SECONDS then self:Hide() end
    end)
    mute:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Stop the fanfare")
        GameTooltip:AddLine("Drag to move this button.", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("Turn it off for good in Options, Display.", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    mute:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return mute
end

function ns.Fanfare()
    if ns.db and ns.db.fanfare == false then return end
    local ok, willPlay, handle = pcall(PlaySoundFile, FANFARE, "Master")
    if ok and willPlay then
        local b = MuteButton()
        b.handle = handle
        local okT, now = pcall(GetTime)
        b.started = okT and now or 0
        b:Show()
        return
    end
    pcall(PlaySound, 888)
end

ns.On("uncovered", function(zone, found)
    local names, learned = {}, {}
    for _, node in ipairs(found) do
        if node.fp then
            learned[#learned + 1] = node.name:gsub("^Flight master: ", "")
        else
            names[#names + 1] = node.name
        end
    end
    local head = #names > 0 and ("Uncovered " .. table.concat(names, ", "))
        or ("Learned the flight point at " .. table.concat(learned, ", "))
    if not ns.route then
        local d, t = ns.ZoneCounts(zone)
        if d < t then
            -- a one-area route done, the zone not yet
            ns.Banner(head, string.format("%d left in %s.", t - d, zone.name))
            return
        end
        ns.Banner(head, "|cff55dd55" .. zone.name .. " is fully explored!|r")
        ns.Print("|cff55dd55" .. zone.name .. " is fully explored.|r")
        ns.Fanfare()
        return
    end
    local left = #ns.route.stops
    ns.Banner(head, string.format("%d left. %s", left, ns.NextStopText() or ""))
end)
