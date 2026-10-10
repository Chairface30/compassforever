-- Chair Legacy: Tracker.lua
-- A small list on screen of the challenges and zones the player ticked, each
-- with the steps still to do, and the route's next stop while one is walked.

local _, ns = ...

local MAX_STEPS = 6
local frame, text

local function Lines()
    local out = {}
    local stop, index = ns.CurrentStop()
    if stop then
        out[#out + 1] = "|cffffd100Route: " .. ns.route.zone.name .. "|r"
        out[#out + 1] = string.format("  Next: %s (%d of %d)", stop.node.name, index, #ns.route.stops)
    end
    -- Zones first, then challenges, each in the order the window lists them.
    for _, zone in ipairs(ns.ZONES) do
        if ns.db.tracked[zone.ach] then
            local done, total = ns.ZoneCounts(zone)
            out[#out + 1] = string.format("|cffffd100Explore %s|r %d/%d", zone.name, done, total)
            local left = ns.ZoneRemaining(zone)
            for i = 1, math.min(#left, MAX_STEPS) do out[#out + 1] = "  " .. left[i].name end
            if #left > MAX_STEPS then out[#out + 1] = "  |cff888888and " .. (#left - MAX_STEPS) .. " more|r" end
        end
    end
    for _, def in ipairs(ns.ChallengeList()) do
        if ns.db.tracked[def.id] then
            local c = ns.Challenge(def)
            if c.done then
                out[#out + 1] = "|cff55dd55" .. c.name .. " (done)|r"
            else
                out[#out + 1] = "|cffffd100" .. c.name .. "|r"
                local shown = 0
                for _, step in ipairs(c.steps) do
                    if step.done ~= true and shown < MAX_STEPS then
                        shown = shown + 1
                        local qty = (step.req and step.req > 1 and step.qty) and (" " .. step.qty .. "/" .. step.req) or ""
                        out[#out + 1] = "  " .. step.name .. qty
                    end
                end
                if #c.steps <= 1 and shown <= 1 and c.text and c.text ~= "" then
                    out[#out] = "  " .. c.text
                end
            end
        end
    end
    return out
end

local function Build()
    if frame then return end
    frame = CreateFrame("Frame", "ChairLegacyTracker", UIParent)
    frame:SetSize(260, 40)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        ns.SavePoint(self, ns.db.tracker)
    end)
    frame:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then ns.ToggleWindow() end
    end)
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT")
    title:SetText("Legacy")
    text = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    text:SetWidth(260)
    text:SetJustifyH("LEFT")
    text:SetSpacing(2)
    ns.RestorePoint(frame, ns.db.tracker, "RIGHT", "RIGHT", -60, 120)
end

function ns.RefreshTracker()
    local lines = Lines()
    if not ns.db.trackerShown or #lines == 0 then
        if frame then frame:Hide() end
        return
    end
    Build()
    text:SetText(table.concat(lines, "\n"))
    frame:SetHeight(20 + #lines * 14)
    frame:Show()
end

function ns.SetTracked(id, on)
    ns.db.tracked[id] = on and true or nil
    ns.RefreshTracker()
end

function ns.SetTrackerShown(on)
    ns.db.trackerShown = on and true or false
    ns.RefreshTracker()
end

ns.On("progress", ns.RefreshTracker)
ns.On("route", ns.RefreshTracker)
ns.On("login", ns.RefreshTracker)
