-- ================================================================
--  LuaBoost v1.0.0 — WoW 3.3.5a Lua Runtime Optimizer
--  Author: Suprematist
--
--  Features:
--   - Faster math.floor/ceil/abs (pure Lua)
--   - Faster table.insert append path
--   - Per-frame GetTimeCached()
--   - Shared throttle API
--   - Shared table pool
--   - Smart incremental GC manager (combat + idle aware)
--   - Optional protection hooks:
--       * Intercept collectgarbage() calls from other addons
--       * Throttle UpdateAddOnMemoryUsage()
-- ================================================================

if _G.LUABOOST_LOADED then return end
_G.LUABOOST_LOADED = true

local ADDON_NAME    = "LuaBoost"
local ADDON_VERSION = "1.0.0"
local ADDON_COLOR   = "|cff00ccff"
local VALUE_COLOR   = "|cffffff00"

-- ================================================================
-- Localize frequently used globals
-- ================================================================
local orig_GetTime                = GetTime
local orig_format                 = string.format
local orig_tinsert                = table.insert
local orig_floor                  = math.floor
local orig_ceil                   = math.ceil
local orig_abs                    = math.abs
local orig_pairs                  = pairs
local orig_type                   = type
local orig_next                   = next
local orig_date                   = date
local orig_print                  = print
local orig_collectgarbage         = collectgarbage
local orig_UpdateAddOnMemoryUsage = UpdateAddOnMemoryUsage
local orig_GetAddOnMemoryUsage    = GetAddOnMemoryUsage
local orig_debugprofilestop       = debugprofilestop
local orig_min                    = math.min

-- ================================================================
-- PART A: Runtime Optimizations
-- ================================================================

-- A1. Per-frame time cache
local cachedTime  = 0
local frameNumber = 0

local timeFrame = CreateFrame("Frame")
timeFrame:SetScript("OnUpdate", function()
    frameNumber = frameNumber + 1
    cachedTime  = orig_GetTime()
end)

function _G.GetTimeCached()
    return cachedTime
end

function _G.GetFrameNumber()
    return frameNumber
end

-- A2. Faster math functions
local function fast_floor(x) return x - x % 1 end

local function fast_ceil(x)
    local f = x - x % 1
    if f == x then return x end
    return f + 1
end

local function fast_abs(x)
    if x < 0 then return -x end
    return x
end

math.floor = fast_floor
math.ceil  = fast_ceil
math.abs   = fast_abs

-- A3. Faster table.insert for append pattern
local function fast_tinsert(t, pos, value)
    if value == nil then
        t[#t + 1] = pos
    else
        orig_tinsert(t, pos, value)
    end
end

table.insert = fast_tinsert
_G.tinsert   = fast_tinsert

-- A4. Shared throttle API
local throttles = {}

function _G.LuaBoost_Throttle(id, interval)
    local now = cachedTime
    if now == 0 then now = orig_GetTime() end
    local last = throttles[id]
    if not last or (now - last) >= interval then
        throttles[id] = now
        return true
    end
    return false
end

-- A5. Shared table pool
local pool      = {}
local poolCount = 0
local POOL_MAX  = 200
local poolStats = { acquired = 0, released = 0, created = 0 }

function _G.LuaBoost_AcquireTable()
    poolStats.acquired = poolStats.acquired + 1
    if poolCount > 0 then
        local t = pool[poolCount]
        pool[poolCount] = nil
        poolCount = poolCount - 1
        return t
    end
    poolStats.created = poolStats.created + 1
    return {}
end

function _G.LuaBoost_ReleaseTable(t)
    if orig_type(t) ~= "table" then return end
    if poolCount >= POOL_MAX then return end

    poolStats.released = poolStats.released + 1

    local k = orig_next(t)
    while k ~= nil do
        t[k] = nil
        k = orig_next(t)
    end

    poolCount = poolCount + 1
    pool[poolCount] = t
end

function _G.LuaBoost_GetPoolStats()
    return poolStats.acquired, poolStats.released, poolStats.created, poolCount
end

-- A6. Cached date() — opt-in API (does not replace _G.date)
local cachedDate       = ""
local cachedDateFormat = ""
local cachedDateTime   = 0

function _G.GetDateCached(fmt, t)
    if t then return orig_date(fmt, t) end
    fmt = fmt or "%c"
    local now = cachedTime
    if now == 0 then now = orig_GetTime() end
    if fmt == cachedDateFormat and (now - cachedDateTime) < 1 then
        return cachedDate
    end
    cachedDateFormat = fmt
    cachedDateTime   = now
    cachedDate       = orig_date(fmt)
    return cachedDate
end

-- A7. Lua 5.0 compatibility shims (only if missing)
if not table.getn then table.getn = function(t) return #t end end
if not table.setn then table.setn = function() end end
if not table.foreach then
    table.foreach = function(t, f)
        for k, v in orig_pairs(t) do
            local r = f(k, v)
            if r ~= nil then return r end
        end
    end
end
if not table.foreachi then
    table.foreachi = function(t, f)
        for i = 1, #t do
            local r = f(i, t[i])
            if r ~= nil then return r end
        end
    end
end

-- ================================================================
-- PART B: Smart GC Manager
-- ================================================================

local defaults = {
    enabled                = true,
    frameStepKB            = 30,
    combatStepKB           = 10,
    idleStepKB             = 100,
    fullCollectThresholdMB = 80,
    idleTimeout            = 15,
    preset                 = "mid",
    debugMode              = false,

    -- Protection (enabled by default as requested)
    interceptGC            = true,
    blockMemoryUsage       = true,
    memoryUsageMinInterval = 1,
}

local presets = {
    weak = {
        frameStepKB            = 50,
        combatStepKB           = 5,
        idleStepKB             = 150,
        fullCollectThresholdMB = 50,
        idleTimeout            = 10,
    },
    mid = {
        frameStepKB            = 30,
        combatStepKB           = 10,
        idleStepKB             = 100,
        fullCollectThresholdMB = 80,
        idleTimeout            = 15,
    },
    strong = {
        frameStepKB            = 20,
        combatStepKB           = 15,
        idleStepKB             = 200,
        fullCollectThresholdMB = 120,
        idleTimeout            = 20,
    },
}

local db

local inCombat     = false
local isIdle       = false
local lastActivity = 0

local allControls = {}

local gcStats = {
    stepsLua     = 0,
    fullCollects = 0,
    emergencyGC  = 0,
}

local function Msg(text)
    orig_print(ADDON_COLOR .. "[LuaBoost]|r " .. text)
end

local function DebugMsg(text)
    if db and db.debugMode then
        orig_print("|cff888888[LuaBoost-GC]|r " .. text)
    end
end

local function InitDB()
    if orig_type(LuaBoostDB) ~= "table" then
        LuaBoostDB = {}
    end

    -- Import legacy SmartGCDB once
    if orig_type(SmartGCDB) == "table" and not LuaBoostDB._migrated then
        for k, v in orig_pairs(SmartGCDB) do
            if defaults[k] ~= nil then
                LuaBoostDB[k] = v
            end
        end
        LuaBoostDB._migrated = true
    end

    for k, v in orig_pairs(defaults) do
        if LuaBoostDB[k] == nil then
            LuaBoostDB[k] = v
        end
    end

    db = LuaBoostDB
end

local function ApplyPreset(name)
    local p = presets[name]
    if not p then return end
    for k, v in orig_pairs(p) do
        db[k] = v
    end
    db.preset = name
end

local function GetMemoryMB()
    return orig_collectgarbage("count") / 1024
end

local function GetCurrentStepKB()
    if not db then return 30 end
    if inCombat then
        return db.combatStepKB
    elseif isIdle then
        return db.idleStepKB
    else
        return db.frameStepKB
    end
end

local function GetModeString()
    if inCombat then return "|cffff4444combat|r"
    elseif isIdle then return "|cff888888idle|r"
    else return "|cff44ff44normal|r" end
end

local function RefreshAllControls()
    for _, c in orig_pairs(allControls) do
        if c.Refresh then c:Refresh() end
    end
end

local function hasDLL()
    return orig_type(LuaBoostC_IsLoaded) == "function"
end

-- ================================================================
-- Protection hooks
-- ================================================================
local lastMemUsageUpdate = 0

local function CollectGarbage_Proxy(opt, arg)
    if not db or not db.enabled or not db.interceptGC then
        return orig_collectgarbage(opt, arg)
    end

    if opt == "count" then
        return orig_collectgarbage("count")
    end

    if opt == nil or opt == "collect" then
        return 0
    end

    if opt == "step" then
        local limit = inCombat and 5 or 20
        arg = arg and orig_min(arg, limit) or limit
        return orig_collectgarbage("step", arg)
    end

    if opt == "stop" or opt == "restart" or opt == "setpause" or opt == "setstepmul" then
        return 0
    end

    return orig_collectgarbage(opt, arg)
end

local function UpdateAddOnMemoryUsage_Proxy(...)
    if not db or not db.enabled or not db.blockMemoryUsage then
        return orig_UpdateAddOnMemoryUsage(...)
    end
    return
end

local function GetAddOnMemoryUsage_Proxy(index)
    if not db or not db.enabled or not db.blockMemoryUsage then
        return orig_GetAddOnMemoryUsage(index)
    end
    return 0
end

local function ApplyProtectionHooks()
    if not db then return end

    -- collectgarbage()
    if db.enabled and db.interceptGC then
        _G.collectgarbage = CollectGarbage_Proxy
    else
        _G.collectgarbage = orig_collectgarbage
    end

    -- AddOn memory APIs
    if db.enabled and db.blockMemoryUsage then
        _G.UpdateAddOnMemoryUsage = UpdateAddOnMemoryUsage_Proxy
        _G.GetAddOnMemoryUsage    = GetAddOnMemoryUsage_Proxy
    else
        _G.UpdateAddOnMemoryUsage = orig_UpdateAddOnMemoryUsage
        _G.GetAddOnMemoryUsage    = orig_GetAddOnMemoryUsage
    end

    if db.debugMode then
        orig_print("|cff888888[LuaBoost-GC]|r Hooks: " ..
            "collectgarbage=" .. ((db.enabled and db.interceptGC) and "proxy" or "orig") ..
            ", AddOnMemory=" .. ((db.enabled and db.blockMemoryUsage) and "blocked" or "orig"))
    end
end

-- ================================================================
-- GC core
-- ================================================================
orig_collectgarbage("stop")
orig_collectgarbage("collect")
orig_collectgarbage("collect")

local gcReStopCounter = 0

local gcFrame = CreateFrame("Frame")
gcFrame:SetScript("OnUpdate", function()
    if not db or not db.enabled then return end

    -- Idle detection
    if not isIdle and (orig_GetTime() - lastActivity) > db.idleTimeout then
        isIdle = true
        DebugMsg("Idle mode activated")
    end

    -- Every ~5 seconds: re-stop GC + re-apply protection hooks
    gcReStopCounter = gcReStopCounter + 1
    if gcReStopCounter >= 300 then
        gcReStopCounter = 0
        orig_collectgarbage("stop")
        ApplyProtectionHooks()
    end

    -- Emergency full GC (not in combat)
    local memKB = orig_collectgarbage("count")
    if memKB > (db.fullCollectThresholdMB * 1024) and not inCombat then
        local t0 = orig_debugprofilestop()
        orig_collectgarbage("collect")
        orig_collectgarbage("collect")
        local dt = orig_debugprofilestop() - t0

        local memAfterKB = orig_collectgarbage("count")
        gcStats.emergencyGC = gcStats.emergencyGC + 1

        DebugMsg(orig_format("Emergency GC: freed %.1f MB in %.1f ms",
            (memKB - memAfterKB) / 1024, dt))

        if dt > 50 then
            db.fullCollectThresholdMB = db.fullCollectThresholdMB + 20
            DebugMsg("Raised threshold to " .. db.fullCollectThresholdMB .. " MB")
        end

        orig_collectgarbage("stop")
        return
    end

    -- DLL handles per-frame stepping if present
    if hasDLL() then return end

    local step = orig_floor(GetCurrentStepKB())
    if step > 0 then
        orig_collectgarbage("step", step)
        gcStats.stepsLua = gcStats.stepsLua + 1
    end
end)

-- Combat tracking
local combatFrame = CreateFrame("Frame")
combatFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
combatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
combatFrame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_REGEN_DISABLED" then
        inCombat = true
        lastActivity = orig_GetTime()
        isIdle = false

        _G.LUABOOST_ADDON_COMBAT = true
        if hasDLL() and LuaBoostC_SetCombat then
            LuaBoostC_SetCombat(true)
        end

    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        lastActivity = orig_GetTime()

        _G.LUABOOST_ADDON_COMBAT = false
        if hasDLL() and LuaBoostC_SetCombat then
            LuaBoostC_SetCombat(false)
        end

        if db and db.enabled then
            if hasDLL() and LuaBoostC_GCStep then
                LuaBoostC_GCStep(256)
            else
                orig_collectgarbage("step", 50)
            end
        end
    end
end)

-- Activity tracking (idle reset)
local activityFrame = CreateFrame("Frame")
local activityEvents = {
    "PLAYER_STARTED_MOVING", "PLAYER_STOPPED_MOVING",
    "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_SUCCEEDED",
    "CHAT_MSG_SAY", "CHAT_MSG_PARTY", "CHAT_MSG_RAID",
    "CHAT_MSG_GUILD", "CHAT_MSG_WHISPER", "CHAT_MSG_WHISPER_INFORM",
    "LOOT_OPENED", "BAG_UPDATE", "ACTIONBAR_UPDATE_STATE",
    "MERCHANT_SHOW", "AUCTION_HOUSE_SHOW", "BANKFRAME_OPENED",
    "MAIL_SHOW", "QUEST_DETAIL",
}
for _, event in orig_pairs(activityEvents) do
    activityFrame:RegisterEvent(event)
end
activityFrame:SetScript("OnEvent", function()
    lastActivity = orig_GetTime()
    if isIdle then isIdle = false end
end)

-- Zone/loading GC
local zoneFrame = CreateFrame("Frame")
zoneFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
zoneFrame:RegisterEvent("LOADING_SCREEN_DISABLED")
zoneFrame:SetScript("OnEvent", function()
    if not db or not db.enabled then return end

    if hasDLL() and LuaBoostC_GCCollect then
        LuaBoostC_GCCollect()
    else
        orig_collectgarbage("collect")
        orig_collectgarbage("collect")
    end

    gcStats.fullCollects = gcStats.fullCollects + 1
    lastActivity = orig_GetTime()
    isIdle = false
    orig_collectgarbage("stop")
end)

-- ================================================================
-- PART C: Benchmark
-- ================================================================
local function RunBenchmark()
    local N = 1000000
    local dummy = 0

    orig_print(ADDON_COLOR .. "[LuaBoost]|r Running benchmark (" .. N .. " iterations)...")

    debugprofilestart()
    for i = 1, N do dummy = orig_floor(i * 1.7) end
    local floor_orig = debugprofilestop()

    debugprofilestart()
    for i = 1, N do dummy = fast_floor(i * 1.7) end
    local floor_fast = debugprofilestop()

    debugprofilestart()
    for i = 1, N do dummy = orig_ceil(i * 1.3) end
    local ceil_orig = debugprofilestop()

    debugprofilestart()
    for i = 1, N do dummy = fast_ceil(i * 1.3) end
    local ceil_fast = debugprofilestop()

    debugprofilestart()
    for i = 1, N do dummy = orig_abs(i * -1.5) end
    local abs_orig = debugprofilestop()

    debugprofilestart()
    for i = 1, N do dummy = fast_abs(i * -1.5) end
    local abs_fast = debugprofilestop()

    local K = 100000
    local benchTable = {}
    debugprofilestart()
    for i = 1, K do orig_tinsert(benchTable, i) end
    local insert_orig = debugprofilestop()

    benchTable = {}
    debugprofilestart()
    for i = 1, K do benchTable[#benchTable + 1] = i end
    local insert_fast = debugprofilestop()

    local function pct(a, b)
        if a > 0 then return (1 - b / a) * 100 end
        return 0
    end

    orig_print(ADDON_COLOR .. "[LuaBoost]|r Results (lower ms = better):")
    orig_print(orig_format("  math.floor:   %7.1f ms -> %7.1f ms  (%.0f%% faster)",
        floor_orig, floor_fast, pct(floor_orig, floor_fast)))
    orig_print(orig_format("  math.ceil:    %7.1f ms -> %7.1f ms  (%.0f%% faster)",
        ceil_orig, ceil_fast, pct(ceil_orig, ceil_fast)))
    orig_print(orig_format("  math.abs:     %7.1f ms -> %7.1f ms  (%.0f%% faster)",
        abs_orig, abs_fast, pct(abs_orig, abs_fast)))
    orig_print(orig_format("  table.insert: %7.1f ms -> %7.1f ms  (%.0f%% faster) (100k)",
        insert_orig, insert_fast, pct(insert_orig, insert_fast)))
end

-- ================================================================
-- PART D: GUI (Interface Options)
-- ================================================================
local function Label(parent, text, x, y, template)
    local fs = parent:CreateFontString(nil, "ARTWORK", template or "GameFontHighlight")
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetText(text)
    fs:SetJustifyH("LEFT")
    return fs
end

local function Checkbox(parent, label, tip, x, y, get, set)
    local name = "LuaBoost_CB_" .. label:gsub("[^%w]", "")
    local cb = CreateFrame("CheckButton", name, parent, "InterfaceOptionsCheckButtonTemplate")
    cb:SetPoint("TOPLEFT", x, y)

    local t = _G[name .. "Text"]
    if t then t:SetText(label) end

    cb.tooltipText = label
    cb.tooltipRequirement = tip

    function cb:Refresh() self:SetChecked(get()) end
    cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)

    cb:Refresh()
    allControls[#allControls + 1] = cb
    return cb
end

local function Slider(parent, label, tip, x, y, lo, hi, st, get, set)
    local name = "LuaBoost_S_" .. label:gsub("[^%w]", "")
    local s = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
    s:SetPoint("TOPLEFT", x, y)
    s:SetWidth(220)
    s:SetHeight(17)
    s:SetMinMaxValues(lo, hi)
    s:SetValueStep(st)

    local tT = _G[name .. "Text"]
    local tL = _G[name .. "Low"]
    local tH = _G[name .. "High"]
    if tT then tT:SetText(label) end
    if tL then tL:SetText(lo) end
    if tH then tH:SetText(hi) end

    s.tooltipText = label
    s.tooltipRequirement = tip

    local val = s:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    val:SetPoint("LEFT", s, "RIGHT", 8, 0)
    s.valText = val

    function s:Refresh()
        self:SetValue(get())
        self.valText:SetText(VALUE_COLOR .. get() .. "|r")
    end

    s:SetScript("OnValueChanged", function(self, v)
        v = orig_floor(v / st + 0.5) * st
        set(v)
        self.valText:SetText(VALUE_COLOR .. v .. "|r")
    end)

    s:Refresh()
    allControls[#allControls + 1] = s
    return s
end

-- Main panel
local panelMain = CreateFrame("Frame", "LuaBoostPanelMain", InterfaceOptionsFramePanelContainer)
panelMain.name = "LuaBoost"
panelMain:Hide()

panelMain:SetScript("OnShow", function(self)
    if self.built then RefreshAllControls() return end
    self.built = true

    Label(self, ADDON_COLOR .. "LuaBoost|r v" .. ADDON_VERSION, 16, -16, "GameFontNormalLarge")

    local desc = Label(self, "Lua runtime optimizer + smart garbage collector for WoW 3.3.5a.", 16, -36, "GameFontHighlightSmall")
    desc:SetWidth(450)

    local statusLabel = Label(self, "", 16, -56, "GameFontNormal")
    statusLabel:SetWidth(500)

    local timer = 0
    self:SetScript("OnUpdate", function(_, el)
        timer = timer + el
        if timer < 0.5 then return end
        timer = 0
        if not db then return end

        local dllTag = hasDLL() and " | |cff00ff00DLL|r" or ""
        statusLabel:SetText(orig_format(
            "%s  |  Mem: %s%.1f MB|r  |  %s  |  %s%d|r KB/f%s",
            db.enabled and "|cff00ff00ON|r" or "|cffff0000OFF|r",
            VALUE_COLOR, GetMemoryMB(),
            GetModeString(),
            VALUE_COLOR, GetCurrentStepKB(),
            dllTag
        ))
    end)

    Checkbox(self, "Enable GC Manager",
        "Master toggle for smart GC.",
        14, -76,
        function() return db.enabled end,
        function(v)
            db.enabled = v
            if v then
                orig_collectgarbage("stop")
            else
                orig_collectgarbage("restart")
            end
            ApplyProtectionHooks()
        end
    )

    Label(self, "GC Presets:", 16, -106, "GameFontNormal")

    local pdata = {
        { k = "weak",   l = "|cffff8844Weak|r",   x = 95 },
        { k = "mid",    l = "|cffffff44Mid|r",    x = 205 },
        { k = "strong", l = "|cff44ff44Strong|r", x = 315 },
    }

    for _, p in orig_pairs(pdata) do
        local b = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
        b:SetSize(100, 22)
        b:SetPoint("TOPLEFT", p.x, -103)
        b:SetText(p.l)
        b:SetScript("OnClick", function()
            ApplyPreset(p.k)
            RefreshAllControls()
        end)
    end

    Label(self, "Runtime optimizations are always active.", 16, -140, "GameFontHighlightSmall")
end)

InterfaceOptions_AddCategory(panelMain)

-- GC Settings panel
local panelSettings = CreateFrame("Frame", "LuaBoostPanelSettings", InterfaceOptionsFramePanelContainer)
panelSettings.name = "GC Settings"
panelSettings.parent = "LuaBoost"
panelSettings:Hide()

panelSettings:SetScript("OnShow", function(self)
    if self.built then RefreshAllControls() return end
    self.built = true

    Label(self, ADDON_COLOR .. "GC Settings|r", 16, -16, "GameFontNormalLarge")

    Label(self, "Step Sizes (KB collected per frame)", 16, -56, "GameFontNormal")

    Slider(self, "Normal Step", "GC per frame during normal gameplay.", 20, -86, 1, 200, 5,
        function() return db.frameStepKB end,
        function(v) db.frameStepKB = v; db.preset = "custom" end
    )

    Slider(self, "Combat Step", "GC per frame in combat.", 20, -138, 0, 50, 1,
        function() return db.combatStepKB end,
        function(v) db.combatStepKB = v; db.preset = "custom" end
    )

    Slider(self, "Idle Step", "GC per frame while AFK/idle.", 20, -190, 10, 500, 10,
        function() return db.idleStepKB end,
        function(v) db.idleStepKB = v; db.preset = "custom" end
    )

    Label(self, "Thresholds", 16, -244, "GameFontNormal")

    Slider(self, "Emergency Full GC (MB)", "Force full GC outside combat.", 20, -274, 20, 300, 10,
        function() return db.fullCollectThresholdMB end,
        function(v) db.fullCollectThresholdMB = v; db.preset = "custom" end
    )

    Slider(self, "Idle Timeout (sec)", "Seconds without activity before idle mode.", 20, -326, 5, 120, 5,
        function() return db.idleTimeout end,
        function(v) db.idleTimeout = v end
    )
end)

InterfaceOptions_AddCategory(panelSettings)

-- Tools panel
local panelTools = CreateFrame("Frame", "LuaBoostPanelTools", InterfaceOptionsFramePanelContainer)
panelTools.name = "Tools"
panelTools.parent = "LuaBoost"
panelTools:Hide()

panelTools:SetScript("OnShow", function(self)
    if self.built then RefreshAllControls() return end
    self.built = true

    Label(self, ADDON_COLOR .. "Tools & Diagnostics|r", 16, -16, "GameFontNormalLarge")

    Checkbox(self, "Debug mode (GC info in chat)",
        "Shows GC mode changes and emergency collections.",
        14, -40,
        function() return db.debugMode end,
        function(v) db.debugMode = v end
    )

    Checkbox(self, "Intercept collectgarbage() calls",
        "Blocks full GC calls triggered by other addons.\nIf UI blocking/taint appears, disable this option.",
        14, -66,
        function() return db.interceptGC end,
        function(v) db.interceptGC = v and true or false; ApplyProtectionHooks() end
    )

    Checkbox(self, "Throttle UpdateAddOnMemoryUsage()",
        "Throttles heavy addon memory scans.\nIf UI blocking/taint appears, disable this option.",
        14, -92,
        function() return db.blockMemoryUsage end,
        function(v) db.blockMemoryUsage = v and true or false; ApplyProtectionHooks() end
    )

    Slider(self, "MemUsage Min Interval (sec)", "Minimum interval between UpdateAddOnMemoryUsage() calls.", 20, -132, 0, 10, 1,
        function() return db.memoryUsageMinInterval end,
        function(v) db.memoryUsageMinInterval = v end
    )

    local resultLabel = Label(self, "", 200, -175, "GameFontHighlightSmall")
    resultLabel:SetWidth(300)

    local forceBtn = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
    forceBtn:SetSize(170, 22)
    forceBtn:SetPoint("TOPLEFT", 16, -172)
    forceBtn:SetText("Force Full GC Now")
    forceBtn:SetScript("OnClick", function()
        local before = orig_collectgarbage("count")
        local t0 = orig_debugprofilestop()

        if hasDLL() and LuaBoostC_GCCollect then
            LuaBoostC_GCCollect()
        else
            orig_collectgarbage("collect")
            orig_collectgarbage("collect")
        end

        local dt = orig_debugprofilestop() - t0
        local after = orig_collectgarbage("count")
        local freed = (before - after) / 1024

        resultLabel:SetText(orig_format("|cff44ff44Freed %.1f MB in %.1f ms|r", freed, dt))
        gcStats.fullCollects = gcStats.fullCollects + 1
        orig_collectgarbage("stop")
    end)

    local benchBtn = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
    benchBtn:SetSize(170, 22)
    benchBtn:SetPoint("TOPLEFT", 16, -200)
    benchBtn:SetText("Run Benchmark")
    benchBtn:SetScript("OnClick", function() RunBenchmark() end)

    local resetBtn = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
    resetBtn:SetSize(170, 22)
    resetBtn:SetPoint("TOPLEFT", 16, -228)
    resetBtn:SetText("Reset All to Defaults")
    resetBtn:SetScript("OnClick", function()
        StaticPopupDialogs["LUABOOST_RESET"] = {
            text = "Reset all LuaBoost settings to defaults?",
            button1 = "Yes", button2 = "No",
            OnAccept = function()
                LuaBoostDB = nil
                InitDB()
                ApplyProtectionHooks()
                RefreshAllControls()
                resultLabel:SetText("")
            end,
            timeout = 0, whileDead = true, hideOnEscape = true,
        }
        StaticPopup_Show("LUABOOST_RESET")
    end)
end)

InterfaceOptions_AddCategory(panelTools)

-- ================================================================
-- PART E: Slash Commands
-- ================================================================
local function ShowStatus()
    orig_print(ADDON_COLOR .. "[LuaBoost]|r v" .. ADDON_VERSION)
    if db then
        orig_print(orig_format("  GC: %s | Mode: %s | Mem: %.1f MB | Step: %d KB/f",
            db.enabled and "|cff00ff00ON|r" or "|cffff0000OFF|r",
            GetModeString(), GetMemoryMB(), GetCurrentStepKB()))
        orig_print(orig_format("  Protection: interceptGC=%s, blockMemoryUsage=%s",
            db.interceptGC and "on" or "off",
            db.blockMemoryUsage and "on" or "off"))
    end
    if hasDLL() then
        orig_print("  wow_optimize.dll: |cff00ff00CONNECTED|r")
    else
        orig_print("  wow_optimize.dll: |cffaaaaaaNOT DETECTED|r")
    end
    orig_print("  " .. VALUE_COLOR .. "/lb help|r")
end

SLASH_LUABOOST1 = "/luaboost"
SLASH_LUABOOST2 = "/lb"
SlashCmdList["LUABOOST"] = function(input)
    if not db then InitDB() end
    input = (input or ""):lower()

    if input == "bench" or input == "benchmark" then
        RunBenchmark()

    elseif input == "gc" then
        local memKB = orig_collectgarbage("count")
        orig_print(ADDON_COLOR .. "[LuaBoost]|r GC Stats:")
        orig_print(orig_format("  Memory: %.0f KB (%.1f MB)", memKB, memKB / 1024))
        orig_print(orig_format("  Mode: %s | Step: %d KB/f", GetModeString(), GetCurrentStepKB()))
        orig_print(orig_format("  Lua steps: %d | Emergency: %d | Full: %d",
            gcStats.stepsLua, gcStats.emergencyGC, gcStats.fullCollects))

        if hasDLL() and LuaBoostC_GetStats then
            local mem, steps, fulls, pause, stepmul, combat = LuaBoostC_GetStats()
            if mem then
                orig_print(orig_format("  DLL: mem=%.0f KB steps=%d full=%d pause=%d stepmul=%d combat=%s",
                    mem or 0, steps or 0, fulls or 0, pause or 0, stepmul or 0,
                    combat and "yes" or "no"))
            end
        end

    elseif input == "pool" then
        local acq, rel, cre, cur = LuaBoost_GetPoolStats()
        orig_print(orig_format(ADDON_COLOR .. "[LuaBoost]|r Pool: %d acquired, %d released, %d created, %d available",
            acq, rel, cre, cur))

    elseif input == "toggle" then
        db.enabled = not db.enabled
        if db.enabled then orig_collectgarbage("stop") else orig_collectgarbage("restart") end
        ApplyProtectionHooks()
        Msg("GC Manager: " .. (db.enabled and "|cff00ff00ON|r" or "|cffff0000OFF|r"))

    elseif input == "force" then
        local b = orig_collectgarbage("count")
        if hasDLL() and LuaBoostC_GCCollect then
            LuaBoostC_GCCollect()
        else
            orig_collectgarbage("collect")
            orig_collectgarbage("collect")
        end
        local a = orig_collectgarbage("count")
        Msg(orig_format("Freed %.1f MB", (b - a) / 1024))
        gcStats.fullCollects = gcStats.fullCollects + 1
        orig_collectgarbage("stop")

    elseif input == "settings" then
        InterfaceOptionsFrame_OpenToCategory(panelSettings)
        InterfaceOptionsFrame_OpenToCategory(panelSettings)

    elseif input == "help" then
        orig_print(ADDON_COLOR .. "[LuaBoost]|r Commands:")
        orig_print("  /lb           — status")
        orig_print("  /lb bench     — benchmark")
        orig_print("  /lb gc        — GC stats")
        orig_print("  /lb pool      — table pool stats")
        orig_print("  /lb toggle    — enable/disable GC manager")
        orig_print("  /lb force     — force full GC now")
        orig_print("  /lb settings  — open GC settings")
    else
        ShowStatus()
    end
end

-- ================================================================
-- PART F: Initialization
-- ================================================================
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("ADDON_LOADED")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME and arg1 ~= ("!" .. ADDON_NAME) then return end

        InitDB()
        ApplyProtectionHooks()

        lastActivity = orig_GetTime()
        cachedTime   = orig_GetTime()

        if db.enabled then
            orig_collectgarbage("stop")
        end

    elseif event == "PLAYER_LOGIN" then
        self:UnregisterEvent("ADDON_LOADED")
        self:UnregisterEvent("PLAYER_LOGIN")

        if not db then
            InitDB()
            ApplyProtectionHooks()
            lastActivity = orig_GetTime()
            cachedTime   = orig_GetTime()
            if db.enabled then orig_collectgarbage("stop") end
        end

        local parts = {}
        parts[#parts + 1] = ADDON_COLOR .. "[LuaBoost]|r v" .. ADDON_VERSION
        parts[#parts + 1] = db.enabled and ("GC:" .. VALUE_COLOR .. (db.preset or "custom") .. "|r") or "GC:|cffff0000OFF|r"
        if hasDLL() then parts[#parts + 1] = "|cff00ff00DLL|r" end
        parts[#parts + 1] = VALUE_COLOR .. "/lb|r help"
        orig_print(table.concat(parts, " | "))

        if orig_type(SmartGCDB) == "table" or (IsAddOnLoaded and (IsAddOnLoaded("SmartGC") or IsAddOnLoaded("!SmartGC"))) then
            orig_print(ADDON_COLOR .. "[LuaBoost]|r |cffff8844WARNING:|r SmartGC detected. Disable SmartGC to avoid conflicts.")
        end
    end
end)