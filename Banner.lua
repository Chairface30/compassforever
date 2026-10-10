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

-- "Head northwest to Raven Hill, 420 yd", or just the name when the player
-- cannot be placed.
function ns.NextStopText()
    local stop = ns.CurrentStop()
    if not stop then return nil end
    local bearing, yards = ns.StopVector(ns.route.zone, stop)
    if bearing then
        return string.format("Head %s to |cffffd100%s|r, %s", ns.Compass(bearing), stop.node.name, ns.Yards(yards))
    end
    return "Next: |cffffd100" .. stop.node.name .. "|r"
end

-- A zone finished: Sounds\fanfare.ogg, the Final Fantasy VII victory
-- fanfare. Anyone can put their own clip there instead. If the file is
-- missing the client says it will not play, and the game's level-up
-- fanfare plays.
local FANFARE = "Interface\\AddOns\\" .. ns.addonName .. "\\Sounds\\fanfare.ogg"
function ns.Fanfare()
    local ok, willPlay = pcall(PlaySoundFile, FANFARE, "Master")
    if ok and willPlay then return end
    pcall(PlaySound, 888)
end

ns.On("uncovered", function(zone, found)
    local names = {}
    for _, node in ipairs(found) do names[#names + 1] = node.name end
    local head = "Uncovered " .. table.concat(names, ", ")
    if not ns.route then
        ns.Banner(head, "|cff55dd55" .. zone.name .. " is fully explored!|r")
        ns.Print("|cff55dd55" .. zone.name .. " is fully explored.|r")
        ns.Fanfare()
        return
    end
    local left = #ns.route.stops
    ns.Banner(head, string.format("%d left. %s", left, ns.NextStopText() or ""))
end)
