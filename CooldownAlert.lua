-- ============================================================
--  CooldownAlert - warriorkekw
--  Suena un aviso cuando pulsas una tecla de acción que está
--  en cooldown real, no se puede usar (sin mana, stance, etc)
--  o (opcional) está fuera de rango. Ignora el GCD.
-- ============================================================

local ADDON   = "CooldownAlert"
local VERSION = "1.3"

-- ── Config por defecto (persistente via SavedVariables) ──────
local DEFAULTS = {
    enabled       = true,
    alertOnCD     = true,    -- CD real
    alertOnUnusable = true,  -- sin maná/rage, stance incorrecta, etc
    alertOnRange  = false,   -- fuera de rango (ruidoso, off por defecto)
    alertCooldown = 0.3,     -- anti-spam (seg)
    soundID       = 882,     -- 882 = spell error genérico
    alertOnReady  = true,    -- suena cuando una habilidad trackeada sale de CD
    soundIDReady  = 12867,   -- alarma/alerta — distinto del "fallo"
    trackedSpells = {},      -- { [spellID] = "cd" | "usable" }
    pulseEnabled  = true,    -- mostrar icono en pantalla al dispararse el alert
    pulseLocked   = true,    -- si está locked no se puede arrastrar
    pulseSize     = 64,
    pulsePosX     = 0,
    pulsePosY     = 120,     -- centro vertical + 120 = aprox encima del personaje
    pulseDuration = 1.2,     -- segundos que está visible antes de desaparecer
    minimapHide   = false,
    minimapAngle  = -math.pi / 4,  -- posición inicial (arriba-derecha)
}

CooldownAlertDB = CooldownAlertDB or {}
local function cfg(key)
    if CooldownAlertDB[key] == nil then CooldownAlertDB[key] = DEFAULTS[key] end
    return CooldownAlertDB[key]
end

local debugMode = false
local lastAlert = 0

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

-- ── Detección de "habilidad lista" ───────────────────────────
-- Para cada spellID trackeado guardamos si la última vez estaba lista.
-- En cada SPELL_UPDATE_COOLDOWN comprobamos transiciones false → true
-- y tocamos el sonido de "ready". El estado inicial se cachea sin sonar.

local readyState = {}
local lastReadyAlert = 0

local function GetSpellDisplay(spellID)
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spellID)
        if info then return info.name, info.iconID end
    end
    if GetSpellInfo then
        local name, _, icon = GetSpellInfo(spellID)
        return name, icon
    end
    return nil, nil
end

-- Modo "cd": listo = fuera de CD (ignora GCD). Bueno para CDs largos.
-- Modo "usable": listo = C_Spell.IsSpellUsable (sin CD). Bueno para hechizos
-- resource-gated sin CD (p. ej. Void Ray del DH Devourer → requiere fury).
local TRACK_MODES = { cd = true, usable = true }
local DEFAULT_TRACK_MODE = "cd"

local function NormalizeMode(mode)
    if type(mode) == "string" and TRACK_MODES[mode] then return mode end
    return DEFAULT_TRACK_MODE
end

-- Nota: en Midnight (11.2+) algunos valores devueltos por las APIs de CD
-- pueden ser "secret numbers" opacos que lanzan al comparar en combate.
-- Por eso todas las operaciones van envueltas en pcall — el mismo patrón
-- que usa GetAlertReason (ver CLAUDE.md).
-- En Midnight ciertos valores devueltos por C_Spell.GetSpellCooldown vienen
-- "taintados" (secret numbers) y lanzan al compararlos. Blizzard sólo ofusca
-- valores distintos de 0, así que si la comparación lanza → SÍ hay CD en
-- marcha. Devolvemos false ("no ready") en ese caso. Cuando el CD expira,
-- duration pasa a 0 real y la comparación funciona normalmente → true.
local function IsSpellReadyCD(spellID)
    if not C_Spell or not C_Spell.GetSpellCooldown then return true end
    local ok, info = pcall(C_Spell.GetSpellCooldown, spellID)
    if not ok then return true end  -- API inaccesible, fallback seguro
    if not info then return true end
    local okInner, ready = pcall(function()
        local duration = info.duration
        if type(duration) ~= "number" or duration <= 0 then return true end
        local startTime = info.startTime or 0
        if IsGCD(startTime, duration) then return true end
        local remaining = startTime + duration - GetTime()
        return remaining <= 0.1
    end)
    if not okInner then
        -- Comparación lanzó por secret-number → en CD real (Blizzard sólo ofusca
        -- valores no-0). Este path solo se toma si el hechizo NO está en action
        -- bars (sino IsSpellReadyViaSlot lo resuelve antes). No se spamea en debug.
        return false
    end
    return ready
end

-- "usable" = puede lanzarse AHORA → CD terminado Y IsSpellUsable=true.
-- Sin el chequeo de CD, un hechizo con CD (p. ej. Void Ray en Meta del DH)
-- dispararía al cruzar el umbral de recurso aunque siguiera en cooldown.
local function IsSpellReadyUsable(spellID)
    if not IsSpellReadyCD(spellID) then return false end
    if C_Spell and C_Spell.IsSpellUsable then
        local ok, usable = pcall(C_Spell.IsSpellUsable, spellID)
        if ok then return usable and true or false end
    end
    if IsUsableSpell then
        local ok, usable = pcall(IsUsableSpell, spellID)
        if ok then return usable and true or false end
    end
    return true  -- si no podemos saberlo, no generamos ruido
end

-- ── Detección via action slot (inmune al taint de Midnight) ─────
-- En combate, C_Spell.GetSpellCooldown y C_Spell.IsSpellUsable pueden devolver
-- "secret numbers" que lanzan al comparar — haciendo que nuestra detección por
-- spellID falle todo el combate. IsUsableAction(slot) devuelve booleanos que
-- NO se taintean, así que es la vía robusta. El addon ya usa este patrón en
-- el alert de "tecla-en-CD" y funciona en combate.
local spellSlotCache = {}

local function ClearSpellSlotCache()
    wipe(spellSlotCache)
end

local function SlotHasSpell(slot, spellID)
    local okInfo, aType, aId = pcall(GetActionInfo, slot)
    if not okInfo then return false end
    if aType == "spell" and aId == spellID then return true end
    if aType == "macro" and type(aId) == "number" and GetMacroSpell then
        return GetMacroSpell(aId) == spellID
    end
    return false
end

-- NOTA: cacheamos agresivamente y NO revalidamos el contenido del slot en cada
-- llamada. Razón: en formas tipo Meta del DH, el slot original cambia su
-- contenido (p.ej. a "Cancelar Meta") pero `IsUsableAction(slot)` sigue
-- devolviendo un booleano coherente para toda la duración de la forma, con lo
-- que las transiciones se detectan correctamente al volver a la forma base +
-- iniciar CD. La invalidación del cache se hace por eventos (ver readyFrame).
local function FindActionSlotForSpell(spellID)
    local cached = spellSlotCache[spellID]
    if cached ~= nil then return cached end
    for slot = 1, 180 do
        local okHas, has = pcall(HasAction, slot)
        if okHas and has and SlotHasSpell(slot, spellID) then
            spellSlotCache[spellID] = slot
            return slot
        end
    end
    spellSlotCache[spellID] = false
    return false
end

-- Devuelve true/false si puede determinarse via slot, o nil si no se encuentra.
local function IsSpellReadyViaSlot(spellID, mode)
    local slot = FindActionSlotForSpell(spellID)
    if not slot or type(slot) ~= "number" then return nil end
    local ok, isUsable, notEnoughMana = pcall(IsUsableAction, slot)
    if not ok then return nil end
    if mode == "usable" then
        -- usable = CD terminado Y recursos OK → IsUsableAction exactamente
        return isUsable and true or false
    else
        -- cd = off-CD (ignora recursos). notEnoughMana=true implica off-CD.
        return (isUsable or notEnoughMana) and true or false
    end
end

local function IsSpellReady(spellID, mode)
    -- Preferido: via slot (booleanos, inmune al taint)
    local viaSlot = IsSpellReadyViaSlot(spellID, mode)
    if viaSlot ~= nil then return viaSlot end
    -- Fallback: APIs por spellID (pueden fallar en combate si el spell no está
    -- en barras y Midnight tiente el CD)
    if mode == "usable" then return IsSpellReadyUsable(spellID) end
    return IsSpellReadyCD(spellID)
end

-- forward decl: ShowPulse se define más abajo, se resuelve en runtime
local ShowPulse

local function CheckTrackedSpells()
    local tracked = CooldownAlertDB and CooldownAlertDB.trackedSpells
    if not tracked then return end
    local alertEnabled = cfg("enabled") and cfg("alertOnReady")
    local now = GetTime()
    for spellID, mode in pairs(tracked) do
        mode = NormalizeMode(mode)
        local nowReady = IsSpellReady(spellID, mode)
        local wasReady = readyState[spellID]
        if debugMode and nowReady ~= wasReady then
            print(("|cffffff00[CDA]|r trans spell=%d [%s]  %s→%s  alertEnabled=%s"):format(
                spellID, mode, tostring(wasReady), tostring(nowReady), tostring(alertEnabled)))
        end
        if alertEnabled and nowReady and wasReady == false then
            local dt = now - lastReadyAlert
            if dt > cfg("alertCooldown") then
                PlaySound(cfg("soundIDReady"), "Master")
                if ShowPulse then ShowPulse(spellID) end
                lastReadyAlert = now
                if debugMode then
                    print(("|cff00ff00[CDA]|r 🔔 FIRED spell=%d [%s]"):format(spellID, mode))
                end
            elseif debugMode then
                print(("|cffff4444[CDA]|r SILENCED (antispam %.2fs < %.2fs) spell=%d"):format(
                    dt, cfg("alertCooldown"), spellID))
            end
        end
        readyState[spellID] = nowReady
    end
end

local function TrackSpell(spellID, mode)
    spellID = tonumber(spellID)
    if not spellID or spellID <= 0 then return false, "ID inválido" end
    CooldownAlertDB.trackedSpells = CooldownAlertDB.trackedSpells or {}
    if CooldownAlertDB.trackedSpells[spellID] then return false, "ya trackeado" end
    CooldownAlertDB.trackedSpells[spellID] = NormalizeMode(mode)
    -- Asume "lista" — el próximo evento corregirá sin sonar (nil→false no dispara)
    readyState[spellID] = true
    return true
end

local function SetSpellMode(spellID, mode)
    spellID = tonumber(spellID)
    if not spellID or not CooldownAlertDB.trackedSpells then return false end
    if not CooldownAlertDB.trackedSpells[spellID] then return false end
    CooldownAlertDB.trackedSpells[spellID] = NormalizeMode(mode)
    readyState[spellID] = true  -- reset para no disparar de inmediato tras cambio
    return true
end

local function UntrackSpell(spellID)
    spellID = tonumber(spellID)
    if not spellID or not CooldownAlertDB.trackedSpells then return false end
    if not CooldownAlertDB.trackedSpells[spellID] then return false end
    CooldownAlertDB.trackedSpells[spellID] = nil
    readyState[spellID] = nil
    return true
end

-- ── Pulse: icono flotante al dispararse el alert de "lista" ──

local pulseFrame

local function CreatePulseFrame()
    local size = cfg("pulseSize")
    local f = CreateFrame("Frame", "CooldownAlertPulse", UIParent)
    f:SetSize(size, size)
    f:SetFrameStrata("HIGH")
    f:Hide()
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetClampedToScreen(true)

    f:ClearAllPoints()
    f:SetPoint("CENTER", UIParent, "CENTER", cfg("pulsePosX"), cfg("pulsePosY"))

    -- Borde oscuro (pequeño inset para que se vea el borde alrededor del icono)
    f.border = f:CreateTexture(nil, "BACKGROUND")
    f.border:SetColorTexture(0, 0, 0, 1)
    f.border:SetAllPoints(f)

    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local inset = math.max(2, math.floor(size * 0.05 + 0.5))
    f.icon:SetPoint("TOPLEFT", f, "TOPLEFT", inset, -inset)
    f.icon:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -inset, inset)

    f.label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.label:SetPoint("TOP", f, "BOTTOM", 0, -4)
    f.label:SetShadowOffset(1, -1)

    local ag = f:CreateAnimationGroup()
    local fadeOut = ag:CreateAnimation("Alpha")
    fadeOut:SetFromAlpha(1)
    fadeOut:SetToAlpha(0)
    fadeOut:SetDuration(cfg("pulseDuration"))
    fadeOut:SetStartDelay(0.2)
    fadeOut:SetSmoothing("OUT")
    ag:SetScript("OnPlay", function() f:Show() end)
    ag:SetScript("OnFinished", function()
        if CooldownAlertDB.pulseLocked ~= false then f:Hide() end
    end)
    f.ag = ag
    f.fadeOut = fadeOut

    -- Drag sólo cuando está unlocked
    f:SetScript("OnDragStart", function(self)
        if not CooldownAlertDB.pulseLocked then self:StartMoving() end
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local _, _, _, x, y = self:GetPoint(1)
        CooldownAlertDB.pulsePosX = math.floor(x + 0.5)
        CooldownAlertDB.pulsePosY = math.floor(y + 0.5)
    end)

    return f
end

-- Nota: ShowPulse se declaró arriba como forward decl para que CheckTrackedSpells
-- pueda referenciarlo. Aquí asignamos al upvalue, no declaramos un nuevo local.
ShowPulse = function(spellID, force)
    if not force and not cfg("pulseEnabled") then return end
    if not pulseFrame then pulseFrame = CreatePulseFrame() end
    local name, iconID = GetSpellDisplay(spellID)
    pulseFrame.icon:SetTexture(iconID or "Interface\\ICONS\\INV_Misc_QuestionMark")
    pulseFrame.label:SetText(name or ("spell " .. tostring(spellID)))
    pulseFrame.ag:Stop()
    pulseFrame:SetAlpha(1)
    pulseFrame.ag:Play()
end

local function ApplyPulseSettings()
    if not pulseFrame then return end
    local size = cfg("pulseSize")
    pulseFrame:SetSize(size, size)
    local inset = math.max(2, math.floor(size * 0.05 + 0.5))
    pulseFrame.icon:ClearAllPoints()
    pulseFrame.icon:SetPoint("TOPLEFT", pulseFrame, "TOPLEFT", inset, -inset)
    pulseFrame.icon:SetPoint("BOTTOMRIGHT", pulseFrame, "BOTTOMRIGHT", -inset, inset)
    pulseFrame.fadeOut:SetDuration(cfg("pulseDuration"))
    pulseFrame:ClearAllPoints()
    pulseFrame:SetPoint("CENTER", UIParent, "CENTER", cfg("pulsePosX"), cfg("pulsePosY"))
end

-- En modo "unlock" mostramos el frame estático con un placeholder para
-- poder arrastrarlo. En modo "lock" vuelve a ser invisible hasta el pulse.
local function SetPulseUnlocked(unlocked)
    CooldownAlertDB.pulseLocked = not unlocked
    if not pulseFrame then pulseFrame = CreatePulseFrame() end
    pulseFrame.ag:Stop()
    pulseFrame:EnableMouse(unlocked)
    if unlocked then
        pulseFrame.icon:SetTexture("Interface\\AddOns\\CooldownAlert\\Textures\\icon")
        pulseFrame.label:SetText("|cffffcc00Arrastra para mover|r")
        pulseFrame:SetAlpha(0.85)
        pulseFrame:Show()
    else
        pulseFrame:Hide()
    end
end

local readyFrame = CreateFrame("Frame")
readyFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
readyFrame:RegisterEvent("SPELL_UPDATE_USABLE")
readyFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
-- Sólo invalidamos el cache ante cambios iniciados por el usuario
-- (ACTIONBAR_SLOT_CHANGED). Los cambios por stance/form NO deben invalidar:
-- en formas tipo Meta del DH, el slot pasa a contener la ability-toggle
-- (Collapsing Stars, Cancelar Meta, etc.), y aunque el spellID no coincida,
-- `IsUsableAction(slotCacheado)` sigue devolviendo un booleano que refleja
-- correctamente la transición cuando la forma acaba y el CD arranca.
readyFrame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
readyFrame:SetScript("OnEvent", function(_, evt)
    if evt == "ACTIONBAR_SLOT_CHANGED" then
        ClearSpellSlotCache()
    end
    pcall(CheckTrackedSpells)
end)

-- Poll periódico como red de seguridad: SPELL_UPDATE_COOLDOWN no siempre
-- dispara al ACABAR un CD (sólo al empezar/resetear), y algunos hechizos
-- con CD dinámico (p. ej. Void Ray en Meta del DH) pueden saltarse eventos.
-- Coste: 1 tabla-scan cada 0.25s cuando hay spells trackeados.
local POLL_INTERVAL = 0.25
local pollAccum = 0
readyFrame:SetScript("OnUpdate", function(_, elapsed)
    pollAccum = pollAccum + elapsed
    if pollAccum < POLL_INTERVAL then return end
    pollAccum = 0
    local tracked = CooldownAlertDB and CooldownAlertDB.trackedSpells
    if not tracked or not next(tracked) then return end
    pcall(CheckTrackedSpells)
end)

-- ── Frame captador de teclas ─────────────────────────────────

local frame = CreateFrame("Frame", ADDON .. "Frame", UIParent)
frame:SetAllPoints(UIParent)
frame:EnableKeyboard(true)
frame:SetPropagateKeyboardInput(true)  -- NO consume el input

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

local function GetPresetName(id)
    for _, p in ipairs(SOUND_PRESETS) do
        if p[1] == id then return p[2] end
    end
    return nil
end

-- ── Sound popup (scrollable dropdown, estilo CDPulse) ────────

local POPUP_VISIBLE_ITEMS = 10
local POPUP_ITEM_HEIGHT   = 22

local SoundPopup, SoundOverlay

local function EnsureSoundPopup()
    if SoundPopup then return end

    SoundOverlay = CreateFrame("Frame", nil, UIParent)
    SoundOverlay:SetAllPoints(UIParent)
    SoundOverlay:EnableMouse(true)
    SoundOverlay:SetFrameStrata("FULLSCREEN_DIALOG")
    SoundOverlay:Hide()

    SoundPopup = CreateFrame("Frame", "CooldownAlertSoundPopup", UIParent, "BackdropTemplate")
    SoundPopup:SetFrameStrata("FULLSCREEN_DIALOG")
    SoundPopup:SetClampedToScreen(true)
    SoundPopup:EnableMouse(true)
    SoundPopup:Hide()
    SoundPopup:SetBackdrop({
        bgFile   = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile     = true, tileSize = 16, edgeSize = 12,
        insets   = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    SoundPopup:SetBackdropColor(0.06, 0.06, 0.06, 0.98)

    SoundOverlay:SetScript("OnMouseDown", function() SoundPopup:Hide() end)
    SoundPopup:SetScript("OnHide", function() SoundOverlay:Hide() end)

    local scroll = CreateFrame("ScrollFrame", nil, SoundPopup, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 6, -6)
    scroll:SetPoint("BOTTOMRIGHT", -26, 6)
    SoundPopup.scroll = scroll

    SoundPopup.buttons = {}
    for i = 1, POPUP_VISIBLE_ITEMS do
        local b = CreateFrame("Button", nil, SoundPopup)
        b:SetHeight(POPUP_ITEM_HEIGHT)
        b:SetPoint("TOPLEFT", SoundPopup, "TOPLEFT", 8, -(6 + (i - 1) * POPUP_ITEM_HEIGHT))
        b:SetPoint("RIGHT", scroll, "RIGHT", 0, 0)

        b.highlight = b:CreateTexture(nil, "HIGHLIGHT")
        b.highlight:SetAllPoints()
        b.highlight:SetColorTexture(1, 0.82, 0, 0.18)

        b.id = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        b.id:SetPoint("RIGHT", -38, 0)
        b.id:SetJustifyH("RIGHT")

        b.name = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.name:SetPoint("LEFT", 2, 0)
        b.name:SetPoint("RIGHT", b.id, "LEFT", -6, 0)
        b.name:SetJustifyH("LEFT"); b.name:SetWordWrap(false)

        b.preview = CreateFrame("Button", nil, b)
        b.preview:SetSize(18, 18)
        b.preview:SetPoint("RIGHT", -18, 0)
        local tex = b.preview:CreateTexture(nil, "ARTWORK")
        tex:SetAllPoints()
        if tex.SetAtlas then
            tex:SetAtlas("voicechat-icon-speaker")
        else
            tex:SetTexture("Interface\\COMMON\\VoiceChat-Speaker")
        end
        b.preview:SetScript("OnClick", function(self)
            if self:GetParent().value then PlaySound(self:GetParent().value, "Master") end
        end)

        b.check = b:CreateTexture(nil, "OVERLAY")
        b.check:SetTexture("Interface/Buttons/UI-CheckBox-Check")
        b.check:SetSize(14, 14)
        b.check:SetPoint("RIGHT", -2, 0)
        b.check:Hide()

        b:SetScript("OnClick", function(self)
            if SoundPopup.onSelect and self.value then SoundPopup.onSelect(self.value) end
            SoundPopup:Hide()
        end)
        SoundPopup.buttons[i] = b
    end

    function SoundPopup:Refresh()
        local items  = self.items or {}
        local total  = #items
        local offset = FauxScrollFrame_GetOffset(self.scroll) or 0
        for i = 1, POPUP_VISIBLE_ITEMS do
            local idx, b = i + offset, self.buttons[i]
            if idx <= total then
                local id, name = items[idx][1], items[idx][2]
                b.value = id
                b.name:SetText(name)
                b.id:SetText(tostring(id))
                b.check:SetShown(self.selected == id)
                b:Show()
            else
                b.value = nil
                b:Hide()
            end
        end
        FauxScrollFrame_Update(self.scroll, total, POPUP_VISIBLE_ITEMS, POPUP_ITEM_HEIGHT)
    end

    scroll:SetScript("OnVerticalScroll", function(self, off)
        FauxScrollFrame_OnVerticalScroll(self, off, POPUP_ITEM_HEIGHT, function() SoundPopup:Refresh() end)
    end)

    SoundPopup:EnableMouseWheel(true)
    SoundPopup:SetScript("OnMouseWheel", function(_, delta)
        local cur = FauxScrollFrame_GetOffset(SoundPopup.scroll) or 0
        local maxOff = math.max(0, #(SoundPopup.items or {}) - POPUP_VISIBLE_ITEMS)
        local newOff = math.max(0, math.min(maxOff, cur - delta))
        FauxScrollFrame_SetOffset(SoundPopup.scroll, newOff)
        if SoundPopup.scroll.ScrollBar then
            SoundPopup.scroll.ScrollBar:SetValue(newOff * POPUP_ITEM_HEIGHT)
        end
        SoundPopup:Refresh()
    end)
end

local function OpenSoundPopup(anchor, selectedID, onSelect)
    EnsureSoundPopup()
    SoundPopup.items    = SOUND_PRESETS
    SoundPopup.selected = selectedID
    SoundPopup.onSelect = onSelect

    local h = POPUP_VISIBLE_ITEMS * POPUP_ITEM_HEIGHT + 12
    SoundPopup:SetHeight(h)
    SoundPopup:SetWidth(math.max(240, anchor:GetWidth() + 20))

    SoundPopup:ClearAllPoints()
    local bottom = anchor:GetBottom() or 0
    if bottom < (h + 30) then
        SoundPopup:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 4)
    else
        SoundPopup:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
    end

    SoundOverlay:Show(); SoundPopup:Show()
    FauxScrollFrame_SetOffset(SoundPopup.scroll, 0)
    if SoundPopup.scroll.ScrollBar then SoundPopup.scroll.ScrollBar:SetValue(0) end
    SoundPopup:Refresh()
end

-- ── Ventana principal ────────────────────────────────────────

local uiFrame

-- Crea el bloque de selección de sonido (dropdown + preview + ID manual).
-- Devuelve { refresh = fn, bottom = frame } para anclar más contenido debajo.
local function CreateSoundControls(parent, dbKey)
    local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lbl:SetPoint("TOPLEFT", 15, -10)
    lbl:SetText("Preset:")

    local dd = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    dd:SetSize(240, 24)
    dd:SetPoint("TOPLEFT", lbl, "BOTTOMLEFT", 0, -6)

    dd.label = dd:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    dd.label:SetPoint("LEFT", 8, 0)
    dd.label:SetPoint("RIGHT", -22, 0)
    dd.label:SetJustifyH("LEFT"); dd.label:SetWordWrap(false)

    dd.arrow = dd:CreateTexture(nil, "OVERLAY")
    dd.arrow:SetSize(12, 12)
    dd.arrow:SetPoint("RIGHT", -6, 0)
    dd.arrow:SetTexture("Interface/ChatFrame/ChatFrameExpandArrow")

    local eb  -- forward decl para cerrar sobre él

    local function refresh()
        local id = CooldownAlertDB[dbKey]
        local name = GetPresetName(id)
        if name then
            dd.label:SetText(name .. "  |cff888888(" .. id .. ")|r")
        else
            dd.label:SetText("|cffffcc00Custom|r  (" .. tostring(id) .. ")")
        end
        if eb then eb:SetText(tostring(id)) end
    end

    dd:SetScript("OnClick", function(self)
        if SoundPopup and SoundPopup:IsShown() then SoundPopup:Hide(); return end
        OpenSoundPopup(self, CooldownAlertDB[dbKey], function(id)
            CooldownAlertDB[dbKey] = id
            PlaySound(id, "Master")
            refresh()
        end)
    end)

    local preview = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    preview:SetSize(28, 24)
    preview:SetPoint("LEFT", dd, "RIGHT", 6, 0)
    local tex = preview:CreateTexture(nil, "ARTWORK")
    tex:SetSize(16, 16); tex:SetPoint("CENTER")
    if tex.SetAtlas then tex:SetAtlas("voicechat-icon-speaker")
    else tex:SetTexture("Interface\\COMMON\\VoiceChat-Speaker") end
    preview:SetScript("OnClick", function() PlaySound(CooldownAlertDB[dbKey], "Master") end)

    local manualLbl = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    manualLbl:SetPoint("TOPLEFT", dd, "BOTTOMLEFT", 0, -12)
    manualLbl:SetText("ID manual:")

    eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    eb:SetSize(90, 22)
    eb:SetPoint("LEFT", manualLbl, "RIGHT", 10, 0)
    eb:SetAutoFocus(false); eb:SetNumeric(true); eb:SetMaxLetters(10)

    local play = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    play:SetSize(60, 22)
    play:SetPoint("LEFT", eb, "RIGHT", 8, 0)
    play:SetText("Probar")
    play:SetScript("OnClick", function()
        local id = tonumber(eb:GetText()); if id then PlaySound(id, "Master") end
    end)

    local apply = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    apply:SetSize(68, 22)
    apply:SetPoint("LEFT", play, "RIGHT", 4, 0)
    apply:SetText("Aplicar")
    apply:SetScript("OnClick", function()
        local id = tonumber(eb:GetText()); if not id then return end
        CooldownAlertDB[dbKey] = id
        PlaySound(id, "Master")
        refresh()
    end)

    return { refresh = refresh, bottom = apply }
end

-- ── Tab "Habilidad lista": lista scrollable de spells trackeados ─────

local TRACKED_ROW_HEIGHT = 26
local TRACKED_VISIBLE    = 6

local function BuildTrackedList(parent, anchorTop)
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    frame:SetPoint("TOPLEFT", anchorTop, "BOTTOMLEFT", 0, -8)
    frame:SetPoint("RIGHT", parent, "RIGHT", -15, 0)
    frame:SetHeight(TRACKED_ROW_HEIGHT * TRACKED_VISIBLE + 12)
    frame:SetBackdrop({
        bgFile   = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(0, 0, 0, 0.5)

    local scroll = CreateFrame("ScrollFrame", nil, frame, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 6, -6)
    scroll:SetPoint("BOTTOMRIGHT", -26, 6)

    local rows = {}
    for i = 1, TRACKED_VISIBLE do
        local r = CreateFrame("Frame", nil, frame)
        r:SetHeight(TRACKED_ROW_HEIGHT)
        r:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -(6 + (i - 1) * TRACKED_ROW_HEIGHT))
        r:SetPoint("RIGHT", scroll, "RIGHT", 0, 0)

        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(18, 18)
        r.icon:SetPoint("LEFT", 2, 0)
        r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        r.remove = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
        r.remove:SetSize(22, 20)
        r.remove:SetPoint("RIGHT", -2, 0)
        r.remove:SetText("X")

        r.modeBtn = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
        r.modeBtn:SetSize(44, 20)
        r.modeBtn:SetPoint("RIGHT", r.remove, "LEFT", -4, 0)

        r.id = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        r.id:SetPoint("RIGHT", r.modeBtn, "LEFT", -6, 0)
        r.id:SetJustifyH("RIGHT")

        r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.name:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
        r.name:SetPoint("RIGHT", r.id, "LEFT", -6, 0)
        r.name:SetJustifyH("LEFT"); r.name:SetWordWrap(false)
        rows[i] = r
    end

    local function SetModeButtonAppearance(btn, mode)
        if mode == "usable" then
            btn:SetText("|cffffcc00USE|r")
        else
            btn:SetText("CD")
        end
    end

    local function Refresh()
        local tracked = CooldownAlertDB.trackedSpells or {}
        local ids = {}
        for id in pairs(tracked) do ids[#ids + 1] = id end
        table.sort(ids)

        local total  = #ids
        local offset = FauxScrollFrame_GetOffset(scroll) or 0
        for i = 1, TRACKED_VISIBLE do
            local idx, row = i + offset, rows[i]
            if idx <= total then
                local id = ids[idx]
                local mode = NormalizeMode(tracked[id])
                local name, iconID = GetSpellDisplay(id)
                row.icon:SetTexture(iconID or "Interface\\ICONS\\INV_Misc_QuestionMark")
                row.name:SetText(name or "|cff808080(desconocido)|r")
                row.id:SetText(tostring(id))
                SetModeButtonAppearance(row.modeBtn, mode)
                row.modeBtn:SetScript("OnClick", function()
                    local cur = NormalizeMode(CooldownAlertDB.trackedSpells[id])
                    SetSpellMode(id, cur == "cd" and "usable" or "cd")
                    Refresh()
                end)
                row.modeBtn:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_TOP")
                    GameTooltip:AddLine("Modo de tracking")
                    GameTooltip:AddLine("|cffaaaaaaCD:|r suena al salir de cooldown", 1, 1, 1)
                    GameTooltip:AddLine("|cffffcc00USE:|r suena cuando |cffffcc00IsSpellUsable|r pasa a true (recursos)", 1, 1, 1)
                    GameTooltip:AddLine("Click para alternar", 0.7, 0.7, 0.7)
                    GameTooltip:Show()
                end)
                row.modeBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
                row.remove:SetScript("OnClick", function()
                    UntrackSpell(id); Refresh()
                end)
                row:Show()
            else
                row:Hide()
            end
        end
        FauxScrollFrame_Update(scroll, total, TRACKED_VISIBLE, TRACKED_ROW_HEIGHT)

        if frame.countLabel then
            frame.countLabel:SetText(("%d trackead%s"):format(total, total == 1 and "a" or "as"))
        end
    end

    scroll:SetScript("OnVerticalScroll", function(self, off)
        FauxScrollFrame_OnVerticalScroll(self, off, TRACKED_ROW_HEIGHT, Refresh)
    end)
    frame:EnableMouseWheel(true)
    frame:SetScript("OnMouseWheel", function(_, delta)
        local cur = FauxScrollFrame_GetOffset(scroll) or 0
        local total = 0
        for _ in pairs(CooldownAlertDB.trackedSpells or {}) do total = total + 1 end
        local maxOff = math.max(0, total - TRACKED_VISIBLE)
        local newOff = math.max(0, math.min(maxOff, cur - delta))
        FauxScrollFrame_SetOffset(scroll, newOff)
        if scroll.ScrollBar then scroll.ScrollBar:SetValue(newOff * TRACKED_ROW_HEIGHT) end
        Refresh()
    end)

    return frame, Refresh
end

local function BuildUI()
    if uiFrame then return uiFrame end

    local f = CreateFrame("Frame", "CooldownAlertUI", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(360, 480)
    f:SetPoint("CENTER")
    f:SetMovable(true); f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("DIALOG")
    tinsert(UISpecialFrames, "CooldownAlertUI")

    f.TitleText:SetText("CooldownAlert")

    -- Tabs
    local TAB_NAMES = { "Al pulsar en CD", "Habilidad lista" }
    local tabs, tabFrames, tabIndicators = {}, {}, {}

    local function SelectTab(i)
        for j = 1, #tabFrames do
            tabFrames[j]:Hide()
            tabIndicators[j]:Hide()
            tabs[j]:SetNormalFontObject("GameFontNormal")
        end
        tabFrames[i]:Show()
        tabIndicators[i]:Show()
        tabs[i]:SetNormalFontObject("GameFontHighlight")
    end

    for i, name in ipairs(TAB_NAMES) do
        local btn = CreateFrame("Button", nil, f)
        btn:SetSize(140, 24)
        btn:SetNormalFontObject("GameFontNormal")
        btn:SetHighlightFontObject("GameFontHighlight")
        btn:SetText(name)
        if i == 1 then
            btn:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -30)
        else
            btn:SetPoint("LEFT", tabs[i-1], "RIGHT", 4, 0)
        end
        btn:SetScript("OnClick", function() SelectTab(i) end)
        tabs[i] = btn

        local ind = f:CreateTexture(nil, "ARTWORK")
        ind:SetColorTexture(1, 0.82, 0, 1)
        ind:SetHeight(2)
        ind:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)
        ind:SetPoint("TOPRIGHT", btn, "BOTTOMRIGHT", 0, -2)
        ind:Hide()
        tabIndicators[i] = ind

        local tf = CreateFrame("Frame", nil, f)
        tf:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -60)
        tf:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
        tf:Hide()
        tabFrames[i] = tf
    end

    -- Tab 1: Sonido al pulsar en CD
    local tab1 = tabFrames[1]
    local ctrl1 = CreateSoundControls(tab1, "soundID")

    local hint1 = tab1:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint1:SetPoint("TOPLEFT", tab1, "TOPLEFT", 15, -100)
    hint1:SetPoint("RIGHT", tab1, "RIGHT", -15, 0)
    hint1:SetJustifyH("LEFT")
    hint1:SetText("Se reproduce cuando pulsas una tecla cuya habilidad está en CD / no usable.")

    -- Tab 2: Habilidad lista
    local tab2 = tabFrames[2]
    local ctrl2 = CreateSoundControls(tab2, "soundIDReady")

    -- Checkbox "Activar sonido"
    local cb = CreateFrame("CheckButton", nil, tab2, "UICheckButtonTemplate")
    cb:SetSize(22, 22)
    cb:SetPoint("TOPLEFT", tab2, "TOPLEFT", 15, -100)
    cb.text = cb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    cb.text:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    cb.text:SetText("Alerta al estar lista")
    cb:SetScript("OnClick", function(self)
        CooldownAlertDB.alertOnReady = self:GetChecked() and true or false
    end)

    -- Checkbox "Icono en pantalla" + botones Test/Mover
    local cbPulse = CreateFrame("CheckButton", nil, tab2, "UICheckButtonTemplate")
    cbPulse:SetSize(22, 22)
    cbPulse:SetPoint("TOPLEFT", cb, "BOTTOMLEFT", 0, -4)
    cbPulse.text = cbPulse:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    cbPulse.text:SetPoint("LEFT", cbPulse, "RIGHT", 2, 0)
    cbPulse.text:SetText("Icono en pantalla")
    cbPulse:SetScript("OnClick", function(self)
        CooldownAlertDB.pulseEnabled = self:GetChecked() and true or false
    end)

    local pulseTest = CreateFrame("Button", nil, tab2, "UIPanelButtonTemplate")
    pulseTest:SetSize(52, 20)
    pulseTest:SetPoint("LEFT", cbPulse.text, "RIGHT", 14, 0)
    pulseTest:SetText("Test")
    pulseTest:SetScript("OnClick", function()
        local first
        for id in pairs(CooldownAlertDB.trackedSpells or {}) do first = id; break end
        ShowPulse(first or 2825, true)
    end)

    local pulseMove = CreateFrame("Button", nil, tab2, "UIPanelButtonTemplate")
    pulseMove:SetSize(62, 20)
    pulseMove:SetPoint("LEFT", pulseTest, "RIGHT", 4, 0)
    local function RefreshMoveBtn()
        pulseMove:SetText(cfg("pulseLocked") and "Mover" or "|cffffcc00Fijar|r")
    end
    RefreshMoveBtn()
    pulseMove:SetScript("OnClick", function()
        SetPulseUnlocked(cfg("pulseLocked"))  -- alterna
        RefreshMoveBtn()
    end)

    -- Header lista
    local listLbl = tab2:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    listLbl:SetPoint("TOPLEFT", cbPulse, "BOTTOMLEFT", 0, -10)
    listLbl:SetText("Spells trackeados:")

    local trackedFrame, refreshTrackedList = BuildTrackedList(tab2, listLbl)
    trackedFrame.countLabel = tab2:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    trackedFrame.countLabel:SetPoint("LEFT", listLbl, "RIGHT", 8, 0)

    -- Añadir
    local addLbl = tab2:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    addLbl:SetPoint("TOPLEFT", trackedFrame, "BOTTOMLEFT", 0, -10)
    addLbl:SetText("Añadir spellID:")

    local addEB = CreateFrame("EditBox", nil, tab2, "InputBoxTemplate")
    addEB:SetSize(90, 22)
    addEB:SetPoint("LEFT", addLbl, "RIGHT", 10, 0)
    addEB:SetAutoFocus(false); addEB:SetNumeric(true); addEB:SetMaxLetters(10)

    -- Selector de modo para el nuevo spell (togglea entre "cd" y "usable")
    local addMode = "cd"
    local modeSel = CreateFrame("Button", nil, tab2, "UIPanelButtonTemplate")
    modeSel:SetSize(52, 22)
    modeSel:SetPoint("LEFT", addEB, "RIGHT", 6, 0)
    local function UpdateModeSelText()
        modeSel:SetText(addMode == "usable" and "|cffffcc00USE|r" or "CD")
    end
    UpdateModeSelText()
    modeSel:SetScript("OnClick", function()
        addMode = (addMode == "cd") and "usable" or "cd"
        UpdateModeSelText()
    end)
    modeSel:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Modo al añadir")
        GameTooltip:AddLine("|cffaaaaaaCD:|r dispara al salir de cooldown", 1, 1, 1)
        GameTooltip:AddLine("|cffffcc00USE:|r dispara al volver a ser usable (recursos)", 1, 1, 1)
        GameTooltip:Show()
    end)
    modeSel:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local addBtn = CreateFrame("Button", nil, tab2, "UIPanelButtonTemplate")
    addBtn:SetSize(60, 22)
    addBtn:SetPoint("LEFT", modeSel, "RIGHT", 6, 0)
    addBtn:SetText("Añadir")
    local function DoAdd()
        local id = tonumber(addEB:GetText())
        if not id then return end
        local ok, err = TrackSpell(id, addMode)
        if ok then
            addEB:SetText("")
            refreshTrackedList()
        else
            print(("|cffff4444[CDA]|r %s"):format(err or "error"))
        end
    end
    addBtn:SetScript("OnClick", DoAdd)
    addEB:SetScript("OnEnterPressed", function(self) DoAdd(); self:ClearFocus() end)

    -- Hooks globales
    f.RefreshTracked = refreshTrackedList
    f:SetScript("OnShow", function()
        ctrl1.refresh()
        ctrl2.refresh()
        cb:SetChecked(cfg("alertOnReady"))
        cbPulse:SetChecked(cfg("pulseEnabled"))
        RefreshMoveBtn()
        refreshTrackedList()
    end)
    f:SetScript("OnHide", function()
        if SoundPopup and SoundPopup:IsShown() then SoundPopup:Hide() end
    end)

    SelectTab(1)
    uiFrame = f
    return f
end

local function ToggleUI()
    local f = BuildUI()
    if f:IsShown() then f:Hide() else f:Show() end
end

-- ── Botón de minimapa ────────────────────────────────────────

local MINIMAP_ICON = "Interface\\AddOns\\CooldownAlert\\Textures\\icon"
local MINIMAP_RADIUS = 80
local minimapButton

local function UpdateMinimapPosition()
    if not minimapButton then return end
    local angle = cfg("minimapAngle") or (-math.pi / 4)
    local x = MINIMAP_RADIUS * math.cos(angle)
    local y = MINIMAP_RADIUS * math.sin(angle)
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function BuildMinimapButton()
    if minimapButton then return minimapButton end
    if not Minimap then return nil end

    local b = CreateFrame("Button", "CooldownAlertMinimapButton", Minimap)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:SetSize(32, 32)
    b:SetMovable(true)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")

    -- Marco circular estilo minimapa
    local overlay = b:CreateTexture(nil, "OVERLAY")
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetSize(54, 54)
    overlay:SetPoint("TOPLEFT", 0, 0)

    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetSize(20, 20)
    bg:SetPoint("CENTER", 1, 1)

    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(MINIMAP_ICON)
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", 1, 1)
    icon:SetTexCoord(0, 1, 0, 1)
    b.icon = icon

    b:SetScript("OnClick", function(_, btn)
        if btn == "RightButton" then
            CooldownAlertDB.enabled = not cfg("enabled")
            print(("|cffffff00[CDA]|r Addon: %s"):format(cfg("enabled") and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
        else
            ToggleUI()
        end
    end)

    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("CooldownAlert")
        GameTooltip:AddLine("|cffaaaaaaClick izq:|r abrir interfaz", 1, 1, 1)
        GameTooltip:AddLine("|cffaaaaaaClick der:|r activar/desactivar", 1, 1, 1)
        GameTooltip:AddLine("|cffaaaaaaArrastrar:|r mover alrededor del minimapa", 1, 1, 1)
        GameTooltip:AddLine(("Estado: %s"):format(cfg("enabled") and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local function OnUpdateDrag(self)
        local mx, my = Minimap:GetCenter()
        local px, py = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        px, py = px / scale, py / scale
        local angle = math.atan2(py - my, px - mx)
        CooldownAlertDB.minimapAngle = angle
        UpdateMinimapPosition()
    end
    b:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", OnUpdateDrag)
    end)
    b:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    minimapButton = b
    UpdateMinimapPosition()
    if cfg("minimapHide") then b:Hide() end
    return b
end

local function SetMinimapShown(show)
    CooldownAlertDB.minimapHide = not show
    if show then
        BuildMinimapButton()
        if minimapButton then minimapButton:Show() end
    elseif minimapButton then
        minimapButton:Hide()
    end
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
    print("  /cda ready on|off       — alerta cuando una habilidad trackeada está lista")
    print("  /cda pulse on|off|test|unlock|lock — icono flotante al estar lista")
    print("  /cda track <id> [cd|usable] — añadir spell (modo: cd por defecto)")
    print("  /cda mode <id> cd|usable — cambiar el modo de un spell trackeado")
    print("  /cda untrack <spellID>  — quitar spell de la lista")
    print("  /cda tracked            — listar spells trackeados")
    print("  /cda test               — reproducir sonido actual")
    print("  /cda ui                 — abrir interfaz para elegir sonido")
    print("  /cda minimap show|hide  — mostrar/ocultar botón del minimapa")
    print("  /cda debug              — togglear prints de depuración")
    print("  /cda diag <spellID>     — diagnóstico del estado de un spell trackeado")
    print("  /cda casts on|off       — log de cada cast con su spellID (debug)")
    print("  /cda watch <spellID>    — monitoriza estado 20s (debug)")
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

    elseif sub == "ready" then
        toggleFlag("alertOnReady", "Alerta de habilidad lista", arg)

    elseif sub == "pulse" then
        if arg == "unlock" then
            SetPulseUnlocked(true)
            print("|cffffff00[CDA]|r Pulse desbloqueado — arrastra el icono para colocarlo, luego /cda pulse lock")
        elseif arg == "lock" then
            SetPulseUnlocked(false)
            print("|cffffff00[CDA]|r Pulse bloqueado")
        elseif arg == "test" then
            local first
            for id in pairs(CooldownAlertDB.trackedSpells or {}) do first = id; break end
            ShowPulse(first or 2825, true)  -- Bloodlust como fallback para el test
        elseif arg == "on" or arg == "off" then
            toggleFlag("pulseEnabled", "Pulse en pantalla", arg)
        else
            print(("|cffffff00[CDA]|r Pulse: %s  (/cda pulse on|off|test|unlock|lock)"):format(
                cfg("pulseEnabled") and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
        end

    elseif sub == "track" then
        local idStr, modeStr = arg:match("^(%S+)%s*(%S*)$")
        local id = tonumber(idStr)
        if not id then
            print("|cffff4444[CDA]|r Uso: /cda track <spellID> [cd|usable]")
            return
        end
        local mode = (modeStr ~= "" and modeStr) or "cd"
        if not TRACK_MODES[mode] then
            print("|cffff4444[CDA]|r modo inválido, usa 'cd' o 'usable'")
            return
        end
        local ok, err = TrackSpell(id, mode)
        if ok then
            local name = GetSpellDisplay(id) or "¿?"
            print(("|cff00ff00[CDA]|r Trackeando: %s (%d) — modo %s"):format(name, id, mode))
            if uiFrame and uiFrame.RefreshTracked then uiFrame.RefreshTracked() end
        else
            print(("|cffff4444[CDA]|r No añadido (%s)"):format(err or "error"))
        end

    elseif sub == "mode" then
        local idStr, modeStr = arg:match("^(%S+)%s*(%S*)$")
        local id = tonumber(idStr)
        if not id or not TRACK_MODES[modeStr] then
            print("|cffff4444[CDA]|r Uso: /cda mode <spellID> cd|usable")
            return
        end
        if SetSpellMode(id, modeStr) then
            print(("|cff00ff00[CDA]|r Modo de %d → %s"):format(id, modeStr))
            if uiFrame and uiFrame.RefreshTracked then uiFrame.RefreshTracked() end
        else
            print("|cffff4444[CDA]|r ese spellID no está trackeado")
        end

    elseif sub == "untrack" then
        local id = tonumber(arg)
        if not id then
            print("|cffff4444[CDA]|r Uso: /cda untrack <spellID>")
            return
        end
        if UntrackSpell(id) then
            print(("|cffffaa00[CDA]|r Quitado spellID %d"):format(id))
            if uiFrame and uiFrame.RefreshTracked then uiFrame.RefreshTracked() end
        else
            print("|cffff4444[CDA]|r ese spellID no estaba trackeado")
        end

    elseif sub == "tracked" then
        local tracked = CooldownAlertDB.trackedSpells or {}
        local ids = {}
        for id in pairs(tracked) do ids[#ids + 1] = id end
        table.sort(ids)
        if #ids == 0 then
            print("|cffffff00[CDA]|r No hay spells trackeados.")
        else
            print(("|cffffff00[CDA]|r Spells trackeados (%d):"):format(#ids))
            for _, id in ipairs(ids) do
                local name = GetSpellDisplay(id) or "|cff808080(desconocido)|r"
                local mode = NormalizeMode(tracked[id])
                print(("  %d [%s] — %s"):format(id, mode, name))
            end
        end

    elseif sub == "minimap" then
        if arg == "hide" or arg == "off" then
            SetMinimapShown(false)
            print("|cffff4444[CDA]|r Botón del minimapa: OFF")
        elseif arg == "show" or arg == "on" then
            SetMinimapShown(true)
            print("|cff00ff00[CDA]|r Botón del minimapa: ON")
        else
            SetMinimapShown(cfg("minimapHide") and true or false)
            print(("|cffffff00[CDA]|r Botón del minimapa: %s"):format(
                cfg("minimapHide") and "|cffff4444OFF|r" or "|cff00ff00ON|r"))
        end

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

    elseif sub == "d1" then
        -- Diag compacto: una sola línea con todo lo esencial.
        local id = tonumber(arg)
        if not id then print("|cffff4444[CDA]|r Uso: /cda d1 <spellID>"); return end
        local slot = FindActionSlotForSpell(id)
        local slotStr, iuaStr, gacStr, slotSpellStr = "none", "n/a", "n/a", "n/a"
        if slot and type(slot) == "number" then
            slotStr = tostring(slot)
            local okInfo, aType, aId = pcall(GetActionInfo, slot)
            if okInfo then slotSpellStr = tostring(aType) .. ":" .. tostring(aId) end
            local okU, isU, nEM = pcall(IsUsableAction, slot)
            iuaStr = okU and (tostring(isU) .. "/" .. tostring(nEM)) or "err"
            local okC, start, dur, ena = pcall(GetActionCooldown, slot)
            if okC then
                local tDur = type(dur)
                gacStr = ("dt=%s st=%s dur=%s en=%s"):format(tDur, tostring(start), tostring(dur), tostring(ena))
            else
                gacStr = "err"
            end
        end
        -- Cargas (si el hechizo las usa). Midnight: puede estar taintado también.
        local chargesStr = "n/a"
        if C_Spell and C_Spell.GetSpellCharges then
            local okCh, ch = pcall(C_Spell.GetSpellCharges, id)
            if okCh and ch then
                chargesStr = ("cur=%s max=%s"):format(tostring(ch.currentCharges), tostring(ch.maxCharges))
            elseif okCh then
                chargesStr = "sin cargas"
            else
                chargesStr = "err"
            end
        end
        local cached = tostring(readyState[id])
        local mode = CooldownAlertDB.trackedSpells and CooldownAlertDB.trackedSpells[id] or "?"
        print(("|cffffff00[CDA d1]|r id=%d [%s] slot=%s(%s) IUA=%s GAC=%s CH=%s cache=%s"):format(
            id, tostring(mode), slotStr, slotSpellStr, iuaStr, gacStr, chargesStr, cached))

    elseif sub == "watch" then
        local id = tonumber(arg)
        if not id then
            print("|cffff4444[CDA]|r Uso: /cda watch <spellID>")
            return
        end
        print(("|cff00ff00[CDA watch]|r spell=%d — monitorizando 20s, una línea/seg"):format(id))
        local ticks = 0
        local function tick()
            ticks = ticks + 1
            local cdReady = IsSpellReadyCD(id)
            local useReady = IsSpellReadyUsable(id)
            local cached = readyState[id]
            local cdInfo = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(id)
            local remaining = "?"
            if cdInfo and type(cdInfo.duration) == "number" and cdInfo.duration > 0 then
                local r = (cdInfo.startTime or 0) + cdInfo.duration - GetTime()
                remaining = ("%.1fs"):format(r)
            else
                remaining = "0"
            end
            local isUsable
            if C_Spell and C_Spell.IsSpellUsable then
                local ok, u = pcall(C_Spell.IsSpellUsable, id)
                isUsable = ok and tostring(u) or "err"
            else
                isUsable = "n/a"
            end
            print(("|cff66ccff[w%02d]|r cdRem=%s usable=%s  CDok=%s USEok=%s  cache=%s"):format(
                ticks, remaining, isUsable,
                tostring(cdReady), tostring(useReady), tostring(cached)))
            if ticks < 20 then C_Timer.After(1, tick) end
        end
        C_Timer.After(0.01, tick)

    elseif sub == "casts" then
        if not _G.CooldownAlertCastHook then
            local cf = CreateFrame("Frame", "CooldownAlertCastHook")
            cf:SetScript("OnEvent", function(_, _, unit, _, spellID)
                local name = GetSpellDisplay(spellID) or "?"
                print(("|cff66ccff[CDA cast]|r %s  spellID=|cffffffff%d|r  (%s)"):format(unit, spellID, name))
            end)
        end
        local cf = _G.CooldownAlertCastHook
        if arg == "on" then
            cf:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
            print("|cff00ff00[CDA]|r casts: ON — lanza Void Ray en Meta y verás el spellID real")
        elseif arg == "off" then
            cf:UnregisterAllEvents()
            print("|cffff4444[CDA]|r casts: OFF")
        else
            print("|cffffff00[CDA]|r Uso: /cda casts on|off")
        end

    elseif sub == "diag" then
        local id = tonumber(arg)
        if not id then
            print("|cffff4444[CDA]|r Uso: /cda diag <spellID>")
            return
        end
        -- Cada sección en su propio pcall — los "secret numbers" de Midnight
        -- pueden lanzar en formato/comparación y matarían el resto del diag.
        local function safe(label, fn)
            local ok, err = pcall(fn)
            if not ok then
                print(("  %s: |cffff4444ERR|r %s"):format(label, tostring(err)))
            end
        end

        local name = GetSpellDisplay(id) or "(desconocido)"
        local mode = CooldownAlertDB.trackedSpells and CooldownAlertDB.trackedSpells[id]
        print(("|cffffff00[CDA diag]|r spell=%d (%s)  trackeado=%s"):format(
            id, name, mode and ("sí [" .. mode .. "]") or "NO"))

        safe("CD", function()
            local cdInfo = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(id)
            if not cdInfo then print("  CD: sin info"); return end
            -- type() no toca valores, seguro
            local tDur = type(cdInfo.duration)
            print(("  CD.duration type=%s  startTime type=%s"):format(
                tDur, type(cdInfo.startTime)))
            -- tostring puede lanzar con secret numbers — otro safe
            safe("CD raw", function()
                print(("  CD raw: start=%s dur=%s"):format(
                    tostring(cdInfo.startTime), tostring(cdInfo.duration)))
            end)
        end)

        safe("IsSpellUsable", function()
            if not (C_Spell and C_Spell.IsSpellUsable) then return end
            local ok, usable, noPower = pcall(C_Spell.IsSpellUsable, id)
            if ok then
                print(("  IsSpellUsable: usable=%s noPower=%s"):format(
                    tostring(usable), tostring(noPower)))
            else
                print("  IsSpellUsable: pcall-err")
            end
        end)

        safe("Slot", function()
            local slot = FindActionSlotForSpell(id)
            if slot and type(slot) == "number" then
                local ok, isU, notEM = pcall(IsUsableAction, slot)
                if ok then
                    print(("  slot=%d  IsUsableAction: usable=%s notEnoughMana=%s"):format(
                        slot, tostring(isU), tostring(notEM)))
                else
                    print(("  slot=%d  IsUsableAction: pcall-err"):format(slot))
                end
            else
                print("  slot: no encontrado en action bars")
            end
        end)

        safe("Predicados", function()
            print(("  IsSpellReadyCD=%s   IsSpellReadyUsable=%s"):format(
                tostring(IsSpellReadyCD(id)), tostring(IsSpellReadyUsable(id))))
        end)

        print(("  readyState cacheado: %s"):format(tostring(readyState[id])))
        print(("  alertOnReady=%s enabled=%s"):format(
            tostring(cfg("alertOnReady")), tostring(cfg("enabled"))))

    elseif sub == "reset" then
        wipe(CooldownAlertDB)
        for k, v in pairs(DEFAULTS) do CooldownAlertDB[k] = v end
        CooldownAlertDB.trackedSpells = {}
        wipe(readyState)
        if uiFrame and uiFrame.RefreshTracked then uiFrame.RefreshTracked() end
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
    -- trackedSpells debe ser una tabla independiente (no compartir el default)
    if CooldownAlertDB.trackedSpells == DEFAULTS.trackedSpells then
        CooldownAlertDB.trackedSpells = {}
    end
    -- Migración: versiones previas guardaban true en vez del modo ("cd"/"usable")
    for id, v in pairs(CooldownAlertDB.trackedSpells) do
        if v == true then CooldownAlertDB.trackedSpells[id] = "cd" end
    end
    if not cfg("minimapHide") then BuildMinimapButton() end
    print(("|cff00ff00[CooldownAlert]|r v%s cargado. /cda para ayuda."):format(VERSION))
end)
