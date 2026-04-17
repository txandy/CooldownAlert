-- ============================================================
--  CooldownAlert - warriorkekw
--  Suena un aviso cuando pulsas una tecla de acción que está
--  en cooldown real, no se puede usar (sin mana, stance, etc)
--  o (opcional) está fuera de rango. Ignora el GCD.
-- ============================================================

local ADDON   = "CooldownAlert"
local VERSION = "1.1"

-- ── Config por defecto (persistente via SavedVariables) ──────
local DEFAULTS = {
    enabled       = true,
    alertOnCD     = true,    -- CD real
    alertOnUnusable = true,  -- sin maná/rage, stance incorrecta, etc
    alertOnRange  = false,   -- fuera de rango (ruidoso, off por defecto)
    alertCooldown = 0.3,     -- anti-spam (seg)
    soundID       = 882,     -- 882 = spell error genérico
}

CooldownAlertDB = CooldownAlertDB or {}
local function cfg(key)
    if CooldownAlertDB[key] == nil then CooldownAlertDB[key] = DEFAULTS[key] end
    return CooldownAlertDB[key]
end

-- ── Binding name → Blizzard action button frame name ─────────
-- El slot actual se resuelve con btn:GetAttribute("action") si está
-- (barras puras Blizzard) o bien con page*12+id (bars con
-- "native dispatch" estilo EllesmereUI, que no setean el atributo).
local BINDING_TO_BUTTON = {}
for i = 1, 12 do
    BINDING_TO_BUTTON["ACTIONBUTTON"          .. i] = "ActionButton"              .. i
    BINDING_TO_BUTTON["MULTIACTIONBAR1BUTTON" .. i] = "MultiBarBottomLeftButton"  .. i
    BINDING_TO_BUTTON["MULTIACTIONBAR2BUTTON" .. i] = "MultiBarBottomRightButton" .. i
    BINDING_TO_BUTTON["MULTIACTIONBAR3BUTTON" .. i] = "MultiBarRightButton"       .. i
    BINDING_TO_BUTTON["MULTIACTIONBAR4BUTTON" .. i] = "MultiBarLeftButton"        .. i
    BINDING_TO_BUTTON["MULTIACTIONBAR5BUTTON" .. i] = "MultiBar5Button"           .. i
    BINDING_TO_BUTTON["MULTIACTIONBAR6BUTTON" .. i] = "MultiBar6Button"           .. i
    BINDING_TO_BUTTON["MULTIACTIONBAR7BUTTON" .. i] = "MultiBar7Button"           .. i
end

-- Action page fija para multi-bars (WoW asigna así los slots 1-180)
local BUTTON_PREFIX_PAGE = {
    ["MultiBarBottomLeftButton"]  = 6,   -- slots 61-72
    ["MultiBarBottomRightButton"] = 5,   -- slots 49-60
    ["MultiBarRightButton"]       = 3,   -- slots 25-36
    ["MultiBarLeftButton"]        = 4,   -- slots 37-48
    ["MultiBar5Button"]           = 13,  -- slots 145-156
    ["MultiBar6Button"]           = 14,  -- slots 157-168
    ["MultiBar7Button"]           = 15,  -- slots 169-180
}

-- Dado el nombre del botón + su ID, devuelve el slot de acción.
local function ComputeSlotFromButton(btnName, btn)
    -- 1) si el botón tiene attr action explícito (barras Blizzard puras), úsalo
    local attrSlot = btn:GetAttribute("action")
    if type(attrSlot) == "number" and attrSlot > 0 then return attrSlot end

    -- 2) ID del botón (1-12)
    local id = btn:GetID()
    if type(id) ~= "number" or id < 1 or id > 12 then return nil end

    -- 3) multi-bars → page fija
    for prefix, page in pairs(BUTTON_PREFIX_PAGE) do
        if btnName:sub(1, #prefix) == prefix then
            return (page - 1) * 12 + id
        end
    end

    -- 4) ActionButton1-12 → page dinámica (stance/forma/vehículo/bonus bar)
    if btnName:sub(1, 12) == "ActionButton" then
        local page = 1
        if MainMenuBar and MainMenuBar.GetAttribute then
            local p = MainMenuBar:GetAttribute("actionpage")
            if type(p) == "number" and p > 0 then page = p end
        end
        if page == 1 and type(GetActionBarPage) == "function" then
            page = GetActionBarPage() or 1
        end
        return (page - 1) * 12 + id
    end

    return nil
end

local MODIFIER_KEYS = {
    LSHIFT=true, RSHIFT=true,
    LCTRL=true,  RCTRL=true,
    LALT=true,   RALT=true,
    LMETA=true,  RMETA=true,
}

-- ── Helpers ──────────────────────────────────────────────────

local function GetModifierPrefix()
    local m = ""
    if IsShiftKeyDown()   then m = "SHIFT-" .. m end
    if IsControlKeyDown() then m = "CTRL-"  .. m end
    if IsAltKeyDown()     then m = "ALT-"   .. m end
    return m
end

-- Obtiene el slot actual que realmente ejecuta esa tecla.
local function GetActionSlotForKey(key)
    local prefix = GetModifierPrefix()
    local binding = GetBindingAction(prefix .. key, true)
    if not binding or binding == "" then
        binding = GetBindingAction(key, true)
    end
    if not binding or binding == "" then return nil end

    local btnName = BINDING_TO_BUTTON[binding]
    if not btnName then return nil end

    local btn = _G[btnName]
    if not btn then return nil end

    return ComputeSlotFromButton(btnName, btn)
end

-- Devuelve (start, duration) del GCD actual, o (0,0) si no hay.
local GCD_SPELL_ID = 61304
local function GetGCDInfo()
    if C_Spell and C_Spell.GetSpellCooldown then
        local info = C_Spell.GetSpellCooldown(GCD_SPELL_ID)
        if info then return info.startTime or 0, info.duration or 0 end
    end
    if GetSpellCooldown then
        local s, d = GetSpellCooldown(GCD_SPELL_ID)
        return s or 0, d or 0
    end
    return 0, 0
end

-- ¿El CD del slot es el GCD (y no un CD real)?
local function IsGCD(slotStart, slotDur)
    if slotStart == 0 or slotDur == 0 then return false end
    local gStart, gDur = GetGCDInfo()
    if gDur == 0 then
        -- Fallback: si dura <=1.5s lo tratamos como GCD
        return slotDur <= 1.5
    end
    return math.abs(slotStart - gStart) < 0.05 and math.abs(slotDur - gDur) < 0.05
end

-- En Midnight (11.2+) ciertos valores devueltos en combate vienen como
-- "secret numbers" que no se pueden comparar. Preferimos resolver el hechizo
-- detrás del slot y consultar C_Spell.GetSpellCooldown (números normales).
local function GetSpellCooldownForSlot(slot)
    local actionType, id = GetActionInfo(slot)
    local spellID
    if actionType == "spell" and type(id) == "number" then
        spellID = id
    elseif actionType == "macro" and type(id) == "number" and GetMacroSpell then
        spellID = GetMacroSpell(id)
    end
    if not spellID then return nil end
    if C_Spell and C_Spell.GetSpellCooldown then
        local info = C_Spell.GetSpellCooldown(spellID)
        if info then return info.startTime or 0, info.duration or 0 end
    end
    return nil
end

local function GetItemCooldownForSlot(slot)
    local actionType, id = GetActionInfo(slot)
    local itemID
    if actionType == "item" and type(id) == "number" then
        itemID = id
    elseif actionType == "macro" and type(id) == "number" and GetMacroItem then
        local _, link = GetMacroItem(id)
        if link then itemID = tonumber(link:match("item:(%d+)")) end
    end
    if not itemID then return nil end
    if C_Item and C_Item.GetItemCooldown then
        local s, d = C_Item.GetItemCooldown(itemID)
        if s then return s, d or 0 end
    end
    if GetItemCooldown then
        local s, d = GetItemCooldown(itemID)
        if s then return s, d or 0 end
    end
    return nil
end

-- Motivo por el que la tecla no se puede usar, o nil. Todas las comparaciones
-- van envueltas en pcall para tolerar "secret numbers" en combate.
local function GetAlertReason(slot)
    if not slot then return nil end
    local okHas, has = pcall(HasAction, slot)
    if not okHas or not has then return nil end

    if cfg("alertOnCD") then
        local ok, reason = pcall(function()
            local start, duration = GetSpellCooldownForSlot(slot)
            if not start then start, duration = GetItemCooldownForSlot(slot) end
            if not start then start, duration = GetActionCooldown(slot) end
            if type(start) ~= "number" or type(duration) ~= "number" then return nil end
            if start <= 0 or duration <= 0 then return nil end
            if IsGCD(start, duration) then return nil end
            local remaining = start + duration - GetTime()
            if remaining <= 0.1 then return nil end
            return ("CD %.1fs"):format(remaining)
        end)
        if ok and reason then return reason end
    end

    if cfg("alertOnUnusable") then
        local ok, reason = pcall(function()
            local isUsable, notEnoughMana = IsUsableAction(slot)
            if isUsable == false then
                return notEnoughMana and "sin recurso" or "no usable"
            end
            return nil
        end)
        if ok and reason then return reason end
    end

    if cfg("alertOnRange") then
        local ok, reason = pcall(function()
            local inRange = IsActionInRange(slot)
            if inRange == false or inRange == 0 then
                return "fuera de rango"
            end
            return nil
        end)
        if ok and reason then return reason end
    end

    return nil
end

-- ── Frame captador de teclas ─────────────────────────────────

local frame = CreateFrame("Frame", ADDON .. "Frame", UIParent)
frame:SetAllPoints(UIParent)
frame:EnableKeyboard(true)
frame:SetPropagateKeyboardInput(true)  -- NO consume el input

local lastAlert = 0
local debugMode = false

frame:SetScript("OnKeyDown", function(_, key)
    if not cfg("enabled") then return end
    if not key or MODIFIER_KEYS[key] then return end

    local slot = GetActionSlotForKey(key)
    if not slot then return end

    local reason = GetAlertReason(slot)
    if not reason then return end

    local now = GetTime()
    if (now - lastAlert) <= cfg("alertCooldown") then return end
    lastAlert = now

    PlaySound(cfg("soundID"), "Master")
    if debugMode then
        print(("|cffffff00[CDA]|r tecla=%s slot=%d motivo=%s"):format(key, slot, reason))
    end
end)

-- ── UI ───────────────────────────────────────────────────────

local SOUND_PRESETS = {
    {    882, "Spell fail (default)" },
    {   8959, "Raid warning" },
    {  12867, "Alarma / alerta" },
    {   3332, "Gong" },
    {   5275, "Quest complete" },
    { 567481, "Quest turn-in" },
    { 568008, "Glyph activation" },
    {   1149, "Ready check" },
    {  11466, "Map ping" },
    {    846, "Capture flag" },
    {   6768, "Error corto" },
    {    870, "Raid warning 2" },
    {  37881, "Ping objetivo" },
    {   3175, "Pop UI" },
}

local uiFrame

local function BuildUI()
    if uiFrame then return uiFrame end

    local f = CreateFrame("Frame", "CooldownAlertUI", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(360, 440)
    f:SetPoint("CENTER")
    f:SetMovable(true); f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("DIALOG")
    tinsert(UISpecialFrames, "CooldownAlertUI")

    f.TitleText:SetText("CooldownAlert — Sonido")

    local curLbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    curLbl:SetPoint("TOPLEFT", 15, -32)
    curLbl:SetText("ID actual:")

    f.current = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.current:SetPoint("LEFT", curLbl, "RIGHT", 8, 0)

    local eb = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    eb:SetSize(80, 22)
    eb:SetPoint("TOPLEFT", 20, -58)
    eb:SetAutoFocus(false)
    eb:SetNumeric(true)
    eb:SetMaxLetters(10)
    f.input = eb

    local play = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    play:SetSize(62, 22)
    play:SetPoint("LEFT", eb, "RIGHT", 10, 0)
    play:SetText("Probar")
    play:SetScript("OnClick", function()
        local id = tonumber(eb:GetText())
        if id then PlaySound(id, "Master") end
    end)

    local apply = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    apply:SetSize(70, 22)
    apply:SetPoint("LEFT", play, "RIGHT", 4, 0)
    apply:SetText("Aplicar")
    apply:SetScript("OnClick", function()
        local id = tonumber(eb:GetText())
        if not id then return end
        CooldownAlertDB.soundID = id
        PlaySound(id, "Master")
        f.current:SetText(tostring(id))
    end)

    local sep = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sep:SetPoint("TOPLEFT", 15, -90)
    sep:SetText("Presets:")

    local scroll = CreateFrame("ScrollFrame", "CooldownAlertUIScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 15, -108)
    scroll:SetPoint("BOTTOMRIGHT", -32, 15)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(300, #SOUND_PRESETS * 28)
    scroll:SetScrollChild(content)

    for i, preset in ipairs(SOUND_PRESETS) do
        local id, name = preset[1], preset[2]
        local row = CreateFrame("Frame", nil, content)
        row:SetSize(300, 26)
        row:SetPoint("TOPLEFT", 0, -(i-1) * 28)

        local nameFS = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        nameFS:SetPoint("LEFT", 2, 0)
        nameFS:SetWidth(150); nameFS:SetJustifyH("LEFT")
        nameFS:SetText(name)

        local idFS = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        idFS:SetPoint("LEFT", nameFS, "RIGHT", 0, 0)
        idFS:SetWidth(55); idFS:SetJustifyH("LEFT")
        idFS:SetText(tostring(id))

        local pb = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        pb:SetSize(40, 20)
        pb:SetPoint("LEFT", idFS, "RIGHT", 2, 0)
        pb:SetText("▶")
        pb:SetScript("OnClick", function() PlaySound(id, "Master") end)

        local sb = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        sb:SetSize(50, 20)
        sb:SetPoint("LEFT", pb, "RIGHT", 2, 0)
        sb:SetText("Usar")
        sb:SetScript("OnClick", function()
            CooldownAlertDB.soundID = id
            PlaySound(id, "Master")
            f.current:SetText(tostring(id))
            eb:SetText(tostring(id))
        end)
    end

    f:SetScript("OnShow", function()
        local id = cfg("soundID")
        f.current:SetText(tostring(id))
        eb:SetText(tostring(id))
        eb:ClearFocus()
    end)

    uiFrame = f
    return f
end

local function ToggleUI()
    local f = BuildUI()
    if f:IsShown() then f:Hide() else f:Show() end
end

-- ── Slash commands ───────────────────────────────────────────

SLASH_COOLDOWNALERT1 = "/cda"
SLASH_COOLDOWNALERT2 = "/cooldownalert"

local function printHelp()
    print("|cffffff00[CooldownAlert] v" .. VERSION .. "|r")
    print("  /cda on|off             — activar / desactivar")
    print("  /cda cd on|off          — alerta por cooldown real")
    print("  /cda unusable on|off    — alerta por no usable (maná/stance)")
    print("  /cda range on|off       — alerta por fuera de rango")
    print("  /cda sound <id>         — cambiar sonido (prueba el ID)")
    print("  /cda test               — reproducir sonido actual")
    print("  /cda ui                 — abrir interfaz para elegir sonido")
    print("  /cda debug              — togglear prints de depuración")
    print("  /cda scan               — escanear tus teclas de uso y estado")
    print("  /cda capture            — pulsa cualquier tecla y muestra su nombre/binding")
    print("  /cda reset              — restaurar valores por defecto")
end

local function toggleFlag(name, label, msg)
    if msg == "on" then
        CooldownAlertDB[name] = true
        print(("|cff00ff00[CDA]|r %s: ON"):format(label))
    elseif msg == "off" then
        CooldownAlertDB[name] = false
        print(("|cffff4444[CDA]|r %s: OFF"):format(label))
    else
        print(("|cffffff00[CDA]|r %s actualmente: %s"):format(label, cfg(name) and "ON" or "OFF"))
    end
end

SlashCmdList["COOLDOWNALERT"] = function(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")

    if msg == "" or msg == "help" then
        printHelp()
        return
    end

    if msg == "on" or msg == "off" then
        toggleFlag("enabled", "Addon", msg)
        return
    end

    local sub, arg = msg:match("^(%S+)%s*(.-)$")
    arg = arg or ""

    if sub == "cd" then
        toggleFlag("alertOnCD", "Alerta por CD", arg)

    elseif sub == "unusable" then
        toggleFlag("alertOnUnusable", "Alerta por no usable", arg)

    elseif sub == "range" then
        toggleFlag("alertOnRange", "Alerta por rango", arg)

    elseif sub == "sound" then
        local id = tonumber(arg)
        if not id then
            print("|cffff4444[CDA]|r Uso: /cda sound <número>")
            return
        end
        CooldownAlertDB.soundID = id
        PlaySound(id, "Master")
        print("|cffffff00[CDA]|r Sonido cambiado a ID: " .. id)

    elseif sub == "test" then
        PlaySound(cfg("soundID"), "Master")
        print("|cffffff00[CDA]|r test (soundID=" .. cfg("soundID") .. ")")

    elseif sub == "ui" or sub == "config" then
        ToggleUI()

    elseif sub == "debug" then
        debugMode = not debugMode
        print("|cffffff00[CDA]|r debug: " .. (debugMode and "ON" or "OFF"))

    elseif sub == "scan" then
        print("|cffffff00[CDA]|r Scan de tus teclas:")
        -- Lista de teclas del usuario. Cada entrada es {label, key, modifierPrefix}
        local entries = {
            {"Q","Q",""},   {"E","E",""},   {"F","F",""},   {"G","G",""},
            {"T","T",""},   {"R","R",""},   {"º","º",""},
            {"F1","F1",""}, {"F2","F2",""}, {"F3","F3",""}, {"F4","F4",""},
            {"Shift-1","1","SHIFT-"}, {"Shift-2","2","SHIFT-"},
            {"Shift-3","3","SHIFT-"}, {"Shift-4","4","SHIFT-"},
            {"Shift-5","5","SHIFT-"},
            {"Shift-Q","Q","SHIFT-"}, {"Shift-E","E","SHIFT-"},
            {"Shift-F","F","SHIFT-"}, {"Shift-G","G","SHIFT-"},
            {"Shift-T","T","SHIFT-"}, {"Shift-R","R","SHIFT-"},
        }
        for _, e in ipairs(entries) do
            local label, key, mod = e[1], e[2], e[3]
            local binding = GetBindingAction(mod .. key, true)
            if not binding or binding == "" then binding = GetBindingAction(key, true) end
            local btnName = binding and BINDING_TO_BUTTON[binding]
            local btn = btnName and _G[btnName]
            local slot = btn and ComputeSlotFromButton(btnName, btn)

            if not binding or binding == "" then
                print(("  [%-8s] |cff808080sin binding|r"):format(label))
            elseif not btnName then
                print(("  [%-8s] binding=|cffffaa00%s|r  (NO mapeada — pégame este nombre)"):format(label, binding))
            elseif not btn then
                print(("  [%-8s] binding=%s  btnName=|cffff4444%s|r (no existe el frame)"):format(label, binding, btnName))
            elseif type(slot) ~= "number" or slot <= 0 then
                print(("  [%-8s] binding=%s  btn=%s  |cffff4444no se pudo calcular slot|r"):format(label, binding, btnName))
            elseif not HasAction(slot) then
                print(("  [%-8s] binding=%s  slot=%d |cff808080vacío|r"):format(label, binding, slot))
            else
                local cdTxt = "|cff00ff00no|r"
                pcall(function()
                    local start, dur = GetSpellCooldownForSlot(slot)
                    if not start then start, dur = GetItemCooldownForSlot(slot) end
                    if not start then start, dur = GetActionCooldown(slot) end
                    if type(start) == "number" and type(dur) == "number"
                       and start > 0 and dur > 0 and not IsGCD(start, dur) then
                        local rem = start + dur - GetTime()
                        if rem > 0.1 then
                            cdTxt = ("|cffff4444%.1fs|r"):format(rem)
                        end
                    end
                end)
                local usableTxt = "|cff00ff00sí|r"
                local extraTxt = ""
                pcall(function()
                    local isUsable, notEnoughMana = IsUsableAction(slot)
                    if isUsable == false then usableTxt = "|cffff4444no|r" end
                    if notEnoughMana then extraTxt = " |cffffaa00(sin recurso)|r" end
                end)
                print(("  [%-8s] slot=%-3d CD=%s usable=%s%s"):format(label, slot, cdTxt, usableTxt, extraTxt))
            end
        end

    elseif sub == "capture" then
        if not _G.CooldownAlertCaptureFrame then
            local cf = CreateFrame("Frame", "CooldownAlertCaptureFrame", UIParent)
            cf:SetAllPoints(UIParent)
            cf:EnableKeyboard(true)
            cf:SetPropagateKeyboardInput(true)
            cf:Hide()
            cf:SetScript("OnKeyDown", function(self, key)
                if MODIFIER_KEYS[key] then return end
                local prefix = GetModifierPrefix()
                local bind = GetBindingAction(prefix .. key, true)
                if not bind or bind == "" then bind = GetBindingAction(key, true) end
                local btnName = bind and BINDING_TO_BUTTON[bind]
                local btn = btnName and _G[btnName]
                local slot = btn and ComputeSlotFromButton(btnName, btn)
                print(("|cffffff00[CDA capture]|r key=|cffffffff%s%s|r  binding=|cffffffff%s|r  button=%s  slot=%s"):format(
                    prefix, tostring(key),
                    (bind and bind ~= "") and bind or "(ninguno)",
                    btnName or "-",
                    slot and tostring(slot) or "-"
                ))
                self:Hide()
            end)
            cf:SetScript("OnShow", function(self)
                C_Timer.After(10, function()
                    if self:IsShown() then
                        self:Hide()
                        print("|cffff4444[CDA capture]|r timeout (10s)")
                    end
                end)
            end)
        end
        print("|cffffff00[CDA]|r Pulsa cualquier tecla en los próximos 10s...")
        _G.CooldownAlertCaptureFrame:Show()

    elseif sub == "reset" then
        wipe(CooldownAlertDB)
        for k, v in pairs(DEFAULTS) do CooldownAlertDB[k] = v end
        print("|cff00ff00[CDA]|r Configuración restaurada.")

    else
        printHelp()
    end
end

-- ── Init ─────────────────────────────────────────────────────
local init = CreateFrame("Frame")
init:RegisterEvent("PLAYER_LOGIN")
init:SetScript("OnEvent", function()
    for k, v in pairs(DEFAULTS) do
        if CooldownAlertDB[k] == nil then CooldownAlertDB[k] = v end
    end
    print(("|cff00ff00[CooldownAlert]|r v%s cargado. /cda para ayuda."):format(VERSION))
end)
