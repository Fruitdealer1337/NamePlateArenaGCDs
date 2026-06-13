local addonName, addon = ...

local instantCastBuffsTable = addon.instantCastBuffsTable or {}
local hasteBuffsTable = addon.hasteBuffsTable or {}
local spellTable = addon.spellTable or {}

local floor = math.floor
local GetTime = GetTime
local UnitClass = UnitClass
local UnitAura = UnitAura
local UnitName = UnitName
local UnitGUID = UnitGUID
local UnitExists = UnitExists
local UnitCastingInfo = UnitCastingInfo
local UnitChannelInfo = UnitChannelInfo
local GetSpellInfo = GetSpellInfo
local WorldFrame = WorldFrame

local ADDON_PREFIX = "|cff00ffccNP Arena GCDs|r: "

local defaultConfig = {
    enabled = true,
    iconSize = 27,
    offsetX = 116,
    offsetY = 0,
    scanInterval = 0.05,
    updateInterval = 0.03,
    cooldownSwipeAlpha = 1.0,
    enableCooldownReverse = false,
    hideSweepAnimation = false,
    showCountdownText = true,
    iconZoom = 8,
    fontSize = 11,
    testMode = false,
    plateGrace = 0.35,
}

local arenaUnits = { "arena1", "arena2", "arena3", "arena4", "arena5" }
local trackedUnits = { "arena1", "arena2", "arena3", "arena4", "arena5", "test" }
local unitClasses = {}
local gcdState = {}
local displayFrames = {}
local nameplateByArenaUnit = {}
local nameplateAnchorByArenaUnit = {}
local plateLastSeen = {}
local nameToArenaUnit = {}
local gcdSerial = 0
local pendingClears = {}
local observedCasts = {}

local scannerFrame = CreateFrame("Frame", "NamePlateArenaGCDsScanner", UIParent)
local eventFrame = CreateFrame("Frame", "NamePlateArenaGCDsEvents", UIParent)

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage(ADDON_PREFIX .. tostring(msg))
end

local function CopyDefaults(src, dst)
    if not dst then dst = {} end
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            CopyDefaults(v, dst[k])
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
    return dst
end

local function InitConfig()
    NamePlateArenaGCDsDB = CopyDefaults(defaultConfig, NamePlateArenaGCDsDB or {})
end

local function ClearUnitClasses()
    for _, unit in ipairs(arenaUnits) do
        unitClasses[unit] = nil
    end
end

local function GetUnitClassName(unitId)
    if unitClasses[unitId] then
        return unitClasses[unitId]
    end

    local localizedClass = UnitClass(unitId)
    unitClasses[unitId] = localizedClass or ""
    return unitClasses[unitId]
end

local function DetermineGCD(unitClass, spellName, unitId)
    if unitClass == "Hunter" then
        if spellName == "Readiness" then return 1.0 end
        return 1.5
    end

    if unitClass == "Shaman" then
        if spellName == "Lava Lash" or spellName == "Stormstrike" then return 1.5 end
    end

    if unitClass == "Warrior" then
        if spellName == "Overpower" or spellName == "Revenge" then return 1.0 end
        return 1.5
    end

    if unitClass == "Rogue" then return 1.0 end

    if unitClass == "Druid" and hasteBuffsTable["Druid"] and hasteBuffsTable["Druid"]["Cat Form"] and hasteBuffsTable["Druid"]["Cat Form"][unitId] then
        return 1.0
    end

    if unitClass == "Warlock" and spellName == "Shadowfury" then return 0.5 end

    if unitClass == "Paladin" then
        if spellName:match("^Judgement") or spellName == "Shield of Righteousness" then return 1.5 end
    end

    if hasteBuffsTable["Heroism"] and hasteBuffsTable["Heroism"][unitId] then
        return 1.0
    end

    local hasteBuffs = hasteBuffsTable[unitClass]
    if hasteBuffs then
        for buffName, buffData in pairs(hasteBuffs) do
            if type(buffData) == "table" and buffData.spells then
                if buffData.spells[spellName] and buffData[unitId] then
                    return 1.0
                end
            elseif type(buffData) == "table" and buffData[unitId] then
                if unitClass == "Paladin" then return 1.2 end
                return 1.0
            end
        end
    end

    if unitClass == "Death Knight" then return 1.5 end

    return 1.3
end

local function ApplyIconZoom(f)
    if not f or not f.icon then return end

    local cfg = NamePlateArenaGCDsDB or defaultConfig
    local zoom = tonumber(cfg.iconZoom) or 0
    if zoom < 0 then zoom = 0 end
    if zoom > 45 then zoom = 45 end

    local crop = zoom / 100
    f.icon:SetTexCoord(crop, 1 - crop, crop, 1 - crop)
end

local function CreateDisplayFrame(unitId, index)
    local cfg = NamePlateArenaGCDsDB
    local f = CreateFrame("Frame", "NamePlateArenaGCDsFrame" .. index, UIParent)
    f:SetSize(cfg.iconSize, cfg.iconSize)
    f:SetFrameStrata("HIGH")
    f:Hide()

    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints(f)
    icon:SetTexture("Interface\\Icons\\Spell_Nature_StarFall")
    f.icon = icon
    ApplyIconZoom(f)

    local customSweep = f:CreateTexture(nil, "OVERLAY")
    customSweep:SetAllPoints(f)
    customSweep:SetTexture("Interface\\AddOns\\NamePlateArenaGCDs\\media\\Auras\\swipe")
    customSweep:SetTexCoord(1, 0.875, 0.875, 1)
    customSweep:SetAlpha(cfg.cooldownSwipeAlpha)
    f.customSweep = customSweep

    local text = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    text:SetPoint("CENTER", f, "CENTER", 0, 0)
    text:SetFont("Fonts\\FRIZQT__.TTF", cfg.fontSize)
    text:SetTextColor(1, 1, 1, 1)
    f.text = text

    displayFrames[unitId] = f
    return f
end

local function ApplyDisplayConfig()
    local cfg = NamePlateArenaGCDsDB
    for unitId, f in pairs(displayFrames) do
        f:SetSize(cfg.iconSize, cfg.iconSize)
        f:SetFrameStrata("HIGH")
        ApplyIconZoom(f)

        if f.customSweep then
            f.customSweep:SetAlpha(cfg.cooldownSwipeAlpha)
            if cfg.hideSweepAnimation then
                f.customSweep:Hide()
            else
                f.customSweep:Show()
            end
        end

        f.text:SetFont("Fonts\\FRIZQT__.TTF", cfg.fontSize)

        f.anchorPlate = nil
        f.anchorAnchor = nil
        f.anchorX = nil
        f.anchorY = nil
    end
end


local function NextSerial()
    gcdSerial = gcdSerial + 1
    return gcdSerial
end

local function ClearGCD(unitId, serial)
    local state = gcdState[unitId]
    if serial and state and state.serial ~= serial then return end

    gcdState[unitId] = nil
    pendingClears[unitId] = nil

    local f = displayFrames[unitId]
    if f then
        f:Hide()
        f.anchorPlate = nil
        f.anchorAnchor = nil
    end
end

local function ResolveSpellInfo(unitId, spellName, spellId, allowFallback, fallbackIcon)
    if not spellName or not UnitExists(unitId) then return nil end

    local unitClass = GetUnitClassName(unitId)
    local classSpells = spellTable[unitClass]
    local spellData = classSpells and classSpells[spellName]

    if spellData then
        return unitClass, spellData.icon, spellData
    end

    if not allowFallback then return nil end

    local name, _, icon = GetSpellInfo(spellId or spellName)
    if not name and spellName then
        name, _, icon = GetSpellInfo(spellName)
    end

    icon = icon or fallbackIcon
    if not icon then return nil end
    return unitClass, icon, nil
end

local function GetLiveCastInfo(unitId, source)
    if source == "CHANNEL_START" then
        local name, _, _, icon = UnitChannelInfo(unitId)
        return name, icon
    end

    local name, _, _, icon = UnitCastingInfo(unitId)
    return name, icon
end

local function MarkObservedCast(unitId, spellName)
    if not spellName then return end
    observedCasts[unitId] = observedCasts[unitId] or {}
    observedCasts[unitId][spellName] = GetTime()
end

local function WasRecentlyObservedCast(unitId, spellName)
    local unitCasts = observedCasts[unitId]
    local t = unitCasts and spellName and unitCasts[spellName]
    return t and (GetTime() - t) < 10
end

local function ConfirmGCD(unitId, serial)
    local state = gcdState[unitId]
    if not state then return end
    if serial and state.serial ~= serial then return end

    state.tentative = false
    state.interrupted = true
    pendingClears[unitId] = nil
end

local function RequestPendingClear(unitId)
    local state = gcdState[unitId]
    if not state or not state.tentative then return end
    pendingClears[unitId] = { serial = state.serial }
end

local function ProcessPendingClears()
    for unitId, request in pairs(pendingClears) do
        local state = gcdState[unitId]
        if not state or state.serial ~= request.serial then
            pendingClears[unitId] = nil
        elseif state.tentative and not state.interrupted then
            ClearGCD(unitId, request.serial)
        else
            pendingClears[unitId] = nil
        end
    end
end

local function StartGCD(unitId, spellName, icon, duration, tentative, source)
    local now = GetTime()
    local name = UnitName(unitId)

    pendingClears[unitId] = nil
    gcdState[unitId] = {
        name = name,
        guid = UnitGUID(unitId),
        spellName = spellName,
        icon = icon,
        start = now,
        duration = duration,
        expiration = now + duration,
        serial = NextSerial(),
        tentative = tentative and true or false,
        source = source or "SUCCEEDED",
        interrupted = false,
    }

    local f = displayFrames[unitId]
    if f then
        f.icon:SetTexture(icon)
        ApplyIconZoom(f)
        if f.customSweep then
            f.customSweep:SetTexture("Interface\\AddOns\\NamePlateArenaGCDs\\media\\Auras\\swipe")
            f.customSweep:SetTexCoord(1, 0.875, 0.875, 1)
            f.lastSweepFrame = nil
        end
    end
end

local function StartNamedGCD(unitId, displayName, spellName, icon, duration)
    local now = GetTime()

    pendingClears[unitId] = nil
    gcdState[unitId] = {
        name = displayName,
        guid = nil,
        spellName = spellName,
        icon = icon,
        start = now,
        duration = duration,
        expiration = now + duration,
        serial = NextSerial(),
        tentative = false,
        source = "TEST",
        interrupted = false,
    }

    local f = displayFrames[unitId]
    if f then
        f.icon:SetTexture(icon)
        ApplyIconZoom(f)
        if f.customSweep then
            f.customSweep:SetTexture("Interface\\AddOns\\NamePlateArenaGCDs\\media\\Auras\\swipe")
            f.customSweep:SetTexCoord(1, 0.875, 0.875, 1)
            f.lastSweepFrame = nil
        end
    end
end

local function DetectInstantProcs(unitClass, unitId)
    local classBuffs = instantCastBuffsTable[unitClass]
    if not classBuffs then return end

    for buffName, arenaUnitsForBuff in pairs(classBuffs) do
        local auraName, _, _, stackCount, _, buffDuration = UnitAura(unitId, buffName)

        if unitClass == "Shaman" then
            if auraName == "Maelstrom Weapon" then
                arenaUnitsForBuff[unitId] = (stackCount == 5) and true or false
                break
            elseif auraName == "Elemental Mastery" then
                arenaUnitsForBuff[unitId] = (buffDuration == 30) and true or false
                break
            end
        end

        arenaUnitsForBuff[unitId] = auraName and true or false
        if arenaUnitsForBuff[unitId] then break end
    end
end

local function DetectHasteProcs(unitClass, unitId)
    if not hasteBuffsTable["Heroism"] then return end

    local hasHeroBuff = UnitAura(unitId, "Heroism") or UnitAura(unitId, "Bloodlust")
    hasteBuffsTable["Heroism"][unitId] = hasHeroBuff and true or false
    if hasHeroBuff then return end

    local classBuffs = hasteBuffsTable[unitClass]
    if not classBuffs then return end

    for buffName, arenaUnitsForBuff in pairs(classBuffs) do
        local auraName = UnitAura(unitId, buffName)
        arenaUnitsForBuff[unitId] = auraName and true or false
        if arenaUnitsForBuff[unitId] then break end
    end
end

local function OnUnitAura(unitId)
    if not UnitExists(unitId) then return end
    local unitClass = GetUnitClassName(unitId)
    if unitClass == "" then return end
    DetectInstantProcs(unitClass, unitId)
    DetectHasteProcs(unitClass, unitId)
end


local function OnSpellCastStart(unitId, spellName, spellRank, lineId, spellId, source)
    if not UnitExists(unitId) then return end

    local liveName, liveIcon = GetLiveCastInfo(unitId, source)
    spellName = spellName or liveName
    if not spellName then return end

    local unitClass, icon = ResolveSpellInfo(unitId, spellName, spellId, true, liveIcon)
    if not icon and liveName and liveName ~= spellName then
        unitClass, icon = ResolveSpellInfo(unitId, liveName, spellId, true, liveIcon)
        spellName = icon and liveName or spellName
    end
    if not icon then return end

    MarkObservedCast(unitId, spellName)
    StartGCD(unitId, spellName, icon, DetermineGCD(unitClass, spellName, unitId), true, source)
end

local function OnSpellCastFailed(unitId, spellName)
    local state = gcdState[unitId]
    if state and state.tentative and (not spellName or state.spellName == spellName) and not state.interrupted then
        ClearGCD(unitId, state.serial)
    end
end

local function OnSpellCastStop(unitId, spellName)
    local state = gcdState[unitId]
    if state and state.tentative and (not spellName or state.spellName == spellName) then
        RequestPendingClear(unitId)
    end
end

local function OnSpellInterrupted(destGUID)
    if not destGUID then return end

    for _, unitId in ipairs(arenaUnits) do
        if UnitExists(unitId) and UnitGUID(unitId) == destGUID then
            local state = gcdState[unitId]
            if state and state.tentative then
                ConfirmGCD(unitId, state.serial)
            end
            return
        end
    end
end

local function OnSpellCastSucceeded(unitId, spellName, spellRank, lineId, spellId)
    if not spellName or not UnitExists(unitId) then return end

    local state = gcdState[unitId]
    if state and state.tentative and state.spellName == spellName then
        ConfirmGCD(unitId, state.serial)
        return
    end

    if WasRecentlyObservedCast(unitId, spellName) then
        return
    end

    local unitClass = GetUnitClassName(unitId)
    local classSpells = spellTable[unitClass]
    if not classSpells then return end

    local spellData = classSpells[spellName]
    if not spellData then return end

    local isInstantCast = false
    local classInstantBuffs = instantCastBuffsTable[unitClass]
    if classInstantBuffs then
        for buffName, data in pairs(classInstantBuffs) do
            if data.spells and data.spells[spellName] and data[unitId] then
                isInstantCast = true
                break
            end
        end
    end

    local castTime = spellData.castTime or 0
    if isInstantCast then castTime = 0 end
    if castTime > 0 then return end

    StartGCD(unitId, spellName, spellData.icon, DetermineGCD(unitClass, spellName, unitId), false, "SUCCEEDED")
end

local function RebuildArenaNameMap()
    wipe(nameToArenaUnit)
    for _, unitId in ipairs(arenaUnits) do
        if UnitExists(unitId) then
            local name = UnitName(unitId)
            if name and name ~= "" then
                nameToArenaUnit[name] = unitId
            end
        end
    end

    local testState = gcdState and gcdState.test
    if testState and testState.name and testState.name ~= "" and testState.expiration and testState.expiration > GetTime() then
        nameToArenaUnit[testState.name] = "test"
    end
end

local function TextMatchesArenaName(text)
    if not text or text == "" then return nil end

    if nameToArenaUnit[text] then
        return nameToArenaUnit[text]
    end

    for name, unitId in pairs(nameToArenaUnit) do
        if text == name then
            return unitId
        end
        if string.find(text, name, 1, true) == 1 then
            local nextChar = string.sub(text, string.len(name) + 1, string.len(name) + 1)
            if nextChar == "" or nextChar == "-" or nextChar == " " then
                return unitId
            end
        end
    end

    return nil
end

local function IsUsableWorldChild(frame)
    if not frame or not frame:IsShown() then return false end

    local w = frame:GetWidth() or 0
    local h = frame:GetHeight() or 0

    if w < 20 or h < 5 or w > 600 or h > 250 then
        return false
    end

    return true
end

local function IsUsableAnchorCandidate(frame)
    if not frame or not frame:IsShown() then return false end
    if not frame.GetObjectType or frame:GetObjectType() ~= "StatusBar" then return false end

    local w = frame:GetWidth() or 0
    local h = frame:GetHeight() or 0

    if w < 35 or h < 3 or w > 450 or h > 35 then
        return false
    end

    return true
end

local function FindNameplateAnchor(frame)
    local bestAnchor = nil
    local bestY = nil
    local bestWidth = 0

    local function ConsiderAnchor(candidate)
        if not IsUsableAnchorCandidate(candidate) then return end

        local _, y = candidate:GetCenter()
        local w = candidate:GetWidth() or 0

        if not bestAnchor
            or (y and bestY and y > bestY)
            or (y and not bestY)
            or (not y and not bestY and w > bestWidth) then

            bestAnchor = candidate
            bestY = y
            bestWidth = w
        end
    end

    local function ScanFrame(candidate, depth)
        if not candidate or depth < 0 then return end

        ConsiderAnchor(candidate)

        if candidate.GetChildren then
            for i = 1, select("#", candidate:GetChildren()) do
                local child = select(i, candidate:GetChildren())
                if child and child:IsShown() then
                    ScanFrame(child, depth - 1)
                end
            end
        end
    end

    ScanFrame(frame, 3)
    return bestAnchor or frame
end

local function ScanRegionsForArenaName(frame)
    if not frame or not frame.GetRegions then return nil end

    for i = 1, select("#", frame:GetRegions()) do
        local region = select(i, frame:GetRegions())
        if region and region.GetText then
            local text = region:GetText()
            local unitId = TextMatchesArenaName(text)
            if unitId then
                return unitId, text
            end
        end
    end

    return nil
end

local function ScanChildFramesForArenaName(frame, depth)
    if not frame or not frame.GetChildren or depth <= 0 then return nil end

    for i = 1, select("#", frame:GetChildren()) do
        local child = select(i, frame:GetChildren())
        if child and child:IsShown() then
            local unitId, text = ScanRegionsForArenaName(child)
            if unitId then return unitId, text end

            unitId, text = ScanChildFramesForArenaName(child, depth - 1)
            if unitId then return unitId, text end
        end
    end

    return nil
end

local function ScanNameplates()
    RebuildArenaNameMap()

    local now = GetTime()

    for i = 1, select("#", WorldFrame:GetChildren()) do
        local frame = select(i, WorldFrame:GetChildren())
        if IsUsableWorldChild(frame) then
            local unitId, text = ScanRegionsForArenaName(frame)
            if not unitId then
                unitId, text = ScanChildFramesForArenaName(frame, 2)
            end

            if unitId then
                nameplateByArenaUnit[unitId] = frame
                nameplateAnchorByArenaUnit[unitId] = FindNameplateAnchor(frame)
                plateLastSeen[unitId] = now
            end
        end
    end

    local grace = NamePlateArenaGCDsDB and NamePlateArenaGCDsDB.plateGrace or 0.35
    for _, unitId in ipairs(trackedUnits) do
        local plate = nameplateByArenaUnit[unitId]
        if plate then
            local lastSeen = plateLastSeen[unitId] or 0
            if (now - lastSeen) > grace or not plate:IsShown() then
                nameplateByArenaUnit[unitId] = nil
                nameplateAnchorByArenaUnit[unitId] = nil
                plateLastSeen[unitId] = nil
            end
        end
    end
end

local function AnchorDisplayToPlate(unitId, plate)
    local f = displayFrames[unitId]
    if not f or not plate then return end

    local x = NamePlateArenaGCDsDB.offsetX or 0
    local y = NamePlateArenaGCDsDB.offsetY or 0
    local anchor = nameplateAnchorByArenaUnit[unitId] or plate

    if anchor.IsShown and not anchor:IsShown() then
        anchor = plate
    end

    if f.anchorPlate == plate
        and f.anchorAnchor == anchor
        and f.anchorX == x
        and f.anchorY == y then
        return
    end

    f.anchorPlate = plate
    f.anchorAnchor = anchor
    f.anchorX = x
    f.anchorY = y

    f:ClearAllPoints()
    f:SetPoint("CENTER", anchor, "CENTER", x, y)
end

local function UpdateDisplays()
    local now = GetTime()

    for _, unitId in ipairs(trackedUnits) do
        local f = displayFrames[unitId]
        local state = gcdState[unitId]

        if f and state and state.expiration and state.expiration > now then
            local plate = nameplateByArenaUnit[unitId]
            if plate and plate:IsShown() then
                AnchorDisplayToPlate(unitId, plate)
                if not f:IsShown() then
                    f:Show()
                end

                local left = state.expiration - now
                if left < 0 then left = 0 end

                local duration = state.duration or 1
                if duration <= 0 then duration = 1 end
                local ratio = left / duration
                if ratio < 0 then ratio = 0 end
                if ratio > 1 then ratio = 1 end

                if f.customSweep then
                    if NamePlateArenaGCDsDB.hideSweepAnimation then
                        f.customSweep:Hide()
                    else
                        local progress = NamePlateArenaGCDsDB.enableCooldownReverse and (1 - ratio) or ratio
                        if progress < 0 then progress = 0 end
                        if progress > 1 then progress = 1 end

                        local frameIndex = floor(progress * 63)
                        if frameIndex < 0 then frameIndex = 0 end
                        if frameIndex > 63 then frameIndex = 63 end

                        if f.lastSweepFrame ~= frameIndex then
                            f.lastSweepFrame = frameIndex
                            local row = floor(frameIndex / 8)
                            local col = frameIndex - row * 8
                            local l = col / 8
                            local r = (col + 1) / 8
                            local t = row / 8
                            local b = (row + 1) / 8
                            f.customSweep:SetTexCoord(r, l, t, b)
                        end

                        f.customSweep:SetAlpha(NamePlateArenaGCDsDB.cooldownSwipeAlpha or 1)
                        f.customSweep:Show()
                    end
                end

                if NamePlateArenaGCDsDB.showCountdownText then
                    f.text:SetText(string.format("%.1f", left))
                else
                    f.text:SetText("")
                end
            else
                if f:IsShown() then
                    f:Hide()
                end
                f.anchorPlate = nil
                f.anchorAnchor = nil
            end
        elseif f then
            if f:IsShown() then
                f:Hide()
            end
            f.anchorPlate = nil
            f.anchorAnchor = nil
            if state and state.expiration and state.expiration <= now then
                gcdState[unitId] = nil
            end
        end
    end
end

local scanElapsed = 0
local updateElapsed = 0
scannerFrame:SetScript("OnUpdate", function(self, elapsed)
    if not NamePlateArenaGCDsDB or not NamePlateArenaGCDsDB.enabled then
        return
    end

    ProcessPendingClears()

    scanElapsed = scanElapsed + elapsed
    updateElapsed = updateElapsed + elapsed

    if scanElapsed >= (NamePlateArenaGCDsDB.scanInterval or 0.05) then
        scanElapsed = 0
        ScanNameplates()
    end

    if updateElapsed >= (NamePlateArenaGCDsDB.updateInterval or 0.03) then
        updateElapsed = 0
        UpdateDisplays()
    end
end)

local function RunTestGCDs()
    local firedTarget = false
    local firedArena = 0

    if UnitExists("target") then
        local targetName = UnitName("target")
        if targetName and targetName ~= "" then
            StartNamedGCD("test", targetName, "Test", "Interface\\Icons\\Spell_Nature_StarFall", 15.0)
            firedTarget = true
        end
    end

    for i, unitId in ipairs(arenaUnits) do
        if UnitExists(unitId) then
            StartGCD(unitId, "Test", "Interface\\Icons\\Spell_Nature_StarFall", 1.5)
            firedArena = firedArena + 1
        end
    end

    ScanNameplates()

    if not firedTarget and firedArena == 0 then
        Print("target something with a visible nameplate, or join arena")
    end
end

local optionsFrame = nil
local function RoundNumber(v)
    return floor((tonumber(v) or 0) + 0.5)
end

local function ApplyAndRefreshOptions()
    ApplyDisplayConfig()
    if optionsFrame and optionsFrame.Refresh then
        optionsFrame:Refresh()
    end
end

local function Clamp(v, minValue, maxValue)
    v = tonumber(v) or minValue
    if v < minValue then return minValue end
    if v > maxValue then return maxValue end
    return v
end

local function QuantizeSliderValue(v, minValue, maxValue, step)
    v = Clamp(v, minValue, maxValue)
    step = tonumber(step) or 1

    if step >= 1 then
        return RoundNumber(v)
    end

    local steps = floor(((v - minValue) / step) + 0.5)
    local q = minValue + (steps * step)
    return Clamp(q, minValue, maxValue)
end

local function FormatEditValue(v, step)
    v = tonumber(v) or 0
    if (tonumber(step) or 1) >= 1 then
        return tostring(RoundNumber(v))
    end
    return string.format("%.2f", v)
end

local function CreateSlider(parent, label, minValue, maxValue, step, x, y, key, suffix)
    local row = CreateFrame("Frame", nil, parent)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    row:SetWidth(430)
    row:SetHeight(44)

    local title = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    title:SetText(label)

    local slider = CreateFrame("Slider", nil, row, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -20)
    slider:SetWidth(315)
    slider:SetHeight(16)

    local editBox = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
    editBox:SetAutoFocus(false)
    editBox:SetWidth(52)
    editBox:SetHeight(20)
    editBox:SetPoint("LEFT", slider, "RIGHT", 16, 0)
    editBox:SetJustifyH("CENTER")

    local suffixText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    suffixText:SetPoint("LEFT", editBox, "RIGHT", 5, 0)
    suffixText:SetText(suffix or "")

    slider:SetMinMaxValues(minValue, maxValue)
    slider:SetValueStep(step)

    local function SetConfigValue(value, fromEditBox)
        if not NamePlateArenaGCDsDB then return end

        local newValue = QuantizeSliderValue(value, minValue, maxValue, step)
        NamePlateArenaGCDsDB[key] = newValue

        if slider:GetValue() ~= newValue then
            slider:SetValue(newValue)
        end

        if not editBox:HasFocus() or fromEditBox then
            editBox:SetText(FormatEditValue(newValue, step))
            editBox:HighlightText(0, 0)
        end

        ApplyDisplayConfig()
    end

    slider:SetScript("OnValueChanged", function(self, value)
        SetConfigValue(value, false)
    end)

    editBox:SetScript("OnEnterPressed", function(self)
        SetConfigValue(self:GetText(), true)
        self:ClearFocus()
    end)

    editBox:SetScript("OnEscapePressed", function(self)
        local v = NamePlateArenaGCDsDB and NamePlateArenaGCDsDB[key] or minValue
        self:SetText(FormatEditValue(v, step))
        self:ClearFocus()
    end)

    editBox:SetScript("OnEditFocusLost", function(self)
        SetConfigValue(self:GetText(), true)
    end)

    row.slider = slider
    row.editBox = editBox
    row.key = key
    row.suffix = suffix or ""
    row.Refresh = function(self)
        local v = NamePlateArenaGCDsDB and NamePlateArenaGCDsDB[key] or minValue
        v = QuantizeSliderValue(v, minValue, maxValue, step)
        self.slider:SetValue(v)
        self.editBox:SetText(FormatEditValue(v, step))
        self.editBox:HighlightText(0, 0)
    end

    return row
end

local function CreateCheck(parent, label, x, y, key)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    cb:SetWidth(24)
    cb:SetHeight(24)

    local text = cb:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    text:SetText(label)
    cb.label = text

    cb:SetScript("OnClick", function(self)
        if not NamePlateArenaGCDsDB then return end
        NamePlateArenaGCDsDB[key] = self:GetChecked() and true or false
        ApplyDisplayConfig()
        if key == "enabled" and not NamePlateArenaGCDsDB.enabled then
            for _, f in pairs(displayFrames) do f:Hide() end
        end
    end)

    cb.Refresh = function(self)
        self:SetChecked(NamePlateArenaGCDsDB and NamePlateArenaGCDsDB[key] and true or false)
    end

    return cb
end

local function CreateOptionsWindow()
    if optionsFrame then return optionsFrame end

    local f = CreateFrame("Frame", "NamePlateArenaGCDsOptionsFrame", UIParent)
    f:SetWidth(500)
    f:SetHeight(575)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    f:Hide()

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(f)
    bg:SetTexture(0, 0, 0, 0.88)

    local border = CreateFrame("Frame", nil, f)
    border:SetPoint("TOPLEFT", f, "TOPLEFT", 4, -4)
    border:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -4, 4)
    border:SetBackdrop({
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    border:SetBackdropBorderColor(0.0, 1.0, 0.8, 0.9)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", f, "TOP", 0, -18)
    title:SetText("NameplateArenaGCDs")

    local sub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sub:SetPoint("TOP", title, "BOTTOM", 0, -4)
    sub:SetText("Arena enemy GCDs anchored to nameplates")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)

    f.controls = {}

    f.controls.enabled = CreateCheck(f, "Enable addon", 28, -66, "enabled")
    f.controls.text = CreateCheck(f, "Show countdown text", 28, -94, "showCountdownText")
    f.controls.hideSweep = CreateCheck(f, "Hide sweep animation", 215, -66, "hideSweepAnimation")
    f.controls.reverse = CreateCheck(f, "Reverse timer direction", 215, -94, "enableCooldownReverse")

    f.controls.size = CreateSlider(f, "Icon size", 14, 64, 1, 38, -130, "iconSize", " px")
    f.controls.zoom = CreateSlider(f, "Icon zoom", 0, 30, 1, 38, -180, "iconZoom", " %")
    f.controls.x = CreateSlider(f, "X offset", -150, 150, 1, 38, -230, "offsetX", "")
    f.controls.y = CreateSlider(f, "Y offset", -100, 100, 1, 38, -280, "offsetY", "")
    f.controls.font = CreateSlider(f, "Text size", 6, 24, 1, 38, -330, "fontSize", " px")
    f.controls.alpha = CreateSlider(f, "Timer alpha", 0, 1, 0.05, 38, -380, "cooldownSwipeAlpha", "")

    local testButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    testButton:SetWidth(100)
    testButton:SetHeight(22)
    testButton:SetPoint("TOPLEFT", f, "TOPLEFT", 38, -430)
    testButton:SetText("Test")
    testButton:SetScript("OnClick", function() RunTestGCDs() end)

    local resetButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    resetButton:SetWidth(150)
    resetButton:SetHeight(22)
    resetButton:SetPoint("LEFT", testButton, "RIGHT", 10, 0)
    resetButton:SetText("Reset Defaults")
    resetButton:SetScript("OnClick", function()
        NamePlateArenaGCDsDB = CopyDefaults(defaultConfig, {})
        ApplyAndRefreshOptions()
    end)

    local aboutBox = CreateFrame("Frame", nil, f)
    aboutBox:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 22, 18)
    aboutBox:SetWidth(456)
    aboutBox:SetHeight(106)
    aboutBox:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 10,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    aboutBox:SetBackdropColor(0.02, 0.02, 0.02, 0.75)
    aboutBox:SetBackdropBorderColor(1.0, 0.6, 0.0, 0.8)

    local aboutTitle = aboutBox:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    aboutTitle:SetPoint("TOPLEFT", aboutBox, "TOPLEFT", 10, -8)
    aboutTitle:SetText("About:")

    local authorText = aboutBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    authorText:SetPoint("TOPLEFT", aboutTitle, "BOTTOMLEFT", 0, -6)
    authorText:SetText("Author: Fruitdealer1337    Discord: scartino")

    local creditText = aboutBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    creditText:SetPoint("TOPLEFT", authorText, "BOTTOMLEFT", 0, -6)
    creditText:SetWidth(430)
    creditText:SetJustifyH("LEFT")
    creditText:SetText("Based on ArenaGCDs by Oscarforge.\n\nNameplateArenaGCDs extends the original arena GCD concept with direct nameplate anchoring, a native-looking smooth sweep animation, and support for cast and channel based GCD tracking.")

    f.Refresh = function(self)
        for _, control in pairs(self.controls) do
            if control.Refresh then control:Refresh() end
        end
    end

    optionsFrame = f
    return f
end

local function ShowOptionsWindow()
    local f = CreateOptionsWindow()
    f:Refresh()
    f:Show()
end

local function ToggleOptionsWindow()
    local f = CreateOptionsWindow()
    f:Refresh()
    if f:IsShown() then
        f:Hide()
    else
        f:Show()
    end
end

local interfaceOptionsPanel = nil
local function RegisterInterfaceOptionsPanel()
    if interfaceOptionsPanel or not InterfaceOptions_AddCategory then return end

    local panel = CreateFrame("Frame", "NamePlateArenaGCDsInterfacePanel", UIParent)
    panel.name = "NameplateArenaGCDs"

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -16)
    title:SetText("NameplateArenaGCDs")

    local description = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    description:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    description:SetWidth(520)
    description:SetJustifyH("LEFT")
    description:SetText("Enemy arena GCDs anchored to visible nameplates. Use the button below to open the addon configuration window.")

    local button = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    button:SetWidth(120)
    button:SetHeight(24)
    button:SetPoint("TOPLEFT", description, "BOTTOMLEFT", 0, -18)
    button:SetText("Open Config")
    button:SetScript("OnClick", function()
        if InterfaceOptionsFrame then
            InterfaceOptionsFrame:Hide()
        end
        if GameMenuFrame then
            if HideUIPanel then
                HideUIPanel(GameMenuFrame)
            else
                GameMenuFrame:Hide()
            end
        end
        ShowOptionsWindow()
    end)

    InterfaceOptions_AddCategory(panel)
    interfaceOptionsPanel = panel
end

local function SlashHandler(msg)
    msg = string.lower(tostring(msg or ""))

    if msg == "" or msg == "config" or msg == "options" then
        ToggleOptionsWindow()
        return
    end

    Print("use /npgcd to open the config window")
end

local function InitAddon()
    InitConfig()

    for i, unitId in ipairs(trackedUnits) do
        CreateDisplayFrame(unitId, i)
    end
    ApplyDisplayConfig()

    SLASH_NAMEPLATEARENAGCDS1 = "/npgcd"
    SlashCmdList["NAMEPLATEARENAGCDS"] = SlashHandler

    RegisterInterfaceOptionsPanel()
end

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
eventFrame:RegisterEvent("UNIT_SPELLCAST_START")
eventFrame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
eventFrame:RegisterEvent("UNIT_SPELLCAST_STOP")
eventFrame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
eventFrame:RegisterEvent("UNIT_SPELLCAST_FAILED")
eventFrame:RegisterEvent("UNIT_SPELLCAST_FAILED_QUIET")
eventFrame:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
eventFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
eventFrame:RegisterEvent("UNIT_AURA")
eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...
        if loadedAddon == addonName then
            InitAddon()
        end
        return
    end

    if event == "PLAYER_ENTERING_WORLD" then
        ClearUnitClasses()
        wipe(gcdState)
        wipe(pendingClears)
        wipe(observedCasts)
        wipe(nameplateByArenaUnit)
        wipe(nameplateAnchorByArenaUnit)
        wipe(plateLastSeen)
        return
    end

    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        local timestamp, subevent, hideCaster, sourceGUID, sourceName, sourceFlags, sourceRaidFlags, destGUID = ...
        if subevent == "SPELL_INTERRUPT" then
            OnSpellInterrupted(destGUID)
        end
        return
    end

    local unitId = ...
    if unitId and string.match(unitId, "^arena%d$") then
        if event == "UNIT_SPELLCAST_SUCCEEDED" then
            OnSpellCastSucceeded(unitId, select(2, ...), select(3, ...), select(4, ...), select(5, ...))
        elseif event == "UNIT_SPELLCAST_START" then
            OnSpellCastStart(unitId, select(2, ...), select(3, ...), select(4, ...), select(5, ...), "START")
        elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
            OnSpellCastStart(unitId, select(2, ...), select(3, ...), select(4, ...), select(5, ...), "CHANNEL_START")
        elseif event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_FAILED_QUIET" then
            OnSpellCastFailed(unitId, select(2, ...))
        elseif event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_CHANNEL_STOP" or event == "UNIT_SPELLCAST_INTERRUPTED" then
            OnSpellCastStop(unitId, select(2, ...))
        elseif event == "UNIT_AURA" then
            OnUnitAura(unitId)
        end
    end
end)
