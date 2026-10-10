-- Chair Legacy: Minimap.lua
-- The minimap button (LibDBIcon), also a launcher for any LibDataBroker bar.
-- Click opens the window; right-click starts or stops this zone's route.

local _, ns = ...

local NAME = "ChairLegacy"
local ICON = "Interface\\Icons\\INV_Misc_Map_01"

local function Tooltip(tip)
    tip:AddLine(ns.title, 0.4, 0.8, 1)
    local ad, at, zd, zt = ns.Totals()
    tip:AddLine(string.format("Explored: %d/%d areas, %d/%d zones", ad, at, zd, zt), 1, 1, 1)
    local zone = ns.CurrentZone()
    if zone then
        local d, t = ns.ZoneCounts(zone)
        tip:AddLine(string.format("%s: %d/%d", zone.name, d, t), 0.8, 0.8, 0.8)
    end
    tip:AddLine("Automatic routes: " .. (ns.db.autoRoute and "on" or "off"), 0.8, 0.8, 0.8)
    local stop, i = ns.CurrentStop()
    if stop then
        tip:AddLine(string.format("Route: %s, stop %d of %d", ns.route.zone.name, i, #ns.route.stops), 1, 0.82, 0)
    end
    tip:AddLine(" ")
    tip:AddLine("Click: open", 0.7, 0.7, 0.7)
    tip:AddLine("Right-click: " .. (stop and "stop the route" or "route through this zone"), 0.7, 0.7, 0.7)
end

function ns.SetupMinimap()
    local stub = _G.LibStub
    local ldb = stub and stub("LibDataBroker-1.1", true)
    local icon = stub and stub("LibDBIcon-1.0", true)
    if not (ldb and icon) or ns.launcher then return end
    ns.launcher = ldb:NewDataObject(NAME, {
        type = "launcher",
        text = ns.title,
        icon = ICON,
        OnClick = function(_, button)
            if button == "RightButton" then
                if ns.route then ns.StopRoute() else SlashCmdList.CHAIRLEGACY("route") end
            else
                ns.ToggleWindow()
            end
        end,
        OnTooltipShow = Tooltip,
    })
    icon:Register(NAME, ns.launcher, ns.db.minimap)
end
