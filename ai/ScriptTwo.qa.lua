-- AccLua AI UI v9 (WoW 3.3.5 / Lua 5.1): compact, resizable window for the local model (KoboldCpp).
-- v4: model menu with descriptions, hardware fit (VRAM/RAM from the host) and tooltips.
-- v5: no global frame names (hand-made scroll bars), separate TALK/ACTIONS chats, message queue,
--     Stop for a waiting request, history restore after /reload, bigger fonts, delete models from the menu.
-- v7: constructor ReloadUI/Apply/File + working.lua host IPC; AccLua Tesq* Apply env.
-- v8: even header + Russian tooltips; chat width fix; working.lua open (quoted CreateProcess on host);
--     Apply last/selected ```lua```; best-effort Unload of Apply-created frames.
-- v9: dedicated title drag strip (header buttons no longer eat move); SCRIPT IPC not dumped into chat.
-- v10: File menu contrast/strata; click-to-select ```lua``` with highlight; CollectLuaBlocks scans all plains.
-- v11: two-row header (no button overlap); short Think labels; title drag kept free.
-- v12: per-Apply registry (applyId); «Снять блок» / RMB on code unloads one instance; «Снять» = all.
-- v13: forward-decl RenderHistory/CollectLuaBlocks before SyncCodeHits (Lua 5.1 upvalue fix);
--     subtle code-hit tint (no muddy full-block yellow); SCRIPT_SAVE prioritized + workingCache.
-- v27: AccLuaAI.CancelRequest export (same Lua 5.1 scoping as RenderHistory): HandleSys lives in another
--      do-block and called global CancelRequest → nil crash on [MODEL]busy,...[/MODEL]. Busy switch still
--      Stop+queues MODEL after cancel.
-- v26: history restore fix: a [HISTORY] (or any structured sys reply) whose PAYLOAD contains "[QA_ERROR]"
--      (a rejected ACTIONS plan saved in the history) was thrown away as an error -> nothing restored after
--      /reload. Model switch while a reply is being generated: the request is cancelled and the switch
--      follows automatically. Think-on shows a slowness warning.
-- v25: ```macro fences are Apply blocks too (host answers macro requests with them; run via RunMacroText).
-- v24: "Исправить с AI" button sits right on the red error entry in the history (the header copy was
--      easy to miss); a block made of /slash macro lines is applied as RunMacroText via Tesq1 instead
--      of failing with "unexpected symbol near '/'".
-- v23: Apply env carries the WHOLE AccLua API (TesqTp, TesqGpsX, TesqMapId, ... 55 names): the DLL
--      renames the values in this file, the keys keep the public spelling. An error inside an applied
--      frame's OnUpdate/OnEvent is caught once, the handler is detached and the error goes to TALK
--      (no 4000-error spam).
-- v22: Shift-click links (items, spells, quests, achievements...) go into the AI input while it has focus;
--      a link is sent to the model as "[Name] (item:1234)" so it knows the exact id.
-- v21: AI button toggles the window (AccLuaAI_Show hides a shown window); Copy = window + clipboard;
--      CHAT: 8 replies/min per player (was 3) and 1 s anti-loop mute (was 3 s) - a fast human reply was ignored.
-- v20: visual rework: header band + status dot, segmented tabs, per-entry bands (You/AI), darker code
--      panels, slim auto-hiding scrollbar, input placeholder, empty-state example prompts, live history
--      width from the scroll frame (long intro no longer runs past the right edge).
-- v19: CHAT replies are sent automatically by default (Draft toggle off); Draft = manual Enter.
-- v18: Apply env keys survive the DLL Tesq* rename (Tesq1 nil in applied code); pooled history
--      FontStrings reset their height before SetText (old fixed height clipped text to "...");
--      [WORKING_LUA] shown once; TALK/ACTIONS/CHAT as three tabs; Copy -> clipboard via AccLuaClipboard
--      (window fallback is draggable + "Select all").
-- v17: sections wrapped in do...end (main chunk was at 196/200 locals; the DLL prepends 8 Tesq locals).
-- v16: history = stack of pooled FontStrings (<=3500 bytes each: one huge SetText stopped rendering);
--      per-piece code overlays + Copy button; re-Apply replaces the block; Apply errors stay in TALK +
--      "Исправить с AI"; File -> Run file; CHAT mode (AI replies in whisper/say, all toggles off by default).
-- v6: silent commands (models, downloads, delete, think, Clear) keep flowing while a reply is awaited,
--     "Answering..." status, Up/Down recall of sent questions, a visible two-click Delete per installed model.
-- Model text is display-only. It is never evaluated as Lua or as an action.
-- No chat-frame output: replies open this window instead.

local UIVER = 27
local prev = _G.AccLuaAI
if type(prev) == "table" and prev.ver == UIVER and prev.frame then
    return
end
-- An older AI UI kept its frame and would block this file: stop and hide it, then take over.
if type(prev) == "table" then
    -- Neutralize without calling the old Disable: older builds sent StopAutoRun() (nil on 3.3.5).
    pcall(function()
        if type(prev.executor) == "table" then prev.executor.active = false prev.executor.steps = {} prev.executor.navigation = nil end
        if type(prev.chat) == "table" then prev.chat.enabled = false end
        prev.waitingKind, prev.waitingSys = nil, nil
        prev.queue = {} -- the old ticker must not send its queued messages either
        prev.dlPoll, prev.menuWanted = nil, nil -- the old ticker must not keep polling downloads
        -- v16+: the old CHAT-mode listener and its game-chat send queue must go quiet too.
        if type(prev.chatEvFrame) == "table" and prev.chatEvFrame.UnregisterAllEvents then prev.chatEvFrame:UnregisterAllEvents() end
        prev.chatSendQ, prev.chatIn = {}, {}
    end)
    -- v5+ frames have no global names: newer builds find them through prev.frame / prev.copyFrame.
    -- (Old globals go by name: an ipairs list of frames would stop at the first missing one.)
    local function HideOld(f) if type(f) == "table" and f.Hide then pcall(f.Hide, f) end end
    HideOld(prev.frame)
    HideOld(prev.copyFrame)
    for _, name in ipairs({ "AccLuaAIFrame", "AccLuaAICopyFrame", "AccLuaAI2Frame", "AccLuaAI2CopyFrame",
            "AccLuaAI3Frame", "AccLuaAI3CopyFrame", "AccLuaAI4Frame", "AccLuaAI4CopyFrame" }) do
        HideOld(_G[name])
    end
end

local AccLuaAI = { ver = UIVER, mode = "talk", chat = { draft = nil }, queue = {} }
if type(prev) == "table" and (prev.mode == "actions" or prev.mode == "chat") then AccLuaAI.mode = prev.mode end
-- Frames applied by the previous window instance still exist until /reload: keep them unloadable.
if type(prev) == "table" and type(prev.applies) == "table" then
    AccLuaAI.applies, AccLuaAI.applySeq = prev.applies, prev.applySeq
    AccLuaAI.appliedFrames = type(prev.appliedFrames) == "table" and prev.appliedFrames or nil
end
_G.AccLuaAI = AccLuaAI

local RU = (type(GetLocale) == "function" and GetLocale() or "ruRU") == "ruRU"
local function T(ru, en) if RU then return ru end return en end

-- Text size. Friz Quadrata (Fonts\FRIZQT__.TTF); the path is taken from GameFontHighlight when available
-- so a localized client keeps its own Cyrillic-capable Friz file. No outline flags.
local FONT = "Fonts\\FRIZQT__.TTF"
local function Font(obj, size)
    local path = FONT
    if type(GameFontHighlight) == "table" and GameFontHighlight.GetFont then
        local p = GameFontHighlight:GetFont()
        if type(p) == "string" and p ~= "" then path = p end
    end
    obj:SetFont(path, size)
end

local ACCENT, HOVER, DOWN = { 0.13, 0.17, 0.23, 1 }, { 0.20, 0.30, 0.42, 1 }, { 0.10, 0.45, 0.80, 1 }
local BORDER = { 0.20, 0.23, 0.29, 1 }
-- v20 theme: flat dark buttons, one blue accent for the active/pressed state.
local UI = {
    band = { 0.11, 0.12, 0.15, 1 },      -- header band
    you = { 0.20, 0.45, 0.85, 0.10 },    -- user entry tint
    youBar = { 0.35, 0.65, 1.0, 0.9 },
    ai = { 1, 1, 1, 0.025 },             -- AI entry tint
    aiBar = { 0.55, 0.60, 0.70, 0.6 },
    code = { 0, 0, 0, 0.32 },            -- code panel
    codeSel = { 0.20, 0.40, 0.75, 0.18 },
    dot = { ready = { 0.30, 0.85, 0.40 }, busy = { 0.95, 0.75, 0.20 }, err = { 0.95, 0.30, 0.30 } },
}

local function Backdrop(f, r, g, b, a)
    f:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    f:SetBackdropColor(r, g, b, a)
    f:SetBackdropBorderColor(unpack(BORDER))
end

local function Button(parent, width, label)
    local b = CreateFrame("Button", nil, parent)
    b:SetWidth(width)
    b:SetHeight(20)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints(b)
    b.bg:SetTexture(unpack(ACCENT))
    b.line = b:CreateTexture(nil, "BORDER") -- 1px bottom edge: flat buttons read as buttons
    b.line:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 0, 0)
    b.line:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 0, 0)
    b.line:SetHeight(1)
    b.line:SetTexture(0, 0, 0, 0.45)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.text:SetPoint("CENTER")
    b.text:SetTextColor(0.92, 0.94, 0.97)
    b.text:SetText(label)
    b:SetScript("OnEnter", function(self) self.bg:SetTexture(unpack(HOVER)) end)
    b:SetScript("OnLeave", function(self) self.bg:SetTexture(unpack(self.active and DOWN or ACCENT)) end)
    b:SetScript("OnMouseDown", function(self) self.bg:SetTexture(unpack(DOWN)) end)
    b:SetScript("OnMouseUp", function(self) self.bg:SetTexture(unpack(HOVER)) end)
    return b
end
-- v18: mode tabs stay pressed while selected (TALK / ACTIONS / CHAT are three visible buttons).
local function SetActive(b, on)
    b.active = on and true or false
    b.bg:SetTexture(unpack(on and DOWN or ACCENT))
    b.text:SetTextColor(1, 1, 1)
    if b.line then b.line:SetTexture(unpack(on and { 0.55, 0.80, 1, 1 } or { 0, 0, 0, 0.45 })) end
end

-- GameTooltip on header controls; keeps Button hover colors.
local function Tip(btn, title, body)
    if type(btn) ~= "table" then return end
    local prevEnter, prevLeave = btn:GetScript("OnEnter"), btn:GetScript("OnLeave")
    btn:SetScript("OnEnter", function(self)
        if prevEnter then prevEnter(self) end
        if type(GameTooltip) ~= "table" then return end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:ClearLines()
        GameTooltip:AddLine(title, 0.4, 0.8, 1)
        if body and body ~= "" then GameTooltip:AddLine(body, 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function(self)
        if prevLeave then prevLeave(self) end
        if type(GameTooltip) == "table" then GameTooltip:Hide() end
    end)
end

-- The DLL text-replaces every "Tesq*" in this file with its random names before running it.
-- Wherever the PUBLIC spelling must survive (Apply env keys, code detection) it is built from TQ.
local TQ = "Te" .. "sq" -- public API prefix, assembled so the DLL rename pass leaves it alone
local function Trim(text)
    return tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function SendToHost(text)
    text = Trim(text)
    if text == "" then return false end
    -- A raw newline would end the "--" Lua comment below and run the rest as code:
    -- multi-line text goes as "[ML]" + escaped (host DecodeMultiline).
    if text:find("[\r\n]") then
        text = "[ML]" .. text:gsub("\\", "\\\\"):gsub("\r?\n", "\\n"):gsub("\r", "\\n")
    end
    -- The DLL routes only this marker to the isolated local-AI pipe.
    RunScript("--%&#[AI:UI]" .. text)
    return true
end

-- Two independent waits: the chat wait (waitingKind "talk"/"actions", or "cancel" after Stop) and the
-- silent-command wait (waitingSys = the command, 20 s). The DLL lets [AI:...] commands through while a
-- chat reply is pending, so a sys reply never releases the chat wait and a chat reply never releases
-- the sys wait. sysSerial: an older DLL answered a command with "AI is busy" -> one request at a time.
local function ChatAwaited(now)
    return AccLuaAI.waitingKind ~= nil and (now or GetTime()) < (AccLuaAI.waitingUntil or 0)
end
local function SysAwaited(now)
    return AccLuaAI.waitingSys ~= nil and (now or GetTime()) < (AccLuaAI.waitingSysUntil or 0)
end

-- kind: "talk"/"actions" (shown in the history) or "sys" (model list, downloads: silent).
local function SendTracked(kind, text)
    local now = GetTime()
    -- The wait is set before the send, so an error the DLL delivers at once still finds it.
    if kind == "sys" then
        if SysAwaited(now) or (AccLuaAI.sysSerial and ChatAwaited(now)) then return false end
        AccLuaAI.waitingSys, AccLuaAI.waitingSysUntil = Trim(text), now + 20
        if SendToHost(text) then return true end
        AccLuaAI.waitingSys, AccLuaAI.waitingSysUntil = nil, nil
        return false
    end
    if ChatAwaited(now) or (AccLuaAI.sysSerial and SysAwaited(now)) then return false end
    AccLuaAI.waitingKind, AccLuaAI.waitingSince, AccLuaAI.waitingUntil = kind, now, now + 185
    if SendToHost(text) then return true end
    AccLuaAI.waitingKind, AccLuaAI.waitingSince, AccLuaAI.waitingUntil = nil, nil, nil
    return false
end

-- Replies travel through the DLL chat filter: code bytes arrive as {XX} escapes.
local function Decode(text)
    return (tostring(text or ""):gsub("{(%x%x)}", function(h) return string.char(tonumber(h, 16)) end))
end
local function Shown(text) return (tostring(text or ""):gsub("|", "||")) end

-- Unnamed scroll frame with a slim vertical slider (UIPanelScrollFrameTemplate needs a global name).
local function SyncBar(sf, bar, toEnd, yrange)
    local range = tonumber(yrange) or sf:GetVerticalScrollRange() or 0
    if range < 0 then range = 0 end
    bar:SetMinMaxValues(0, range)
    if range > 0 then bar:Show() else bar:Hide() end
    local v = toEnd and range or math.min(sf:GetVerticalScroll() or 0, range)
    sf:SetVerticalScroll(v)
    bar:SetValue(v)
end
local function MakeScroll(parent)
    local sf = CreateFrame("ScrollFrame", nil, parent)
    local bar = CreateFrame("Slider", nil, parent)
    bar:SetWidth(8) -- v20: slim bar, hidden while the content fits (SyncBar)
    bar:SetOrientation("VERTICAL")
    bar:SetThumbTexture("Interface\\Buttons\\WHITE8X8")
    local thumb = bar.GetThumbTexture and bar:GetThumbTexture()
    if thumb then
        thumb:SetWidth(8)
        thumb:SetHeight(32)
        thumb:SetVertexColor(0.45, 0.55, 0.70, 0.9)
    end
    bar:SetPoint("TOPLEFT", sf, "TOPRIGHT", 6, 0)
    bar:SetPoint("BOTTOMLEFT", sf, "BOTTOMRIGHT", 6, 0)
    local track = bar:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints(bar)
    track:SetTexture(1, 1, 1, 0.06)
    bar:EnableMouse(true)
    bar:SetMinMaxValues(0, 0)
    bar:SetValue(0)
    bar:Hide()
    bar:SetScript("OnValueChanged", function(_, value) sf:SetVerticalScroll(value) end)
    sf:SetScript("OnScrollRangeChanged", function(self, _, yrange) SyncBar(self, bar, false, yrange) end)
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(self, delta)
        local range = self:GetVerticalScrollRange() or 0
        local v = (self:GetVerticalScroll() or 0) - (delta or 0) * 30
        if v > range then v = range end
        if v < 0 then v = 0 end
        self:SetVerticalScroll(v)
        bar:SetValue(v)
    end)
    return sf, bar
end

-- Window: header (mode, model, context buttons, copy/clear/close), status, history, input, size grip.
local frame = CreateFrame("Frame", nil, UIParent)
AccLuaAI.frame = frame
frame:SetWidth(700)
frame:SetHeight(380)
frame:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
-- Above UIErrorsFrame yellow toasts that otherwise paint over the header.
frame:SetFrameStrata("FULLSCREEN_DIALOG")
frame:SetFrameLevel(50)
frame:SetMovable(true)
frame:SetResizable(true)
if frame.SetMinResize then frame:SetMinResize(560, 280) end
if frame.SetMaxResize then frame:SetMaxResize(1200, 900) end
frame:EnableMouse(true)
-- Drag lives on titleBtn + dragStrip: UIVER8 packed ~698px of header buttons into 640px,
-- so left/right groups overlapped and ate every LeftButton drag on the frame chrome.
frame:SetClampedToScreen(true)
Backdrop(frame, 0.08, 0.09, 0.11, 0.97)
frame:Hide()

local HDR_Y1, HDR_Y2, HDR_GAP, HDR_H = -6, -28, 3, 50
local dragStrip = CreateFrame("Frame", nil, frame)
dragStrip:SetPoint("TOPLEFT", frame, "TOPLEFT", 2, -2)
dragStrip:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)
dragStrip:SetHeight(HDR_H)
dragStrip:EnableMouse(true)
dragStrip:RegisterForDrag("LeftButton")
dragStrip:SetScript("OnDragStart", function() frame:StartMoving() end)
dragStrip:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)
dragStrip:SetFrameLevel((frame:GetFrameLevel() or 1) + 1)
do -- v20: header band (rows 1-2 + status line) separates the controls from the history
    local band = dragStrip:CreateTexture(nil, "BACKGROUND")
    band:SetPoint("TOPLEFT", frame, "TOPLEFT", 3, -3)
    band:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -3, -3)
    band:SetHeight(66)
    band:SetTexture(unpack(UI.band))
    local rule = dragStrip:CreateTexture(nil, "BORDER")
    rule:SetPoint("TOPLEFT", frame, "TOPLEFT", 3, -69)
    rule:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -3, -69)
    rule:SetHeight(1)
    rule:SetTexture(1, 1, 1, 0.07)
end

local titleBtn = CreateFrame("Button", nil, frame)
titleBtn:SetWidth(98)
titleBtn:SetHeight(20)
titleBtn:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, HDR_Y1)
titleBtn:EnableMouse(true)
titleBtn:RegisterForDrag("LeftButton")
titleBtn:SetScript("OnDragStart", function() frame:StartMoving() end)
titleBtn:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)
titleBtn:SetFrameLevel((frame:GetFrameLevel() or 1) + 30)
-- v20: status dot before the title: green = ready, yellow = answering, red = last request failed.
local titleDot = titleBtn:CreateTexture(nil, "OVERLAY")
titleDot:SetWidth(8)
titleDot:SetHeight(8)
titleDot:SetPoint("LEFT", titleBtn, "LEFT", 4, 0)
titleDot:SetTexture(unpack(UI.dot.ready))
local function SetDot(state) titleDot:SetTexture(unpack(UI.dot[state] or UI.dot.ready)) end
AccLuaAI.SetDot = SetDot
local title = titleBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("LEFT", titleBtn, "LEFT", 16, 0)
title:SetText("|cff66ccffAccLua AI|r")

local function RaiseHeaderBtn(b)
    b:SetFrameLevel((frame:GetFrameLevel() or 1) + 10)
end
local function FitBtn(b, minW)
    local w = minW or 36
    if b.text and b.text.GetStringWidth then
        local tw = b.text:GetStringWidth()
        if tw and tw > 0 then w = math.max(w, tw + 12) end
    end
    b:SetWidth(w)
    return w
end
local function ThinkLabel(on)
    if on then return T("Дум:вкл", "Think on") end
    return T("Дум:выкл", "Think off")
end

local modeBtn = Button(frame, 52, "TALK")
local actBtn = Button(frame, 64, "ACTIONS")
local chatBtn = Button(frame, 48, "CHAT")
do -- v20: segmented look: one dark groove behind the three tabs
    local groove = frame:CreateTexture(nil, "BORDER")
    groove:SetPoint("TOPLEFT", modeBtn, "TOPLEFT", -2, 2)
    groove:SetPoint("BOTTOMRIGHT", chatBtn, "BOTTOMRIGHT", 2, -2)
    groove:SetTexture(0, 0, 0, 0.35)
end
local modelBtn = Button(frame, 80, T("Модель", "Model"))
-- Thinking for code requests (slower, more accurate); toggled on the host with [AI:THINK=0|1].
local thinkBtn = Button(frame, 64, ThinkLabel(true))
local runBtn = Button(frame, 40, "Run")
-- "Stop act" stops a running local ACTION; the request Stop next to Send cancels a waiting reply.
local stopBtn = Button(frame, 56, "Stop act")
local sayBtn = Button(frame, 40, "Say")

local closeBtn = Button(frame, 22, "X")
closeBtn:SetScript("OnClick", function() frame:Hide() end)
local clearBtn = Button(frame, 44, "Clear")
local copyBtn = Button(frame, 44, "Copy")
-- Constructor: ReloadUI / Apply / Unload / File (working.lua) on header row 2 (never overlaps row 1).
local fileBtn = Button(frame, 44, T("Файл", "File"))
local unloadBtn = Button(frame, 48, T("Снять", "Unload"))
local unloadBlockBtn = Button(frame, 72, T("Снять блок", "Unload blk"))
local applyBtn = Button(frame, 64, T("Применить", "Apply"))
local reloadBtn = Button(frame, 52, "Reload")
for _, b in ipairs({ modeBtn, actBtn, chatBtn, modelBtn, thinkBtn, runBtn, stopBtn, sayBtn,
        closeBtn, clearBtn, copyBtn, fileBtn, unloadBtn, unloadBlockBtn, applyBtn, reloadBtn }) do
    RaiseHeaderBtn(b)
end

-- Row1: title + mode/model/think + context + X. Row2: constructor tools. Title drag strip stays free.
local function LayoutHeader()
    FitBtn(modeBtn, 44)
    FitBtn(actBtn, 56)
    FitBtn(chatBtn, 44)
    FitBtn(modelBtn, 64)
    FitBtn(thinkBtn, 56)
    FitBtn(runBtn, 36)
    FitBtn(stopBtn, 48)
    FitBtn(sayBtn, 36)
    FitBtn(reloadBtn, 48)
    FitBtn(applyBtn, 56)
    FitBtn(unloadBlockBtn, 64)
    FitBtn(unloadBtn, 44)
    FitBtn(fileBtn, 40)
    FitBtn(copyBtn, 40)
    FitBtn(clearBtn, 40)
    FitBtn(closeBtn, 22)

    titleBtn:ClearAllPoints()
    titleBtn:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, HDR_Y1)
    modeBtn:ClearAllPoints()
    modeBtn:SetPoint("TOPLEFT", titleBtn, "TOPRIGHT", 6, 0)
    actBtn:ClearAllPoints()
    actBtn:SetPoint("LEFT", modeBtn, "RIGHT", 1, 0)
    chatBtn:ClearAllPoints()
    chatBtn:SetPoint("LEFT", actBtn, "RIGHT", 1, 0)
    modelBtn:ClearAllPoints()
    modelBtn:SetPoint("LEFT", chatBtn, "RIGHT", HDR_GAP + 4, 0)
    thinkBtn:ClearAllPoints()
    thinkBtn:SetPoint("LEFT", modelBtn, "RIGHT", HDR_GAP, 0)
    local leftAnchor = thinkBtn
    for _, b in ipairs({ runBtn, stopBtn, sayBtn }) do
        b:ClearAllPoints()
        if b:IsShown() then
            b:SetPoint("LEFT", leftAnchor, "RIGHT", HDR_GAP, 0)
            leftAnchor = b
        end
    end
    closeBtn:ClearAllPoints()
    closeBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, HDR_Y1)

    -- Constructor row: left→right under title; never shares Y with row 1 (fixes Дум/Reload jam).
    local row2 = { reloadBtn, applyBtn, unloadBlockBtn, unloadBtn, fileBtn, copyBtn, clearBtn }
    local prev2 = nil
    for _, b in ipairs(row2) do
        b:ClearAllPoints()
        if prev2 then
            b:SetPoint("LEFT", prev2, "RIGHT", HDR_GAP, 0)
        else
            b:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, HDR_Y2)
        end
        prev2 = b
    end
    dragStrip:SetHeight(HDR_H)
end
LayoutHeader()

local status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
-- Below the two-row header.
status:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -52)
status:SetPoint("RIGHT", frame, "RIGHT", -10, 0)
status:SetJustifyH("LEFT")
status:SetTextColor(0.65, 0.72, 0.84)
Font(status, 12)
-- Status of a silent command. While a chat reply is awaited the ticker rewrites the status line every 0.2 s,
-- so the note rides along after the timer for 6 s (download progress keeps refreshing it).
local function SysStatus(text)
    status:SetText(text)
    AccLuaAI.note, AccLuaAI.noteUntil = text, GetTime() + 6
end
-- "Исправить с AI": right of the status line while AccLuaAI.lastError (a failed Apply/Run) exists.
local fixBtn = Button(frame, 104, T("Исправить с AI", "Fix with AI"))
AccLuaAI.fixBtn = fixBtn
fixBtn:SetHeight(16)
fixBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -10, -49)
RaiseHeaderBtn(fixBtn)
fixBtn:Hide()
local function UpdateFixBtn()
    if AccLuaAI.lastError then
        FitBtn(fixBtn, 96)
        fixBtn:Show()
        status:SetPoint("RIGHT", fixBtn, "LEFT", -6, 0)
    else
        fixBtn:Hide()
        status:SetPoint("RIGHT", frame, "RIGHT", -10, 0)
    end
end

-- CHAT mode options (two compact lines under the status line, filled by the CHAT section below).
-- Shown only in CHAT mode; the history then starts lower (OUT_Y.chat).
local OUT_Y = { base = -70, chat = -114 } -- history top: TALK/ACTIONS, CHAT (options shown)
local chatRow = CreateFrame("Frame", nil, frame)
chatRow:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -68)
chatRow:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -68)
chatRow:SetHeight(44)
chatRow:SetFrameLevel((frame:GetFrameLevel() or 1) + 10)
chatRow:Hide()

local output, outputBar = MakeScroll(frame)
output:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, OUT_Y.base)
output:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -28, 38)
local outputChild = CreateFrame("Frame", nil, output)
outputChild:SetWidth(604)
outputChild:SetHeight(1)
output:SetScrollChild(outputChild)
-- History = vertical stack of pooled FontStrings (one per entry, long entries split into pieces).
-- A single FontString stops rendering past ~4 KB: the tail of a long chat was cut mid-word and new
-- messages never appeared. No piece gets more than PIECE_MAX bytes.
local PIECE_MAX, PIECE_GAP, ENTRY_GAP = 3500, 2, 14
local histTextW = 596
local outputText, histPool, PoolFS
do
local function NewHistFS()
    local fs = outputChild:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetWidth(histTextW)
    fs:SetJustifyH("LEFT")
    fs:SetJustifyV("TOP")
    fs:SetNonSpaceWrap(true)
    if fs.SetWordWrap then fs:SetWordWrap(true) end
    fs:SetSpacing(2)
    Font(fs, 14)
    return fs
end
outputText = NewHistFS() -- piece 1; also the font/width reference for MeasureHeight
outputText:SetPoint("TOPLEFT", outputChild, "TOPLEFT", 12, -6)
histPool = { outputText }
PoolFS = function(i)
    if not histPool[i] then histPool[i] = NewHistFS() end
    return histPool[i]
end
end

-- Two separate chats (TALK / ACTIONS), selected by AccLuaAI.mode. history = shown lines, plain = copy text.
-- top = lines above the restore point (welcome/hint + restored items): /reload history goes right below them.
-- sent = questions for Up/Down recall (oldest first, 30 max), recall = position while browsing them.
local function NewChat(intro) return { history = { intro }, plain = { "" }, top = 1, sent = {} } end
AccLuaAI.chats = {
    talk = NewChat("|cff66ccffAccLua AI|r " .. T("(локально, без облака). Первый ответ после запуска может идти 10-40 с. Вопрос с ? или словами найди/поищи - поиск в интернете. Кнопка с именем модели - выбор модели: там же видно, потянет ли её ваш ПК.",
        "(local, no cloud). First answer after a start may take 10-40 s. Start with ? or say найди/поищи for a web search. The model button switches models and shows whether your PC can run each one.")),
    actions = NewChat("|cff66ccffACTIONS:|r " .. T("опишите действие (прыгни, сядь, открой сумку, иди к NPC ...)",
        "describe an action (jump, sit, open bags, go to NPC ...)")),
    chat = NewChat("|cff66ccffCHAT:|r " .. T("ИИ сам отвечает в игровой чат (ЛС / Сказать). Включите «Отвечать в ЛС» или «Отвечать в /say» и добавьте ники в белый список. «Черновик» - если хотите отправлять Enter вручную. Поле ввода - вопрос к ИИ, в игру не уходит.",
        "the AI answers in the game chat (whisper / say). Everything is off by default: enable a toggle above. The input asks the AI (e.g. \"what to reply?\") and never goes to the game.")),
}
local function ModeOf(mode) if mode == "actions" or mode == "chat" then return mode end return "talk" end
local function Chat(mode) return AccLuaAI.chats[ModeOf(mode)] end
local AI_LINE = "\n|cffb8c5d6AI:|r "
-- Fences only count in AI answers (= CollectLuaBlocks over plain): a question with ``` must not shift block N.
local function NoFence(text) return (tostring(text or ""):gsub("```", "'''")) end
local function YouLine(text) return "|cff8fb8e8You:|r " .. NoFence(Shown(text)) end
-- Chat requests: talk/actions/chat all wait for a model reply ("sys" does not).
local function IsChatKind(kind) return kind == "talk" or kind == "actions" or kind == "chat" end
-- CHAT mode per-player state: pending AI request, reply timestamps (3/min), anti-loop mute.
AccLuaAI.chatPeers = {}
local function PeerState(name)
    local st = AccLuaAI.chatPeers[name]
    if not st then st = { hits = {} } AccLuaAI.chatPeers[name] = st end
    return st
end

local scrollPending = 0
-- Invisible hit targets over each ```lua``` fence (FontString alone cannot hit-test a substring).
local codeHitBtns = {}
local function CountNewlines(s)
    local _, n = tostring(s or ""):gsub("\n", "\n")
    return n
end
-- Soft green for code, gold + ▶ for the Apply-selected fence. Returns display text + hit metas.
-- Forward locals BEFORE SyncCodeHits: Lua 5.1 resolves names at compile time; declaring after
-- SyncCodeHits made OnClick call global RenderHistory/CollectLuaBlocks (nil → click error, total=0).
local RenderHistory, CollectLuaBlocks, PreviewBlock, OpenCopy
-- base: blocks counted in earlier history entries (block numbers run across the whole chat).
local InsertEntry, AddHistory, Answer
do -- v17: scope block (Lua 5.1 200-local limit)
local function ColorizeFences(text, selectedIdx, base)
    local s = tostring(text or "")
    local out, hits, n, pos, linesBefore = {}, {}, base or 0, 1, 0
    while true do
        local a, b, lang, body = s:find("```([%w]*)%s*[\r\n](.-)```", pos)
        if not a then
            out[#out + 1] = s:sub(pos)
            break
        end
        local before = s:sub(pos, a - 1)
        out[#out + 1] = before
        linesBefore = linesBefore + CountNewlines(before)
        local lname = string.lower(lang or "")
        if lname ~= "" and lname ~= "lua" and lname ~= "macro" then
            -- Not an Apply block (```text etc.): shown plain, no hit, not counted (= CollectLuaBlocks).
            out[#out + 1] = "```" .. lang .. "\n" .. body .. "\n```"
            linesBefore = linesBefore + CountNewlines(body) + 2
        else
        n = n + 1
        local bodyLines = CountNewlines(body)
        local fenceLines = bodyLines + 2
        local sel = selectedIdx == n
        local open = sel and "|cffe6f0ff" or "|cffa9d8b4"
        local startByte = 0
        for k = 1, #out do startByte = startByte + #out[k] end
        local fenceText = open .. "```" .. lang .. "\n" .. body .. "\n```|r"
        out[#out + 1] = fenceText
        hits[#hits + 1] = { idx = n, line0 = linesBefore, lines = fenceLines,
            s = startByte, e = startByte + #fenceText }
        linesBefore = linesBefore + fenceLines
        end
        pos = b + 1
    end
    return table.concat(out), hits, n
end

local SplitColored
do
-- One display token at byte i: |cAARRGGBB (10), |r or || (2), a whole UTF-8 character, or one byte.
local function TokenLen(s, i)
    local c = s:byte(i)
    local len, kind = 1, nil
    if c == 124 then
        local d = s:sub(i + 1, i + 1)
        if d == "c" and s:sub(i + 2, i + 9):find("^%x%x%x%x%x%x%x%x$") then len, kind = 10, "c"
        elseif d == "r" then len, kind = 2, "r"
        elseif d == "|" then len = 2 end
    elseif c >= 0xF0 then len = 4
    elseif c >= 0xE0 then len = 3
    elseif c >= 0xC0 then len = 2 end
    if i + len - 1 > #s then len = #s - i + 1 end
    return len, kind
end
-- Split one coloured entry into FontString pieces of <= limit bytes: at the last line break that fits,
-- else at a token boundary (never inside |c........, |r, || or a UTF-8 character). A colour open at the
-- cut is re-opened at the start of the next piece (shift = bytes of that prefix).
-- from/to: bytes of the entry text in the piece (a line break used as a cut belongs to no piece).
SplitColored = function(s, limit)
    limit = limit or PIECE_MAX
    local n = #s
    if n <= limit then return { { text = s, from = 1, to = n, shift = 0 } } end
    local pieces, pos, color = {}, 1, nil
    while pos <= n do
        local prefix = color or ""
        local room = limit - #prefix
        if n - pos + 1 <= room then
            pieces[#pieces + 1] = { text = prefix .. s:sub(pos), from = pos, to = n, shift = #prefix }
            break
        end
        local limitEnd = pos + room - 1
        local i, cur = pos, color
        local lastNL, nlColor, safeEnd, safeColor = nil, nil, pos - 1, color
        while i <= limitEnd do
            local len, kind = TokenLen(s, i)
            if i + len - 1 > limitEnd then break end
            if kind == "c" then cur = s:sub(i, i + 9) elseif kind == "r" then cur = nil end
            if len == 1 and i > pos and s:byte(i) == 10 then lastNL, nlColor = i, cur end
            i = i + len
            safeEnd, safeColor = i - 1, cur
        end
        local stop, nextPos, nextColor
        if lastNL then
            stop, nextPos, nextColor = lastNL - 1, lastNL + 1, nlColor
        elseif safeEnd >= pos then
            stop, nextPos, nextColor = safeEnd, safeEnd + 1, safeColor
        else
            stop = pos + TokenLen(s, pos) - 1
            nextPos, nextColor = stop + 1, color
        end
        pieces[#pieces + 1] = { text = prefix .. s:sub(pos, stop), from = pos, to = stop, shift = #prefix }
        pos, color = nextPos, nextColor
    end
    return pieces
end
end

-- Subtle hit overlays: left accent bar + light tint (not a muddy full-block yellow wash).
-- The Copy button shows on hover and on the selected block.
local function PaintCodeHit(b)
    if not b then return end
    -- v20: every code block sits on a dark panel; the selected one gets the blue tint + bright edge.
    if b.selected then
        b.bg:SetTexture(unpack(UI.codeSel))
        if b.edge then b.edge:SetTexture(0.45, 0.75, 1.0, 0.95) end
    else
        b.bg:SetTexture(unpack(UI.code))
        if b.edge then b.edge:SetTexture(0.30, 0.65, 0.45, 0.6) end
    end
    if b.copy then
        if b.selected or b.hover then b.copy:Show() else b.copy:Hide() end
    end
end
local measureFS
local function MeasureHeight(text)
    if not measureFS then
        measureFS = outputChild:CreateFontString(nil, "BACKGROUND")
        measureFS:SetAlpha(0)
        measureFS:SetJustifyH("LEFT")
        measureFS:SetJustifyV("TOP")
        measureFS:SetNonSpaceWrap(true)
        if measureFS.SetWordWrap then measureFS:SetWordWrap(true) end
        measureFS:SetPoint("TOPLEFT", outputChild, "TOPLEFT", 4, -2)
    end
    local font, size, flags = outputText:GetFont()
    if font then measureFS:SetFont(font, size, flags) end
    measureFS:SetSpacing(outputText.GetSpacing and outputText:GetSpacing() or 2)
    measureFS:SetWidth(histTextW)
    measureFS:SetText(text)
    local h = measureFS:GetStringHeight() or 0
    measureFS:SetText("")
    return h
end
-- Pixel span of each fence inside the pieces of one entry: top of its first line (in the piece holding
-- the fence start) .. bottom of its last line (in the piece holding the fence end; may be a later piece).
-- Pieces carry fs (anchor), y (top inside outputChild) and text; measured strings stay <= PIECE_MAX + 2.
local function MeasureHits(pieces, hits, lineH)
    for _, hit in ipairs(hits or {}) do
        local sPos, ePos = (hit.s or 0) + 1, hit.e or 0
        local A, B
        for _, p in ipairs(pieces) do
            if not A and sPos >= p.from and sPos <= p.to then A = p end
            if ePos >= p.from and ePos <= p.to then B = p end
        end
        A = A or pieces[1]
        if not B or B.y < A.y then B = A end
        hit.fs, hit.top, hit.h = A.fs, 0, hit.lines * lineH
        local la = math.max(0, sPos - A.from) + A.shift -- bytes before the fence inside piece A
        local top = 0
        if la > A.shift then
            top = MeasureHeight(A.text:sub(1, la) .. "Xg") - lineH
            if top < 0 then top = CountNewlines(A.text:sub(1, la)) * lineH end
        end
        local lb = math.min(#B.text, ePos - B.from + 1 + B.shift)
        local bottom = MeasureHeight(B.text:sub(1, lb))
        if bottom <= 0 then bottom = (CountNewlines(B.text:sub(1, lb)) + 1) * lineH end
        local h = (B.y + bottom) - (A.y + top)
        if h > 0 then hit.top, hit.h = top, h end
    end
end
local function CopyBlock(idx)
    local blocks = CollectLuaBlocks and CollectLuaBlocks() or {}
    local code = blocks[tonumber(idx) or 0]
    if not code then
        SysStatus("|cffff7777" .. T("Нет такого блока lua", "No such lua block") .. "|r")
        return false
    end
    local copied = OpenCopy and OpenCopy(code)
    if not copied then
        SysStatus(string.format("|cff66ccff%s %d/%d|r - Ctrl+C", T("Код блока", "Code of block"), idx, #blocks))
    end
    return true
end
AccLuaAI.CopyBlock = CopyBlock
local function SyncCodeHits(hits, total)
    total = tonumber(total) or #(hits or {})
    local width = math.max(40, histTextW + 8) -- v20: panel = text column, not the whole child
    for i, hit in ipairs(hits or {}) do
        local b = codeHitBtns[i]
        if not b then
            b = CreateFrame("Button", nil, outputChild)
            b.bg = b:CreateTexture(nil, "BACKGROUND")
            b.bg:SetAllPoints(b)
            b.edge = b:CreateTexture(nil, "ARTWORK")
            b.edge:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
            b.edge:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 0, 0)
            b.edge:SetWidth(2)
            codeHitBtns[i] = b
            -- Copy the raw block (CollectLuaBlocks), not the coloured text.
            b.copy = Button(b, 50, T("Копир.", "Copy"))
            b.copy:SetHeight(16)
            b.copy:SetPoint("TOPRIGHT", b, "TOPRIGHT", -4, -2)
            b.copy.hit = b
            b.copy:Hide()
            b.copy:SetScript("OnClick", function(self) CopyBlock(self.hit.idx) end)
            Tip(b.copy, T("Копировать блок", "Copy block"),
                T("Открыть код этого блока в окне копирования (Ctrl+C). Shift+клик по коду - то же.",
                    "Open this block's code in the copy window (Ctrl+C). Shift+click on the code does the same."))
            local copyLeave = b.copy:GetScript("OnLeave")
            b.copy:SetScript("OnLeave", function(self)
                if copyLeave then copyLeave(self) end
                self.hit.hover = false
                PaintCodeHit(self.hit)
            end)
            local copyEnter = b.copy:GetScript("OnEnter")
            b.copy:SetScript("OnEnter", function(self)
                self.hit.hover = true
                if copyEnter then copyEnter(self) end
            end)
            b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            b:SetScript("OnClick", function(self, button)
                if button == "RightButton" then
                    AccLuaAI.selectedLua = self.idx
                    if type(AccLuaAI.UnloadBlockByIdx) == "function" then
                        AccLuaAI.UnloadBlockByIdx(self.idx)
                    end
                    return
                end
                AccLuaAI.selectedLua = self.idx
                local blocks = CollectLuaBlocks and CollectLuaBlocks() or {}
                local total = #blocks
                if total > 0 and self.idx >= 1 and self.idx <= total then
                    SysStatus(string.format("|cff66ccff%s %d/%d:|r %s",
                        T("Выбран блок", "Selected block"), self.idx, total,
                        Shown(PreviewBlock and PreviewBlock(blocks[self.idx]) or "")))
                end
                local idx = self.idx
                if type(RenderHistory) == "function" then
                    RenderHistory(false)
                elseif type(AccLuaAI.RenderHistory) == "function" then
                    AccLuaAI.RenderHistory(false)
                end
                -- Shift+LMB: copy the block.
                if type(IsShiftKeyDown) == "function" and IsShiftKeyDown() then CopyBlock(idx) end
            end)
            b:SetScript("OnEnter", function(self)
                self.hover = true
                if self.copy then self.copy:Show() end
                if self.selected then
                    self.bg:SetTexture(0.40, 0.60, 1.0, 0.11)
                else
                    self.bg:SetTexture(0.20, 0.55, 0.40, 0.08)
                end
            end)
            b:SetScript("OnLeave", function(self)
                -- Moving onto the Copy button (a child) must not hide it.
                local overCopy = false
                if self.copy and type(GetMouseFocus) == "function" and GetMouseFocus() == self.copy then
                    overCopy = true
                elseif self.copy and self.copy.IsMouseOver then
                    local okM, v = pcall(self.copy.IsMouseOver, self.copy)
                    overCopy = okM and v and true or false
                end
                self.hover = overCopy
                PaintCodeHit(self)
            end)
        end
        b.idx = hit.idx
        b.selected = AccLuaAI.selectedLua == hit.idx
            or (type(AccLuaAI.selectedLua) ~= "number" and hit.idx == total)
        b:ClearAllPoints()
        -- Anchored to the piece holding the fence start: top..bottom = first..last fence line.
        if hit.fs then
            b:SetPoint("TOPLEFT", hit.fs, "TOPLEFT", -2, -(hit.top or 0))
        else
            b:SetPoint("TOPLEFT", outputChild, "TOPLEFT", 2, -2)
        end
        b:SetWidth(width)
        b:SetHeight(math.max(14, hit.h or 14))
        PaintCodeHit(b)
        b:Show()
    end
    for i = #(hits or {}) + 1, #codeHitBtns do
        codeHitBtns[i].hover = false
        codeHitBtns[i]:Hide()
    end
end

-- One FontString piece per entry (more for a long entry), stacked top to bottom; each SetText <= PIECE_MAX.
-- v20: one band + left accent bar per entry (blue = your question, grey = intro/AI-only), and the
-- empty-state example prompts (click = text into the input) while a chat holds only its intro line.
local bandPool, examplePool = {}, {}
-- v24: one "Исправить с AI" button anchored to the newest red error entry (uses the header fixBtn's click).
local errFix
local function PlaceErrFix(fs)
    if not fs or not AccLuaAI.lastError then
        if errFix then errFix:Hide() end
        return
    end
    if not errFix then
        errFix = Button(outputChild, 110, T("Исправить с AI", "Fix with AI"))
        errFix:SetHeight(18)
        errFix.bg:SetTexture(0.55, 0.15, 0.15, 1)
        errFix:SetScript("OnLeave", function(self) self.bg:SetTexture(0.55, 0.15, 0.15, 1) end)
        errFix:SetScript("OnClick", function()
            local f = AccLuaAI.fixBtn
            local h = f and f:GetScript("OnClick")
            if h then h(f) end
        end)
        errFix:SetFrameLevel((outputChild:GetFrameLevel() or 1) + 6)
    end
    FitBtn(errFix, 100)
    errFix:ClearAllPoints()
    errFix:SetPoint("TOPRIGHT", fs, "TOPRIGHT", -2, 2)
    errFix:Show()
end
local function EntryBand(i, firstFS, lastFS, isYou)
    local t = bandPool[i]
    if not t then
        t = { bg = outputChild:CreateTexture(nil, "BACKGROUND"), bar = outputChild:CreateTexture(nil, "BORDER") }
        bandPool[i] = t
    end
    t.bg:ClearAllPoints()
    t.bg:SetPoint("TOPLEFT", firstFS, "TOPLEFT", -9, 4)
    t.bg:SetPoint("BOTTOMRIGHT", lastFS, "BOTTOMRIGHT", 2, -4)
    t.bg:SetTexture(unpack(isYou and UI.you or UI.ai))
    t.bar:ClearAllPoints()
    t.bar:SetPoint("TOPLEFT", firstFS, "TOPLEFT", -9, 4)
    t.bar:SetPoint("BOTTOMLEFT", lastFS, "BOTTOMLEFT", -9, -4)
    t.bar:SetWidth(3)
    t.bar:SetTexture(unpack(isYou and UI.youBar or UI.aiBar))
    t.bg:Show() t.bar:Show()
end
local EXAMPLES = {
    talk = { T("Кнопка, которая кастует заклинание по цели", "A button that casts a spell at the target"),
             T("Макрос: атака + автоповорот к цели", "Macro: attack + auto-face the target"),
             T("Что умеет " .. TQ .. "Cast и " .. TQ .. "1?", "What do " .. TQ .. "Cast and " .. TQ .. "1 do?") },
    actions = { T("прыгни", "jump"), T("сядь", "sit"), T("открой сумку", "open bags") },
    chat = { T("что ответить на «го в данж»?", "what to reply to \"lfg dungeon\"?"),
             T("придумай вежливый отказ", "a polite refusal"), T("поздоровайся кратко", "a short hello") },
}
local function ShowExamples(show, y)
    local list = show and EXAMPLES[ModeOf(AccLuaAI.mode)] or {}
    for k, text in ipairs(list) do
        local b = examplePool[k]
        if not b then
            b = Button(outputChild, 200, "")
            b:SetHeight(18)
            b.text:SetTextColor(0.75, 0.82, 0.95)
            b:SetScript("OnClick", function(self)
                if AccLuaAI.input then AccLuaAI.input:SetText(self.prompt or "") AccLuaAI.input:SetFocus() end
            end)
            examplePool[k] = b
        end
        b.prompt = text
        b.text:SetText("|cff6f8fb8>|r " .. text)
        FitBtn(b, 120)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", outputChild, "TOPLEFT", 12, -(y + 6 + (k - 1) * 21))
        b:Show()
    end
    for k = #list + 1, #examplePool do examplePool[k]:Hide() end
    return show and (#list * 21 + 8) or 0
end
RenderHistory = function(scrollToEnd)
    local list = Chat(AccLuaAI.mode).history
    local total = 0
    -- Live width: the scroll frame knows the real inner width after layout (window resized, CHAT row).
    do
        local ow = output:GetWidth() or 0
        if ow > 60 then histTextW = math.max(180, ow - 22) end
    end
    for i = 1, #list do
        local _, _, n = ColorizeFences(list[i], nil, total)
        total = n
    end
    local sel = AccLuaAI.selectedLua
    if type(sel) ~= "number" or sel < 1 or sel > total then sel = (total > 0) and total or nil end
    local lineH = MeasureHeight("Xg")
    if not lineH or lineH <= 0 then lineH = 16 end
    local y, used, base, prevFS, allHits, errFS = 2, 0, 0, nil, {}, nil
    for i = 1, #list do
        local colored, hits, n = ColorizeFences(list[i], sel, base)
        base = n
        local pieces = SplitColored(colored, PIECE_MAX)
        local firstFS
        for k, p in ipairs(pieces) do
            used = used + 1
            local fs = PoolFS(used)
            fs:ClearAllPoints()
            if prevFS then
                local gap = (k == 1) and ENTRY_GAP or PIECE_GAP
                fs:SetPoint("TOPLEFT", prevFS, "BOTTOMLEFT", 0, -gap)
                y = y + gap
            else
                fs:SetPoint("TOPLEFT", outputChild, "TOPLEFT", 12, -6)
                y = 6
            end
            firstFS = firstFS or fs
            fs:SetWidth(histTextW)
            fs:SetHeight(0) -- v18: drop the previous piece's fixed height (it clipped longer text to "...")
            fs:SetText(p.text)
            local h = fs:GetStringHeight() or 0
            if h < 1 then h = 1 end
            fs:SetHeight(h)
            fs:Show()
            p.fs, p.y = fs, y
            y = y + h
            prevFS = fs
        end
        if hits[1] then pcall(MeasureHits, pieces, hits, lineH) end
        for _, hit in ipairs(hits) do allHits[#allHits + 1] = hit end
        if firstFS then EntryBand(i, firstFS, prevFS, list[i]:find("You:|r", 1, true) ~= nil) end
        if firstFS and list[i]:find("^|cffff5555") then errFS = firstFS end
    end
    PlaceErrFix(errFS)
    for i = used + 1, #histPool do
        histPool[i]:SetText("")
        histPool[i]:Hide()
    end
    for i = #list + 1, #bandPool do bandPool[i].bg:Hide() bandPool[i].bar:Hide() end
    y = y + ShowExamples(#list <= 1, y)
    outputChild:SetHeight(math.max(1, y + 8))
    output:UpdateScrollChildRect()
    SyncCodeHits(allHits, total)
    if scrollToEnd then scrollPending = 3 end -- the scroll range is final only on the next frames
end
AccLuaAI.RenderHistory = RenderHistory

-- Stored entry indexes (pending request, queued items) follow inserts/removals in their chat.
local function ShiftIdx(mode, from, delta)
    local function fix(i)
        if i and i >= from then
            i = i + delta
            if i < 1 then i = nil end
        end
        return i
    end
    if AccLuaAI.pendingMode and ModeOf(AccLuaAI.pendingMode) == mode then AccLuaAI.pendingIdx = fix(AccLuaAI.pendingIdx) end
    for _, q in ipairs(AccLuaAI.queue) do
        if q.mode == mode then q.idx = fix(q.idx) end
    end
end

function InsertEntry(mode, pos, text, plain)
    mode = ModeOf(mode)
    local chat = Chat(mode)
    table.insert(chat.history, pos, tostring(text or ""))
    table.insert(chat.plain, pos, plain or "")
    ShiftIdx(mode, pos, 1)
    while #chat.history > 40 do
        table.remove(chat.history, 1)
        table.remove(chat.plain, 1)
        chat.top = math.max(0, (chat.top or 0) - 1)
        ShiftIdx(mode, 1, -1)
        pos = pos - 1
    end
    if mode == ModeOf(AccLuaAI.mode) then RenderHistory(true) end
    return pos
end

function AddHistory(mode, text, plain)
    return InsertEntry(mode, #Chat(mode).history + 1, text, plain)
end

-- Put the answer into the "You / AI" entry of the pending request, in the chat it was sent from.
-- CHAT-mode game requests (item.game): the entry is "AI -> Name (ЛС): reply" and the player's
-- one-pending-request slot is released here (reply, timeout or cancel).
function Answer(shown, plain)
    local mode = ModeOf(AccLuaAI.pendingMode or AccLuaAI.mode)
    local chat = Chat(mode)
    local i = AccLuaAI.pendingIdx
    local item = AccLuaAI.pendingItem
    local game = type(item) == "table" and item.game
    AccLuaAI.pendingIdx, AccLuaAI.pendingItem = nil, nil
    if game then PeerState(item.sender).pending = nil end
    local line = game and ((AccLuaAI.pendingYou or "") .. " " .. shown)
    if i and i >= 1 and chat.history[i] and AccLuaAI.pendingYou then
        chat.history[i] = line or (AccLuaAI.pendingYou .. AI_LINE .. shown)
        chat.plain[i] = plain or ""
        if mode == ModeOf(AccLuaAI.mode) then RenderHistory(true) end
    else
        AddHistory(mode, line or ("|cffb8c5d6AI:|r " .. shown), plain)
    end
    AccLuaAI.pendingYou, AccLuaAI.pendingMode, AccLuaAI.pendingCode = nil, nil, nil
end

end
local function Resized()
    -- ScrollFrame:GetWidth() is often 0 before first layout → old code clamped to 100 (narrow wrap).
    local fw = frame:GetWidth() or 640
    local w = fw - 36 -- left pad 8 + scrollbar/right 28
    if w < 200 then w = 200 end
    outputChild:SetWidth(w)
    histTextW = math.max(180, w - 22)
    outputText:SetWidth(histTextW)
    RenderHistory(false)
end
frame:SetScript("OnSizeChanged", Resized)
frame:SetScript("OnShow", function()
    Resized()
    LayoutHeader()
end)

local grip = CreateFrame("Button", nil, frame)
grip:SetWidth(16)
grip:SetHeight(16)
grip:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -3, 3)
grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
grip:SetScript("OnMouseUp", function() frame:StopMovingOrSizing() Resized() end)

local input = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
AccLuaAI.input = input
input:SetAutoFocus(false)
input:SetMaxLetters(500)
input:SetHeight(24)
input:SetFontObject("GameFontHighlight")
Font(input, 13)
input:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 16, 9)
input:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -106, 9)
-- v20: grey placeholder inside the empty input (mode-dependent text set by UpdateMode).
local inputHint = input:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
inputHint:SetPoint("LEFT", input, "LEFT", 2, 0)
inputHint:SetPoint("RIGHT", input, "RIGHT", -4, 0)
inputHint:SetJustifyH("LEFT")
inputHint:SetTextColor(0.5, 0.55, 0.65)
Font(inputHint, 12)
AccLuaAI.inputHint = inputHint
local function SyncHint()
    local txt = input:GetText()
    if (txt == nil or txt == "") and not input:HasFocus() then inputHint:Show() else inputHint:Hide() end
end
input:SetScript("OnTextChanged", SyncHint)
-- v22: Shift-click on an item/spell/quest/etc. inserts the link here when this box has focus
-- (the client calls ChatEdit_InsertLink for the chat box; we take the link first).
do
    local orig = _G.ChatEdit_InsertLink
    if type(orig) == "function" and not AccLuaAI._linkHooked then
        _G.ChatEdit_InsertLink = function(link, ...)
            if type(link) == "string" and input:HasFocus() and input:IsVisible() then
                input:Insert(link)
                return true
            end
            return orig(link, ...)
        end
        AccLuaAI._linkHooked = true
    end
end
input:SetScript("OnEditFocusGained", SyncHint)
input:SetScript("OnEditFocusLost", SyncHint)
local sendBtn = Button(frame, 56, "Send")
sendBtn:SetHeight(22)
sendBtn:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -24, 9)
-- Recall the previous question (same as the Up arrow in the input). The arrow is a texture:
-- the Friz font has no arrow glyph.
local recallBtn = Button(frame, 18, "")
AccLuaAI.recallBtn = recallBtn
recallBtn:SetHeight(22)
recallBtn:SetPoint("RIGHT", sendBtn, "LEFT", -4, 0)
recallBtn.icon = recallBtn:CreateTexture(nil, "ARTWORK")
recallBtn.icon:SetTexture("Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Up")
recallBtn.icon:SetTexCoord(0.22, 0.78, 0.25, 0.75)
recallBtn.icon:SetWidth(16)
recallBtn.icon:SetHeight(16)
recallBtn.icon:SetPoint("CENTER")
-- Request Stop: visible only while a TALK/ACTIONS reply is awaited (the input shrinks to make room).
local cancelBtn = Button(frame, 48, T("Стоп", "Stop"))
cancelBtn:SetHeight(22)
cancelBtn:SetPoint("RIGHT", recallBtn, "LEFT", -4, 0)
cancelBtn:Hide()

local function SetRun(on) if on then runBtn:Show() else runBtn:Hide() end LayoutHeader() end

local function UpdateMode()
    local chatMode = AccLuaAI.mode == "chat"
    SetActive(modeBtn, AccLuaAI.mode ~= "actions" and not chatMode)
    SetActive(actBtn, AccLuaAI.mode == "actions")
    SetActive(chatBtn, chatMode)
    if AccLuaAI.mode == "actions" then
        status:SetText(T("ACTIONS: опишите действие (прыгни, сядь, открой сумку, иди к NPC ...)",
            "ACTIONS: describe an action (jump, sit, open bags, go to NPC ...)"))
    elseif chatMode then
        status:SetText(T("CHAT: ИИ отвечает в ЛС / Сказать только с включёнными переключателями. Поле ввода - вопрос к ИИ.",
            "CHAT: the AI replies in whisper / say only with a toggle on. The input asks the AI."))
    else
        status:SetText(T("TALK: вопрос, код, макрос (? = поиск в интернете)", "TALK: question, code, macro (? = web search)"))
    end
    -- v20: placeholder in the input follows the mode.
    if AccLuaAI.inputHint then
        AccLuaAI.inputHint:SetText(chatMode and T("Вопрос к ИИ, в игру не уходит...", "Ask the AI (never sent to the game)...")
            or AccLuaAI.mode == "actions" and T("Что сделать? Например: прыгни, сядь, открой сумку", "What to do? e.g. jump, sit, open bags")
            or T("Спросите ИИ или опишите нужный код...", "Ask the AI or describe the code you need..."))
    end
    -- CHAT options occupy two lines under the status line: the history starts lower.
    if chatMode then chatRow:Show() else chatRow:Hide() end
    output:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, chatMode and OUT_Y.chat or OUT_Y.base)
    if type(AccLuaAI.RefreshChatUI) == "function" then AccLuaAI.RefreshChatUI() end
    LayoutHeader()
end

-- The model never supplies Lua.  This dispatcher owns the only permitted
-- static snippets and can therefore reject every other action type.
local executor = AccLuaAI.executor or { active = false, steps = {}, plan = nil, navigation = nil }
AccLuaAI.executor = executor
local staticLua, numericLimits, riskyActions, actionLabels, DispatchStatic
do -- v17: scope block (Lua 5.1 200-local limit)
staticLua = {
    FORWARD_START = "MoveForwardStart()",
    FORWARD_STOP = "MoveForwardStop()",
    MOVE_FORWARD_START = "MoveForwardStart()",
    MOVE_FORWARD_STOP = "MoveForwardStop()",
    MOVE_BACKWARD_START = "MoveBackwardStart()",
    MOVE_BACKWARD_STOP = "MoveBackwardStop()",
    STRAFE_LEFT_START = "StrafeLeftStart()",
    STRAFE_LEFT_STOP = "StrafeLeftStop()",
    STRAFE_RIGHT_START = "StrafeRightStart()",
    STRAFE_RIGHT_STOP = "StrafeRightStop()",
    TURN_LEFT_START = "TurnLeftStart()",
    TURN_LEFT_STOP = "TurnLeftStop()",
    TURN_RIGHT_START = "TurnRightStart()",
    TURN_RIGHT_STOP = "TurnRightStop()",
    AUTORUN_START = "if StartAutoRun then StartAutoRun() elseif ToggleAutoRun then ToggleAutoRun() end",
    AUTORUN_STOP = "if StopAutoRun then StopAutoRun() end",
    JUMP = "JumpOrAscendStart()",
    SIT = "SitStandOrDescendStart()",
    SIT_STAND = "SitStandOrDescendStart()",
    EMOTE_DANCE = "DoEmote(\"dance\")",
    EMOTE_WAVE = "DoEmote(\"wave\")",
    EMOTE_BOW = "DoEmote(\"bow\")",
    EMOTE_CHEER = "DoEmote(\"cheer\")",
    EMOTE_POINT = "DoEmote(\"point\")",
    EMOTE_LAUGH = "DoEmote(\"laugh\")",
    EMOTE_KNEEL = "DoEmote(\"kneel\")",
    EMOTE_SALUTE = "DoEmote(\"salute\")",
    TARGET_NEAREST_ENEMY = "TargetNearestEnemy()",
    TARGET_LAST = "TargetLastTarget()",
    CLEAR_TARGET = "ClearTarget()",
    FOCUS_TARGET = "FocusUnit(\"target\")",
    CLEAR_FOCUS = "ClearFocus()",
    FOLLOW_TARGET = "FollowUnit(\"target\")",
    ASSIST_TARGET = "AssistUnit(\"target\")",
    INTERACT_TARGET = "InteractUnit(\"target\")",
    ATTACK_TARGET = "AttackTarget()",
    STOP_ATTACK = "StopAttack()",
    STOP_CASTING = "SpellStopCasting()",
    DISMOUNT = "Dismount()",
    CLOSE_GOSSIP = "pcall(CloseGossip) pcall(CloseMerchant) pcall(CloseQuest)",
    ACCEPT_QUEST = "AcceptQuest()",
    DECLINE_QUEST = "DeclineQuest()",
    COMPLETE_QUEST = "CompleteQuest()",
    OPEN_BAGS = "if OpenAllBags then OpenAllBags() end",
}

numericLimits = {
    GOSSIP_OPTION = {1, 32},
    GOSSIP_AVAILABLE_QUEST = {1, 32},
    GOSSIP_ACTIVE_QUEST = {1, 32},
    QUEST_REWARD = {1, 32},
    USE_ACTION_SLOT = {1, 120},
}

riskyActions = {
    GOSSIP_OPTION = true,
    GOSSIP_AVAILABLE_QUEST = true,
    GOSSIP_ACTIVE_QUEST = true,
    ACCEPT_QUEST = true,
    DECLINE_QUEST = true,
    COMPLETE_QUEST = true,
    QUEST_REWARD = true,
    USE_ACTION_SLOT = true,
}

actionLabels = {
    MOVE_FORWARD_START = "forward start", MOVE_FORWARD_STOP = "forward stop",
    MOVE_BACKWARD_START = "backward start", MOVE_BACKWARD_STOP = "backward stop",
    STRAFE_LEFT_START = "strafe left start", STRAFE_LEFT_STOP = "strafe left stop",
    STRAFE_RIGHT_START = "strafe right start", STRAFE_RIGHT_STOP = "strafe right stop",
    TURN_LEFT_START = "turn left start", TURN_LEFT_STOP = "turn left stop",
    TURN_RIGHT_START = "turn right start", TURN_RIGHT_STOP = "turn right stop",
    AUTORUN_START = "autorun start", AUTORUN_STOP = "autorun stop",
    JUMP = "jump", SIT_STAND = "sit/stand", STOP_ALL = "stop",
    NAVIGATE_NPC = "go to NPC", NAVIGATE_NPC_OPEN = "go to and open NPC",
    CHAT_DRAFT = "prepare chat draft", OPEN_BAGS = "open bags",
}

local heldStopActions = {
    "MOVE_FORWARD_STOP", "MOVE_BACKWARD_STOP",
    "STRAFE_LEFT_STOP", "STRAFE_RIGHT_STOP",
    "TURN_LEFT_STOP", "TURN_RIGHT_STOP", "AUTORUN_STOP",
}

-- Movement must go through the local Multibox-style key bridge.  On this
-- client the same calls issued as raw Lua can succeed silently without
-- changing player input.  The bridge accepts only these fixed operations.
local inputOperation = {
    MOVE_FORWARD_START = "forward_down", MOVE_FORWARD_STOP = "forward_up",
    MOVE_BACKWARD_START = "backward_down", MOVE_BACKWARD_STOP = "backward_up",
    STRAFE_LEFT_START = "strafe_left_down", STRAFE_LEFT_STOP = "strafe_left_up",
    STRAFE_RIGHT_START = "strafe_right_down", STRAFE_RIGHT_STOP = "strafe_right_up",
    TURN_LEFT_START = "turn_left_down", TURN_LEFT_STOP = "turn_left_up",
    TURN_RIGHT_START = "turn_right_down", TURN_RIGHT_STOP = "turn_right_up",
    JUMP = "jump", SIT = "sit_stand", SIT_STAND = "sit_stand",
}

function DispatchStatic(action, arg, text)
    if action == "CHAT_DRAFT" then
        local draftText = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if draftText == "" or #draftText > 80 then return false end
        AccLuaAI.chat.draft = {
            channel = "SAY",
            target = nil,
            text = draftText,
        }
        executor.completionStatus =
            "Chat draft ready - press Say to send it"
        return true
    end
    if action == "STOP_ALL" then
        local stopped = false
        if type(AccLuaAIInput) == "function" then
            local ok, value = pcall(AccLuaAIInput, "all_up")
            stopped = ok and value and true or false
        end
        if not stopped and type(Tesq1) == "function" then
            for _, stopAction in ipairs(heldStopActions) do
                pcall(Tesq1, staticLua[stopAction])
            end
        end
        if type(AccLuaAIStopNavigation) == "function" then
            pcall(AccLuaAIStopNavigation)
        end
        return true
    end
    local operation = inputOperation[action]
    if operation then
        if type(AccLuaAIInput) ~= "function" then return false end
        local ok, value = pcall(AccLuaAIInput, operation)
        return ok and value and true or false
    end
    if type(Tesq1) ~= "function" then return false end
    if action == "NAVIGATE_NPC" or action == "NAVIGATE_NPC_OPEN" then
        if action == "NAVIGATE_NPC_OPEN" and staticLua.CLOSE_GOSSIP then
            -- A frame left open by a previous NPC must not be mistaken for
            -- confirmation of this new interaction.
            pcall(Tesq1, staticLua.CLOSE_GOSSIP)
        end
        executor.navigation = {
            query = text,
            requestedQuery = text,
            open = action == "NAVIGATE_NPC_OPEN",
            phase = "find",
            startedAt = GetTime(),
            nextAt = 0,
            bestDistance = nil,
            lastProgressAt = GetTime(),
            exactName = nil,
            interactDeadline = nil,
            nextInteractAt = 0,
        }
        return true
    end
    local code = staticLua[action]
    if not code and numericLimits[action] then
        arg = tonumber(arg)
        local bounds = numericLimits[action]
        if not arg or arg < bounds[1] or arg > bounds[2] or arg ~= math.floor(arg) then
            return false
        end
        if action == "GOSSIP_OPTION" then
            code = "SelectGossipOption(" .. arg .. ")"
        elseif action == "GOSSIP_AVAILABLE_QUEST" then
            code = "SelectGossipAvailableQuest(" .. arg .. ")"
        elseif action == "GOSSIP_ACTIVE_QUEST" then
            code = "SelectGossipActiveQuest(" .. arg .. ")"
        elseif action == "QUEST_REWARD" then
            code = "GetQuestReward(" .. arg .. ")"
        elseif action == "USE_ACTION_SLOT" then
            code = "UseAction(" .. arg .. ")"
        end
    end
    if not code then return false end
    local ok = pcall(Tesq1, code)
    return ok
end

end
local function ForceStop(reason)
    -- Release held keys only when an action was really running (no stray calls on Disable).
    if executor.active or executor.navigation then DispatchStatic("STOP_ALL", 0, "") end
    executor.active = false
    executor.steps = {}
    executor.navigation = nil
    executor.completionStatus = nil
    if reason then status:SetText(reason) end
end

local function IsWorldReady()
    if type(UnitExists) ~= "function" or not UnitExists("player") then return false end
    if type(UnitIsDeadOrGhost) == "function" and UnitIsDeadOrGhost("player") then return false end
    if type(UnitOnTaxi) == "function" and UnitOnTaxi("player") then return false end
    return type(Tesq1) == "function"
end

local function ParseQAPlan(text)
    text = tostring(text or "")
    local unsupported = text:match("%[QA_UNSUPPORTED%](.-)%[/QA_UNSUPPORTED%]")
    if unsupported then
        return nil, Trim(unsupported)
    end
    local block = text:match("%[QA_PLAN%]%s*(.-)%s*%[/QA_PLAN%]")
    if not block then return nil end
    local steps, summary, sequence = {}, {}, 0
    local requiresConfirm = false
    local navigationCount = 0
    for rawLine in block:gmatch("[^|]+") do
        local atText, action, argText, extra =
            rawLine:match("^%s*(%d+)%s+([A-Z_]+)%s+(%d+)%s*(.-)%s*$")
        local at = tonumber(atText)
        local arg = tonumber(argText)
        extra = Trim(extra)
        if not at or at < 0 or at > 30000 or not arg or arg ~= math.floor(arg) then
            return nil, "Action timeline failed local validation"
        end
        local knownPlain = staticLua[action] ~= nil or action == "STOP_ALL"
        local bounds = numericLimits[action]
        local navigation = action == "NAVIGATE_NPC" or action == "NAVIGATE_NPC_OPEN"
        local chatDraft = action == "CHAT_DRAFT"
        if knownPlain then
            if arg ~= 0 or extra ~= "" then
                return nil, "Unexpected action parameters rejected"
            end
        elseif bounds then
            if arg < bounds[1] or arg > bounds[2] or extra ~= "" then
                return nil, "Numeric action parameter rejected"
            end
        elseif navigation then
            if arg ~= 0 or extra == "" or #extra > 80
                or extra:find("[|%[%]]") or extra:find("%c") then
                return nil, "NPC name fragment failed local validation"
            end
            navigationCount = navigationCount + 1
        elseif chatDraft then
            if arg ~= 0 or extra == "" or #extra > 80
                or extra:find("[|%[%]]") or extra:find("%c") then
                return nil, "Chat draft failed local validation"
            end
        else
            return nil, "Unknown action rejected: " .. tostring(action)
        end
        sequence = sequence + 1
        if sequence > 24 then return nil, "Action plan is too long" end
        table.insert(steps, {
            at = at, action = action, arg = arg, text = extra, seq = sequence,
        })
        local label = actionLabels[action] or action:lower():gsub("_", " ")
        if navigation then label = label .. " \"" .. extra .. "\"" end
        table.insert(summary, label .. " @" .. at .. "ms")
        if riskyActions[action] then requiresConfirm = true end
    end
    if #steps == 0 then return nil, "No allowed QA actions in the model reply" end
    if navigationCount > 0 and #steps ~= 1 then
        return nil, "NPC navigation must be a separate action plan"
    end
    table.sort(steps, function(a, b)
        return a.at == b.at and a.seq < b.seq or a.at < b.at
    end)
    return steps, table.concat(summary, ", "), requiresConfirm
end

local function IsNpcUiShown()
    return (MerchantFrame and MerchantFrame:IsShown())
        or (GossipFrame and GossipFrame:IsShown())
        or (QuestFrame and QuestFrame:IsShown())
end

local function TargetAndInteractNpc(exactName)
    if type(Tesq1) ~= "function" then return false end
    local safeName = tostring(exactName or ""):gsub("%c", " "):sub(1, 80)
    if safeName == "" then return false end
    -- exactName comes from the validated in-process object scan, never from
    -- model-generated Lua. %q prevents a game/server supplied name from
    -- escaping the one fixed target/interact snippet.
    local quoted = string.format("%q", safeName)
    local code =
        "local n=" .. quoted .. " " ..
        "if RunMacroText then pcall(RunMacroText,'/targetexact '..n) end " ..
        "if UnitExists and UnitExists('target') and InteractUnit then " ..
        "pcall(InteractUnit,'target') end"
    return pcall(Tesq1, code)
end

local function UpdateNpcNavigation()
    local nav = executor.navigation
    if not nav then return end
    local now = GetTime()
    if nav.phase == "interact" then
        if IsNpcUiShown() then
            ForceStop("NPC opened: " .. tostring(nav.exactName or nav.query))
            return
        end
        if now >= (nav.interactDeadline or 0) then
            ForceStop("Reached NPC, but merchant/gossip did not open")
            return
        end
        if now >= (nav.nextInteractAt or 0) then
            TargetAndInteractNpc(nav.exactName)
            nav.nextInteractAt = now + 1
            status:SetText("Interacting with " .. tostring(nav.exactName or nav.query) .. "...")
        end
        return
    end
    if type(AccLuaAINpcStep) ~= "function" then
        ForceStop("NPC navigation needs the updated AccLua DLL")
        return
    end
    if now < (nav.nextAt or 0) then return end
    nav.nextAt = now + 0.4
    local ok, state, exactName, distance = pcall(AccLuaAINpcStep, nav.query)
    if not ok then
        ForceStop("NPC navigation bridge failed safely")
        return
    end
    distance = tonumber(distance)
    if state == "moving" then
        if exactName and tostring(exactName) ~= "" and not nav.exactName then
            -- Lock the first in-process match. Subsequent scans use the full
            -- exact name instead of jumping between partial-name matches.
            nav.exactName = tostring(exactName)
            nav.query = nav.exactName
        end
        if distance then
            if not nav.bestDistance or distance < nav.bestDistance - 0.25 then
                nav.bestDistance = distance
                nav.lastProgressAt = now
            elseif now - (nav.lastProgressAt or now) > 5 then
                ForceStop("NPC route is blocked or the character is stuck")
                return
            end
            status:SetText(string.format("Moving to %s — %.1f m",
                tostring(exactName or nav.query), distance))
        end
    elseif state == "arrived" then
        nav.exactName = tostring(exactName or nav.query)
        if not nav.open then
            ForceStop("Reached NPC: " .. nav.exactName)
            return
        end
        nav.phase = "interact"
        nav.interactDeadline = now + 7
        nav.nextInteractAt = 0
        TargetAndInteractNpc(nav.exactName)
    elseif state == "not_found" then
        if now - nav.startedAt > 5 then
            ForceStop("NPC not found nearby: " .. tostring(nav.requestedQuery or nav.query))
            return
        else
            status:SetText("Looking for NPC: " .. tostring(nav.requestedQuery or nav.query))
        end
    else
        ForceStop("NPC navigation rejected invalid game state")
        return
    end
    if now - nav.startedAt > 30 then
        ForceStop("NPC navigation timed out")
    end
end

local function StartConfirmedPlan()
    if not executor.plan then
        status:SetText("No confirmed local QA plan")
        return
    end
    if not IsWorldReady() then
        status:SetText("World is not ready; action was not started")
        return
    end
    ForceStop()
    executor.completionStatus = nil
    executor.steps = {}
    local startAt = GetTime()
    for _, step in ipairs(executor.plan) do
        table.insert(executor.steps, {
            at = startAt + (step.at / 1000),
            action = step.action,
            arg = step.arg,
            text = step.text,
        })
    end
    executor.active = true
    SetRun(false)
    status:SetText("Local QA action running — Stop act cancels it")
end


-- Context buttons: Run (plan needs confirmation), Stop act (action running), Say (chat draft ready),
-- request Stop next to Send (a TALK/ACTIONS reply is awaited).
local cancelShown
local function UpdateContext()
    if executor.active then stopBtn:Show() else stopBtn:Hide() end
    if AccLuaAI.chat.draft then sayBtn:Show() else sayBtn:Hide() end
    if not (executor.plan and executor.requiresConfirm and not executor.active) then runBtn:Hide() end
    LayoutHeader()
    local busy = IsChatKind(AccLuaAI.waitingKind)
    if busy ~= cancelShown then
        cancelShown = busy
        if busy then cancelBtn:Show() else cancelBtn:Hide() end
        input:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", busy and -158 or -106, 9)
    end
end

-- One model reply as shown in the chat (live replies and restored history use the same rules).
local FormatReply, sysQueue, Sys, bootAt, ChatBlocked, AfterChat, GameHead, SendRequest, PumpQueue, QueueText, SubmitText, DropQueue
do -- v17: scope block (Lua 5.1 200-local limit)
-- v18: [WORKING_LUA]..[/WORKING_LUA] is the host's file payload (already saved to working.lua).
-- Shown once: dropped when a ```fence follows, else turned into a ```lua fence.
local function StripWorkingTag(text)
    local s, e = text:find("%[WORKING_LUA%]")
    if not s then return text end
    local cs, ce = text:find("%[/WORKING_LUA%]", e + 1)
    if not cs then return text end
    local body = Trim(text:sub(e + 1, cs - 1))
    local rest = text:sub(1, s - 1) .. text:sub(ce + 1)
    if body:sub(1, 3) == "```" then
        body = body:gsub("^```[%w]*\n?", ""):gsub("\n?```%s*$", "")
    end
    if rest:find("```", 1, true) or body == "" then return Trim(rest) end
    return Trim(text:sub(1, s - 1) .. "```lua\n" .. body .. "\n```" .. text:sub(ce + 1))
end
function FormatReply(text)
    text = StripWorkingTag(tostring(text or ""))
    if text == "" then text = T("(пустой ответ)", "(empty answer)") end
    local qaError = text:match("%[QA_ERROR%](.-)%[/QA_ERROR%]")
    if qaError then return "|cffff7777" .. Shown(qaError) .. "|r", "", nil, nil, nil, qaError end
    local steps, planStatus, requiresConfirm = ParseQAPlan(text)
    if steps then return T("План: ", "Plan: ") .. Shown(planStatus), "", steps, planStatus, requiresConfirm end
    if planStatus and planStatus ~= "" then return Shown(planStatus), planStatus, nil, planStatus end
    return Shown(text), text, nil, planStatus
end

-- Silent host commands (model list / switch / download / delete / think / reset): one at a time, sent by the
-- ticker even while a chat reply is awaited. Queued chat messages go out only after them.
-- bootAt: startup commands not queued yet (chat waits too).
sysQueue = {}
function Sys(cmd) table.insert(sysQueue, cmd) end
bootAt = GetTime() + 2

-- A chat request waits for startup, a pending chat reply and the silent commands queued or in flight
-- (they are answered at once; the startup [AI:CANCEL] must reach the host before any new question).
function ChatBlocked()
    return AccLuaAI.waitingKind ~= nil or bootAt ~= nil or sysQueue[1] ~= nil or SysAwaited()
end

-- Commands the host refused with "busy" while it generates (reset / delete / switch): sent again once the
-- chat reply is in (at most 3 tries each, then the host's answer is shown).
function AfterChat(cmd)
    local tries = AccLuaAI.afterTries or {}
    AccLuaAI.afterTries = tries
    local n = (tries[cmd] or 0) + 1
    if n > 3 then tries[cmd] = nil return false end
    tries[cmd] = n
    AccLuaAI.afterChat = AccLuaAI.afterChat or {}
    AccLuaAI.afterChat[cmd] = true
    AccLuaAI.afterChatAt = GetTime() + 2
    return true
end

-- Code questions (thinking applies to them): Lua 5.1 lower() leaves Cyrillic alone, so both cases are listed.
local CODE_WORDS = { "код", "Код", "КОД", "макрос", "Макрос", "скрипт", "Скрипт", "функци", "Функци", "аддон", "Аддон",
    "lua", "macro", "script", "code", "function", "addon", "/run" }
local function IsCodeRequest(text)
    local low = tostring(text or ""):lower()
    for _, w in ipairs(CODE_WORDS) do
        if low:find(w, 1, true) then return true end
    end
    return false
end

-- Send one chat request now (typed or taken from the queue); a queued item re-uses its "(в очереди)" entry.
-- CHAT game request head: "AI -> Name (ЛС):" (the reply follows on the same line).
function GameHead(item)
    local ch = item.channel == "WHISPER" and T("ЛС", "whisper") or T("Сказать", "say")
    return "|cffd9a0ffAI -> " .. Shown(item.sender) .. " (" .. ch .. "):|r"
end
-- A CHAT typed question goes to the host like a TALK one (never to the game chat);
-- a game request (item.game) carries [AI:CHAT] + sender + channel.
function SendRequest(item)
    local hostRequest = item.text
    if item.game then hostRequest = item.host
    elseif item.mode == "actions" then hostRequest = "[AI:ACTIONS] " .. item.text end
    if not SendTracked(item.mode, hostRequest) then return false end
    local chat = Chat(item.mode)
    local you = item.game and GameHead(item) or YouLine(item.text)
    local waitLine = item.game and (you .. " ...") or (you .. AI_LINE .. "...")
    AccLuaAI.pendingMode, AccLuaAI.pendingYou, AccLuaAI.pendingIdx, AccLuaAI.pendingItem = item.mode, you, nil, item
    AccLuaAI.pendingCode = item.mode == "talk" and IsCodeRequest(item.text)
    if item.idx and chat.history[item.idx] then
        chat.history[item.idx] = waitLine
        chat.plain[item.idx] = ""
        AccLuaAI.pendingIdx = item.idx
        if item.mode == ModeOf(AccLuaAI.mode) then RenderHistory(true) end
    else
        AccLuaAI.pendingIdx = AddHistory(item.mode, waitLine, "")
    end
    return true
end

-- Next queued message, once no chat reply is awaited and the silent commands are out.
function PumpQueue()
    if ChatBlocked() or not AccLuaAI.queue[1] then return false end
    local item = table.remove(AccLuaAI.queue, 1)
    if not SendRequest(item) then
        table.insert(AccLuaAI.queue, 1, item)
        return false
    end
    UpdateContext()
    return true
end

function QueueText() return T("В очереди: ", "Queued: ") .. #AccLuaAI.queue end

-- Sent questions per chat for Up/Down recall (like a shell history): queued and cancelled ones included.
local function Remember(mode, text)
    local chat = Chat(mode)
    local sent = chat.sent
    if sent[#sent] ~= text then
        sent[#sent + 1] = text
        while #sent > 30 do table.remove(sent, 1) end
    end
    chat.recall, chat.unsent = nil, nil
end

-- dir -1 = older (Up / the arrow button), +1 = newer (Down). Down past the newest restores the unsent text.
local function Recall(dir)
    local chat = Chat(AccLuaAI.mode)
    local sent, pos = chat.sent, chat.recall
    if not sent[1] then return end
    if dir < 0 then
        if not pos then
            chat.unsent = input:GetText()
            pos = #sent + 1
        end
        pos = math.max(1, math.min(pos, #sent + 1) - 1)
    else
        if not pos then return end
        pos = pos + 1
        if pos > #sent then
            chat.recall = nil
            input:SetText(chat.unsent or "")
            chat.unsent = nil
            return
        end
    end
    chat.recall = pos
    input:SetText(sent[pos])
end

-- The Up/Down keys may reach both OnKeyDown and OnArrowPressed: one step per key press (GetTime is per frame).
local lastArrow = {}
local function ArrowKey(key)
    if key ~= "UP" and key ~= "DOWN" then return end
    local now = GetTime()
    if lastArrow.key == key and lastArrow.at == now then return end
    lastArrow.key, lastArrow.at = key, now
    Recall(key == "UP" and -1 or 1)
end

-- A question as if typed into the input (Submit, and "Исправить с AI"): sent now or queued.
-- v22: |cff..|Hitem:1234:...|h[Name]|h|r  ->  [Name] (item:1234)   (plain text for the host/model)
local function FlattenLinks(text)
    return (tostring(text or ""):gsub("|c%x%x%x%x%x%x%x%x|H([^|:]+):([^|:]+)[^|]*|h(%[.-%])|h|r", function(kind, id, name)
        return name .. " (" .. kind .. ":" .. id .. ")"
    end):gsub("|H([^|:]+):([^|:]+)[^|]*|h(%[.-%])|h", function(kind, id, name)
        return name .. " (" .. kind .. ":" .. id .. ")"
    end))
end
AccLuaAI.FlattenLinks = FlattenLinks
function SubmitText(request, mode, noRecall)
    request = Trim(FlattenLinks(request))
    if request == "" then return false end
    local item = { mode = ModeOf(mode or AccLuaAI.mode), text = request }
    if ChatBlocked() or AccLuaAI.queue[1] then
        if #AccLuaAI.queue >= 10 then
            status:SetText(T("Очередь заполнена (10) - дождитесь ответа", "Queue is full (10) - wait for a reply"))
            return false
        end
        item.idx = AddHistory(item.mode, YouLine(request) .. AI_LINE .. "|cff999999" .. T("(в очереди)", "(queued)") .. "|r", "")
        table.insert(AccLuaAI.queue, item)
        status:SetText(QueueText())
    elseif not SendRequest(item) then
        status:SetText(T("Дождитесь текущего ответа", "Wait for the current reply"))
        return false
    end
    if not noRecall then Remember(item.mode, request) end
    UpdateContext()
    return true
end
local function Submit()
    if not SubmitText(input:GetText(), AccLuaAI.mode) then return end
    input:SetText("")
    input:ClearFocus()
end

-- Request Stop: [AI:CANCEL] goes straight to the host (not through the silent queue, which may be busy).
-- The entry is marked at once; the [CANCEL] ack (or 15 s) releases the chat wait and the queue.
-- AccLuaAI.CancelRequest: HandleSys is another do-block (Lua 5.1); local CancelRequest is invisible there.
local function CancelRequest()
    local kind = AccLuaAI.waitingKind
    if not IsChatKind(kind) then return end
    if not SendToHost("[AI:CANCEL]") then return end
    local now = GetTime()
    AccLuaAI.waitingKind, AccLuaAI.waitingSince, AccLuaAI.waitingUntil = "cancel", now, now + 15
    Answer("|cffff7777" .. T("(отменено)", "(cancelled)") .. "|r", "")
    status:SetText(T("Отменяю запрос...", "Cancelling the request..."))
    UpdateContext()
end
AccLuaAI.CancelRequest = CancelRequest

-- Queued messages are dropped (AI disabled): their entries say "cancelled".
function DropQueue()
    for _, q in ipairs(AccLuaAI.queue) do
        local chat = Chat(q.mode)
        local cancelled = "|cffff7777" .. T("(отменено)", "(cancelled)") .. "|r"
        if q.game then PeerState(q.sender).pending = nil end
        if q.idx and chat.history[q.idx] then
            chat.history[q.idx] = q.game and (GameHead(q) .. " " .. cancelled) or (YouLine(q.text) .. AI_LINE .. cancelled)
        end
    end
    AccLuaAI.queue = {}
    RenderHistory(false)
end

sendBtn:SetScript("OnClick", Submit)
cancelBtn:SetScript("OnClick", AccLuaAI.CancelRequest)
input:SetScript("OnEnterPressed", Submit)
input:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
-- Not every client build has both handlers on an EditBox: a missing one must not break the file.
-- (An EditBox takes keys only while it has focus; EnableKeyboard just makes sure OnKeyDown is delivered.)
pcall(input.EnableKeyboard, input, true)
pcall(input.SetScript, input, "OnKeyDown", function(_, key) ArrowKey(key) end)
pcall(input.SetScript, input, "OnArrowPressed", function(_, key) ArrowKey(key) end)
recallBtn:SetScript("OnClick", function()
    Recall(-1)
    input:SetFocus()
end)
recallBtn:SetScript("OnEnter", function(self)
    self.bg:SetTexture(unpack(HOVER))
    if type(GameTooltip) ~= "table" then return end
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine(T("Предыдущий вопрос", "Previous question"), 0.4, 0.8, 1)
    GameTooltip:AddLine(T("Вернуть отправленный вопрос в поле ввода, чтобы исправить и отправить снова. В поле ввода: стрелки вверх/вниз.",
        "Put a sent question back into the input to edit and resend it. In the input: Up/Down arrows."), 1, 1, 1, true)
    GameTooltip:Show()
end)
recallBtn:SetScript("OnLeave", function(self)
    self.bg:SetTexture(unpack(ACCENT))
    if type(GameTooltip) == "table" then GameTooltip:Hide() end
end)
-- v18: three visible tabs instead of one cycling button (CHAT was easy to miss).
local function SetMode(m)
    if ModeOf(m) == ModeOf(AccLuaAI.mode) then return end
    AccLuaAI.mode = ModeOf(m)
    UpdateMode()
    RenderHistory(true) -- show the other chat
end
modeBtn:SetScript("OnClick", function() SetMode("talk") end)
actBtn:SetScript("OnClick", function() SetMode("actions") end)
chatBtn:SetScript("OnClick", function() SetMode("chat") end)
runBtn:SetScript("OnClick", function() StartConfirmedPlan() UpdateContext() end)
stopBtn:SetScript("OnClick", function() ForceStop(T("Действие остановлено", "Action stopped")) UpdateContext() end)
sayBtn:SetScript("OnClick", function()
    local draft = AccLuaAI.chat.draft
    AccLuaAI.chat.draft = nil
    if draft and draft.text and draft.text ~= "" then
        SendChatMessage(draft.text, draft.channel or "SAY", nil, draft.target)
        AddHistory("actions", "|cff8fb8e8Said:|r " .. Shown(draft.text), draft.text) -- drafts come from ACTIONS plans
        status:SetText(T("Отправлено в чат", "Chat draft sent"))
    end
    UpdateContext()
end)

-- Clear: only the chat on screen, and only its context on the host.
clearBtn:SetScript("OnClick", function()
    local mode = ModeOf(AccLuaAI.mode)
    local chat = Chat(mode)
    chat.history, chat.plain, chat.top = {}, {}, 0
    if AccLuaAI.pendingMode == mode then AccLuaAI.pendingIdx = nil end
    for _, q in ipairs(AccLuaAI.queue) do
        if q.mode == mode then q.idx = nil end -- still sent; gets a new entry then
    end
    RenderHistory(false)
    -- CHAT has no host dialogue of its own ([AI:CHAT] is one-shot): only the screen is cleared.
    if mode == "actions" then Sys("[AI:RESET=actions]") elseif mode == "talk" then Sys("[AI:RESET]") end
end)

-- Copy window: the last answer (for code), "All" shows the whole history.
end
local copyFrame
do -- v17: scope block (Lua 5.1 200-local limit)
copyFrame = CreateFrame("Frame", nil, UIParent)
AccLuaAI.copyFrame = copyFrame
copyFrame:SetWidth(620)
copyFrame:SetHeight(380)
copyFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
copyFrame:SetFrameStrata("DIALOG")
copyFrame:EnableMouse(true)
-- v18: draggable by its top strip (the frame used to be stuck under the AI window).
copyFrame:SetMovable(true)
copyFrame:SetClampedToScreen(true)
Backdrop(copyFrame, 0.08, 0.09, 0.11, 0.98)
copyFrame:Hide()
local copyDrag = CreateFrame("Frame", nil, copyFrame)
copyDrag:SetPoint("TOPLEFT", copyFrame, "TOPLEFT", 0, 0)
copyDrag:SetPoint("TOPRIGHT", copyFrame, "TOPRIGHT", 0, 0)
copyDrag:SetHeight(30)
copyDrag:EnableMouse(true)
copyDrag:SetScript("OnMouseDown", function() copyFrame:StartMoving() end)
copyDrag:SetScript("OnMouseUp", function() copyFrame:StopMovingOrSizing() end)
local copyHint = copyDrag:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
copyHint:SetPoint("TOPLEFT", copyFrame, "TOPLEFT", 10, -11)
copyHint:SetText(T("Текст выделен: Ctrl+C - скопировать. Тянуть за шапку.", "Text selected: Ctrl+C to copy. Drag the top strip."))
local copyClose = Button(copyFrame, 20, "X")
copyClose:SetPoint("TOPRIGHT", copyFrame, "TOPRIGHT", -7, -7)
local copyAll = Button(copyFrame, 44, T("Всё", "All"))
copyAll:SetPoint("RIGHT", copyClose, "LEFT", -4, 0)
local copySel = Button(copyFrame, 72, T("Выделить", "Select all"))
copySel:SetPoint("RIGHT", copyAll, "LEFT", -4, 0)
for _, b in ipairs({ copyClose, copyAll, copySel }) do b:SetFrameLevel((copyFrame:GetFrameLevel() or 1) + 5) end
local copyScroll, copyBar = MakeScroll(copyFrame)
copyScroll:SetPoint("TOPLEFT", copyFrame, "TOPLEFT", 8, -32)
copyScroll:SetPoint("BOTTOMRIGHT", copyFrame, "BOTTOMRIGHT", -28, 8)
local copyEdit = CreateFrame("EditBox", nil, copyScroll)
copyEdit:SetMultiLine(true)
copyEdit:SetAutoFocus(false)
copyEdit:SetFontObject("GameFontHighlight")
Font(copyEdit, 13)
copyEdit:SetWidth(576)
copyEdit:SetHeight(2000)
copyScroll:SetScrollChild(copyEdit)
local function CloseCopy() copyEdit:ClearFocus() copyFrame:Hide() end
local function SelectCopy()
    copyEdit:SetFocus()
    copyEdit:HighlightText()
end
-- v18: with the DLL clipboard bridge (AccLuaClipboard) the text lands in the clipboard at once;
-- the window is the fallback when the bridge is missing or fails.
OpenCopy = function(text)
    text = tostring(text or "")
    -- v21: the window always opens (visible feedback); the bridge additionally fills the clipboard.
    local copied = false
    if type(AccLuaClipboard) == "function" then
        local okC, done = pcall(AccLuaClipboard, text)
        copied = okC and done and true or false
    end
    copyHint:SetText(copied and T("Уже в буфере обмена: Ctrl+V. Тянуть за шапку.", "Already in the clipboard: Ctrl+V. Drag the top strip.")
        or T("Текст выделен: Ctrl+C - скопировать. Тянуть за шапку.", "Text selected: Ctrl+C to copy. Drag the top strip."))
    if copied then SysStatus("|cff66ff88" .. T("Скопировано в буфер обмена (Ctrl+V)", "Copied to the clipboard (Ctrl+V)") .. "|r") end
    copyEdit:SetText(text)
    copyFrame:Show()
    SelectCopy()
    copyScroll:UpdateScrollChildRect()
    SyncBar(copyScroll, copyBar, false)
    copyScroll:SetVerticalScroll(0)
    copyBar:SetValue(0)
    return copied
end
copyClose:SetScript("OnClick", CloseCopy)
copySel:SetScript("OnClick", SelectCopy)
copyEdit:SetScript("OnEscapePressed", CloseCopy)
copyAll:SetScript("OnClick", function()
    local chat, all = Chat(AccLuaAI.mode), {}
    for i = 1, #chat.history do
        local p = chat.plain[i]
        all[#all + 1] = (p and p ~= "") and p or chat.history[i]
    end
    OpenCopy(table.concat(all, "\n\n"))
end)
copyBtn:SetScript("OnClick", function()
    local chat = Chat(AccLuaAI.mode)
    for i = #chat.plain, 1, -1 do
        if chat.plain[i] and chat.plain[i] ~= "" then return OpenCopy(chat.plain[i]) end
    end
    OpenCopy(table.concat(chat.history, "\n\n"))
end)

-- ===== Constructor: working script (AiRuntime/scripts/working.lua via host) =====
end
local HexEncode, HexDecode
do -- v17: scope block (Lua 5.1 200-local limit)
function HexEncode(s)
    s = tostring(s or "")
    local out = {}
    for i = 1, #s do out[i] = string.format("%02X", string.byte(s, i)) end
    return table.concat(out)
end
function HexDecode(hex)
    hex = tostring(hex or "")
    if (#hex % 2) ~= 0 then return nil end
    local out = {}
    for i = 1, #hex, 2 do
        local b = tonumber(hex:sub(i, i + 1), 16)
        if not b then return nil end
        out[#out + 1] = string.char(b)
    end
    return table.concat(out)
end

-- Collect ``` / ```lua fences from chat (document order across all plain entries).
-- Apply default = last block. selectedLua indexes into this list.
CollectLuaBlocks = function()
    local chat = Chat(AccLuaAI.mode)
    local blocks = {}
    local function AddFrom(blob)
        blob = tostring(blob or ""):gsub("||", "|")
        for lang, body in blob:gmatch("```([%w]*)%s*[\r\n](.-)```") do
            lang = string.lower(lang or "")
            if lang == "" or lang == "lua" or lang == "macro" then
                body = Trim(body)
                if body ~= "" then blocks[#blocks + 1] = body end
            end
        end
    end
    for i = 1, #chat.plain do
        local p = chat.plain[i]
        if p and p ~= "" then AddFrom(p) end
    end
    if #blocks == 0 then AddFrom(table.concat(chat.history, "\n\n")) end
    if #blocks == 0 then
        for i = #chat.plain, 1, -1 do
            local p = Trim(chat.plain[i] or "")
            if p ~= "" and (p:find("CreateFrame", 1, true) or p:find("function", 1, true)
                    or p:find(TQ, 1, true) or p:find("CastSpell", 1, true)) then
                blocks[1] = p
                break
            end
        end
    end
    return blocks
end

end
local ExtractApplyLua, CanReloadOrApply, SaveWorkingScript, Utf8Cut, RunApply
do -- v17: scope block (Lua 5.1 200-local limit)
function ExtractApplyLua()
    local blocks = CollectLuaBlocks()
    if #blocks == 0 then return nil, 0, 0 end
    local sel = AccLuaAI.selectedLua
    if type(sel) == "number" and sel >= 1 and sel <= #blocks then
        return blocks[sel], sel, #blocks
    end
    return blocks[#blocks], #blocks, #blocks
end

PreviewBlock = function(code)
    code = tostring(code or ""):gsub("%s+", " ")
    if #code > 72 then code = code:sub(1, 72) .. "..." end
    return code
end

local function CycleSelectedLua()
    local blocks = CollectLuaBlocks()
    if #blocks == 0 then
        AccLuaAI.selectedLua = nil
        SysStatus("|cffff7777" .. T("Нет блока lua в истории", "No lua block in history") .. "|r")
        return
    end
    local cur = AccLuaAI.selectedLua
    if type(cur) ~= "number" or cur < 1 or cur > #blocks then cur = #blocks end
    cur = cur % #blocks + 1
    AccLuaAI.selectedLua = cur
    SysStatus(string.format("|cff66ccff%s %d/%d:|r %s",
        T("Выбран блок", "Selected block"), cur, #blocks, Shown(PreviewBlock(blocks[cur]))))
    RenderHistory(false)
end

function CanReloadOrApply()
    if type(UnitExists) ~= "function" or not UnitExists("player") then return false end
    return true
end

-- Frames created during Apply (constructor). Unload is best-effort; arbitrary loadstring
-- side effects (hooks, globals, Secure*) need ReloadUI.
-- applies[]: each Apply is an instance { id, blockIdx, frames, preview } — unload by id, not by code text.
AccLuaAI.applies = AccLuaAI.applies or {}
AccLuaAI.applySeq = AccLuaAI.applySeq or 0
AccLuaAI.workingSeq = AccLuaAI.workingSeq or 0
-- Legacy flat list kept in sync for older call sites.
AccLuaAI.appliedFrames = AccLuaAI.appliedFrames or {}

local function NeutralizeFrame(f)
    if type(f) ~= "table" then return end
    pcall(function() if f.Hide then f:Hide() end end)
    pcall(function() if f.UnregisterAllEvents then f:UnregisterAllEvents() end end)
    -- One pcall per script: a plain Frame has no OnClick, which must not skip the rest.
    for _, s in ipairs({ "OnUpdate", "OnEvent", "OnShow", "OnHide", "OnClick", "OnEnter", "OnLeave",
            "OnMouseDown", "OnMouseUp" }) do
        pcall(function() if f.SetScript then f:SetScript(s, nil) end end)
    end
    pcall(function() if f.EnableMouse then f:EnableMouse(false) end end)
end

local function RebuildAppliedFlat()
    local flat = {}
    for _, ap in ipairs(AccLuaAI.applies or {}) do
        for _, f in ipairs(ap.frames or {}) do flat[#flat + 1] = f end
    end
    AccLuaAI.appliedFrames = flat
end

-- v23: handlers set on applied frames run under pcall; the first error detaches that handler and
-- reports it (an OnUpdate error would otherwise fire every frame).
local function GuardScripts(f, applyRec)
    if type(f) ~= "table" or f._aiGuarded then return f end
    local rawSet = f.SetScript
    if type(rawSet) ~= "function" then return f end
    f._aiGuarded = true
    f.SetScript = function(self, ev, fn)
        if type(fn) ~= "function" then return rawSet(self, ev, fn) end
        local wrapped
        wrapped = function(...)
            local ok, err = pcall(fn, ...)
            if not ok then
                pcall(rawSet, self, ev, nil)
                local msg = tostring(err)
                AccLuaAI.lastError = { code = applyRec and applyRec.code or "", err = msg, blockIdx = applyRec and applyRec.blockIdx }
                if type(AddHistory) == "function" then
                    AddHistory("talk", "|cffff7777" .. T("Ошибка в ", "Error in ") .. tostring(ev) ..
                        T(" применённого кода (обработчик отключён): ", " of applied code (handler detached): ") ..
                        Shown(msg) .. "|r", "")
                end
                if type(UpdateFixBtn) == "function" then UpdateFixBtn() end
            end
        end
        return rawSet(self, ev, wrapped)
    end
    return f
end
local function TrackAppliedFrame(f)
    if type(f) ~= "table" then return f end
    local cur = AccLuaAI._applyCurrent
    if type(cur) == "table" then
        cur.frames[#cur.frames + 1] = f
    else
        AccLuaAI.appliedFrames[#AccLuaAI.appliedFrames + 1] = f
    end
    return f
end

local function UnloadApplyInstance(ap)
    if type(ap) ~= "table" then return 0 end
    local n = 0
    for _, f in ipairs(ap.frames or {}) do
        NeutralizeFrame(f)
        n = n + 1
    end
    ap.frames = {}
    return n
end

local function RemoveApplyById(applyId)
    local list = AccLuaAI.applies or {}
    local removed, frames = 0, 0
    local i = 1
    while i <= #list do
        if list[i].id == applyId then
            frames = frames + UnloadApplyInstance(list[i])
            table.remove(list, i)
            removed = removed + 1
        else
            i = i + 1
        end
    end
    RebuildAppliedFlat()
    return removed, frames
end

-- Latest apply instance for this history block index (two Applies of same block = two ids).
local function UnloadBlockByIdx(blockIdx)
    blockIdx = tonumber(blockIdx)
    if not blockIdx then
        SysStatus("|cffff7777" .. T("Нет выбранного блока", "No selected block") .. "|r")
        return 0, 0
    end
    local list = AccLuaAI.applies or {}
    local bestI = nil
    for i = #list, 1, -1 do
        if list[i].blockIdx == blockIdx then bestI = i break end
    end
    if not bestI and #list > 0 then
        -- Selected block was never applied (e.g. a newer answer is selected): unload the latest Apply.
        bestI = #list
    end
    if not bestI then
        SysStatus(T("Нечего снимать: не было «Применить». ReloadUI — полный откат.",
            "Nothing to unload: nothing was applied. ReloadUI = full undo."))
        return 0, 0
    end
    local ap = list[bestI]
    local id, frames = ap.id, UnloadApplyInstance(ap)
    table.remove(list, bestI)
    RebuildAppliedFlat()
    SysStatus(string.format("|cff33dd66%s id=%d (%s %d): %d %s.|r %s",
        T("Снят Apply", "Unloaded Apply"), id, T("блок", "block"), ap.blockIdx or blockIdx, frames,
        T("фрейм(ов)", "frame(s)"),
        T("Глобалы/хуки — только ReloadUI.", "Globals/hooks need ReloadUI.")))
    return 1, frames
end
AccLuaAI.UnloadBlockByIdx = UnloadBlockByIdx

local function UnloadApplied()
    local list = AccLuaAI.applies or {}
    local frames = 0
    for i = 1, #list do frames = frames + UnloadApplyInstance(list[i]) end
    -- Also neutralize any legacy flat leftovers.
    for _, f in ipairs(AccLuaAI.appliedFrames or {}) do NeutralizeFrame(f) end
    local nInst = #list
    AccLuaAI.applies = {}
    AccLuaAI.appliedFrames = {}
    AccLuaAI.workingCache = nil
    return frames, nInst
end

-- v24: a "code" block that is really a macro (every non-comment line starts with /) runs line by line
-- through Tesq1('RunMacroText("...")').
local function MacroToLua(code)
    local lines, n = {}, 0
    for line in (code .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        local t = Trim(line)
        if t ~= "" and not t:find("^%-%-") then
            if t:sub(1, 1) ~= "/" then return nil end
            n = n + 1
            lines[n] = string.format("%s1(%q)", TQ, string.format("RunMacroText(%q)", t))
        end
    end
    if n == 0 then return nil end
    return table.concat(lines, "\n")
end
local function ExecuteConstructorLua(code, applyRec)
    code = Trim(code)
    if code == "" then return false, "empty" end
    code = MacroToLua(code) or code
    if type(loadstring) ~= "function" then
        if type(Tesq1) == "function" then
            local ok, err = pcall(Tesq1, code)
            return ok, err
        end
        return false, "no loadstring/Tesq1"
    end
    local chunkName = "AccLuaAI_working"
    if type(applyRec) == "table" and applyRec.id then
        chunkName = "AccLuaAI_apply_" .. tostring(applyRec.id)
    end
    local fn, err = loadstring(code, chunkName)
    if not fn then return false, err end
    local realCreateFrame = CreateFrame
    AccLuaAI._applyCurrent = applyRec
    -- v18: the DLL text-replaces every "Tesq*" in this file with its random names (the values below
    -- become the random globals = correct), so the KEYS are spelled without the literal prefix:
    -- model code calls Tesq1(...) by its public name and must find it in this env.
    local env = setmetatable({
        [TQ .. ""] = Tesq or Tesq1,
        [TQ .. "1"] = Tesq1,
        [TQ .. "Cast"] = TesqCast,
        [TQ .. "UnitFacing"] = TesqUnitFacing,
        [TQ .. "LoS"] = TesqLoS,
        [TQ .. "Silenced"] = TesqSilenced,
        [TQ .. "Disarmed"] = TesqDisarmed,
        [TQ .. "Controlled"] = TesqControlled,
        -- v23: the rest of the public API (values are renamed by the DLL, keys stay public).
        [TQ .. "AddPacketOpcodeFilter"] = TesqAddPacketOpcodeFilter,
        [TQ .. "Block"] = TesqBlock,
        [TQ .. "ClearPacketFilters"] = TesqClearPacketFilters,
        [TQ .. "ConsoleClose"] = TesqConsoleClose,
        [TQ .. "ConsoleIsOpen"] = TesqConsoleIsOpen,
        [TQ .. "ConsoleOpen"] = TesqConsoleOpen,
        [TQ .. "ConsoleToggle"] = TesqConsoleToggle,
        [TQ .. "CursorPos"] = TesqCursorPos,
        [TQ .. "Fast"] = TesqFast,
        [TQ .. "FastSend"] = TesqFastSend,
        [TQ .. "GetOpcodeByName"] = TesqGetOpcodeByName,
        [TQ .. "GetOpcodeName"] = TesqGetOpcodeName,
        [TQ .. "Gps"] = TesqGps,
        [TQ .. "GpsX"] = TesqGpsX,
        [TQ .. "GpsY"] = TesqGpsY,
        [TQ .. "GpsZ"] = TesqGpsZ,
        [TQ .. "GroundZ"] = TesqGroundZ,
        [TQ .. "HttpGet"] = TesqHttpGet,
        [TQ .. "HttpPoll"] = TesqHttpPoll,
        [TQ .. "HttpPost"] = TesqHttpPost,
        [TQ .. "HttpPostAsync"] = TesqHttpPostAsync,
        [TQ .. "InjectRecv"] = TesqInjectRecv,
        [TQ .. "IsPacketSniffEnabled"] = TesqIsPacketSniffEnabled,
        [TQ .. "LogToFile"] = TesqLogToFile,
        [TQ .. "MapId"] = TesqMapId,
        [TQ .. "MapToWorld"] = TesqMapToWorld,
        [TQ .. "Recv"] = TesqRecv,
        [TQ .. "RegisterPacketCallback"] = TesqRegisterPacketCallback,
        [TQ .. "RemovePacketOpcodeFilter"] = TesqRemovePacketOpcodeFilter,
        [TQ .. "Replace"] = TesqReplace,
        [TQ .. "ReplaceClear"] = TesqReplaceClear,
        [TQ .. "ReplaceEx"] = TesqReplaceEx,
        [TQ .. "Send"] = TesqSend,
        [TQ .. "SendMulti"] = TesqSendMulti,
        [TQ .. "SendTo"] = TesqSendTo,
        [TQ .. "SetFilter"] = TesqSetFilter,
        [TQ .. "SetLog"] = TesqSetLog,
        [TQ .. "SetPacketFilterMode"] = TesqSetPacketFilterMode,
        [TQ .. "SetThrottle"] = TesqSetThrottle,
        [TQ .. "Throttle"] = TesqThrottle,
        [TQ .. "Tp"] = TesqTp,
        [TQ .. "TpLoadGitHub"] = TesqTpLoadGitHub,
        [TQ .. "TpLoadMy"] = TesqTpLoadMy,
        [TQ .. "TpSafe"] = TesqTpSafe,
        [TQ .. "TpSave"] = TesqTpSave,
        [TQ .. "Unblock"] = TesqUnblock,
        [TQ .. "UnregisterPacketCallback"] = TesqUnregisterPacketCallback,
        -- Safety net: a bare protected cast that slipped into the model's code still goes
        -- through the unlocker (Tesq1) instead of failing as a protected call.
        CastSpellByName = type(Tesq1) == "function" and function(spell, unit)
            return Tesq1(string.format("CastSpellByName(%q,%q)", tostring(spell or ""), tostring(unit or "target")))
        end or nil,
        UseAction = type(Tesq1) == "function" and function(slot)
            return Tesq1("UseAction(" .. (tonumber(slot) or 0) .. ")")
        end or nil,
        RunMacroText = type(Tesq1) == "function" and function(text)
            return Tesq1(string.format("RunMacroText(%q)", tostring(text or "")))
        end or nil,
        TargetUnit = type(Tesq1) == "function" and function(unit)
            return Tesq1(string.format("TargetUnit(%q)", tostring(unit or "target")))
        end or nil,
        CreateFrame = function(ftype, name, parent, template)
            AccLuaAI.workingSeq = (AccLuaAI.workingSeq or 0) + 1
            if type(name) ~= "string" or name == "" then
                local id = applyRec and applyRec.id or AccLuaAI.workingSeq
                name = "AccLuaAI_Working" .. tostring(id) .. "_" .. tostring(AccLuaAI.workingSeq)
            end
            local f = realCreateFrame(ftype, name, parent, template)
            return GuardScripts(TrackAppliedFrame(f), applyRec)
        end,
    }, { __index = _G })
    setfenv(fn, env)
    local ok, runErr = pcall(fn)
    AccLuaAI._applyCurrent = nil
    return ok, runErr
end

function SaveWorkingScript(code)
    code = Trim(code)
    if code == "" then return false end
    if #code > 2800 then
        SysStatus("|cffff7777" .. T("Скрипт слишком большой (макс 2800 байт)", "Script too large (max 2800 bytes)") .. "|r")
        return false
    end
    local hex = HexEncode(code)
    -- DLL BeginLocalAiRequest rejects payloads > 7000 ([AI:SCRIPT_SAVE=] + hex).
    if (#hex + 20) > 7000 then
        SysStatus("|cffff7777" .. T("Скрипт слишком большой для IPC", "Script too large for IPC") .. "|r")
        return false
    end
    AccLuaAI.workingCache = code
    -- Front of queue: Apply must not lose to MODELS/DLSTATUS polls.
    table.insert(sysQueue, 1, "[AI:SCRIPT_SAVE=" .. hex .. "]")
    SysStatus(T("Сохраняю working.lua...", "Saving working.lua..."))
    return true
end

-- UTF-8-safe prefix of at most maxBytes bytes (never ends inside a multi-byte character).
function Utf8Cut(s, maxBytes)
    s = tostring(s or "")
    if #s <= maxBytes then return s end
    local cut = maxBytes
    while cut > 0 do
        local c = s:byte(cut + 1)
        if not c or c < 0x80 or c >= 0xC0 then break end
        cut = cut - 1
    end
    return s:sub(1, cut)
end

local function BlockLabel(blockIdx)
    if blockIdx == "file" then return T("файла working.lua", "working.lua") end
    return T("блока ", "block ") .. tostring(blockIdx)
end

-- (forward decl hoisted) local RunApply
do
-- Re-applying a block replaces it: every earlier Apply record of the same blockIdx is unloaded first.
local function ReplaceApplies(blockIdx)
    local list = AccLuaAI.applies or {}
    local n, i = 0, 1
    while i <= #list do
        if list[i].blockIdx == blockIdx then
            UnloadApplyInstance(list[i])
            table.remove(list, i)
            n = n + 1
        else
            i = i + 1
        end
    end
    if n > 0 then RebuildAppliedFlat() end
    return n
end

-- A failed Apply/Run stays visible: a red TALK entry (the status line changes later) + "Исправить с AI".
local function ApplyFailed(code, err, blockIdx)
    err = tostring(err or "?")
    AccLuaAI.lastError = { code = code, err = err, blockIdx = blockIdx }
    AddHistory("talk", "|cffff5555" .. T("Ошибка при запуске ", "Run error in ") .. BlockLabel(blockIdx) .. ": " ..
        NoFence(Shown(err)) .. "|r", "")
    SysStatus("|cffff7777" .. T("Ошибка: ", "Error: ") .. Shown(err) .. "|r")
    UpdateFixBtn()
end

-- Apply one code text as block blockIdx (a number, or "file" for Run file).
RunApply = function(code, blockIdx, total, save)
    local replaced = ReplaceApplies(blockIdx)
    AccLuaAI.applySeq = (AccLuaAI.applySeq or 0) + 1
    local applyRec = {
        id = AccLuaAI.applySeq,
        blockIdx = blockIdx,
        frames = {},
        preview = PreviewBlock(code),
        code = code, -- v23: "Исправить с AI" after a runtime (OnUpdate) error needs the source
    }
    AccLuaAI.applies = AccLuaAI.applies or {}
    AccLuaAI.applies[#AccLuaAI.applies + 1] = applyRec
    if save then SaveWorkingScript(code) end
    local ok, err = ExecuteConstructorLua(code, applyRec)
    RebuildAppliedFlat()
    if ok then
        AccLuaAI.lastError = nil
        UpdateFixBtn()
        local tail = save and " + working.lua" or ""
        if replaced > 0 then
            SysStatus(string.format("|cff33dd66%s (%s): id=%d, %d fr%s|r", T("Заменено", "Replaced"),
                blockIdx == "file" and T("файл", "file") or (T("блок ", "block ") .. tostring(blockIdx)),
                applyRec.id, #(applyRec.frames or {}), tail))
        elseif blockIdx == "file" then
            SysStatus(string.format("|cff33dd66%s (working.lua, id=%d, %d fr)|r",
                T("Запущено", "Started"), applyRec.id, #(applyRec.frames or {})))
        else
            SysStatus(string.format("|cff33dd66%s (%s/%s, id=%d, %d fr)%s|r",
                T("Применено", "Applied"), tostring(blockIdx), tostring(total or "?"), applyRec.id,
                #(applyRec.frames or {}), tail))
        end
    else
        RemoveApplyById(applyRec.id)
        ApplyFailed(code, err, blockIdx)
    end
    return ok, err
end
end

reloadBtn:SetScript("OnClick", function()
    if not CanReloadOrApply() then
        SysStatus("|cffff7777" .. T("ReloadUI только в мире (не Glue)", "ReloadUI only in-world (not Glue)") .. "|r")
        return
    end
    if type(ReloadUI) ~= "function" then
        SysStatus("|cffff7777ReloadUI nil|r")
        return
    end
    SysStatus(T("ReloadUI...", "ReloadUI..."))
    ReloadUI()
end)

applyBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
applyBtn:SetScript("OnClick", function(_, button)
    if button == "RightButton" then
        CycleSelectedLua()
        return
    end
    if not CanReloadOrApply() then
        SysStatus("|cffff7777" .. T("Применить только в мире", "Apply only in-world") .. "|r")
        return
    end
    local code, idx, total = ExtractApplyLua()
    if not code then
        SysStatus("|cffff7777" .. T("Нет блока lua в ответе", "No lua block in the reply") .. "|r")
        return
    end
    RunApply(code, idx, total, true)
end)

-- "Исправить с AI": the failed code + error as a TALK question (as if typed; code cut to 2200 bytes).
fixBtn:SetScript("OnClick", function()
    local le = AccLuaAI.lastError
    if not le then UpdateFixBtn() return end
    if AccLuaAI.mode ~= "talk" then
        AccLuaAI.mode = "talk"
        UpdateMode()
        RenderHistory(true)
    end
    local request = "Исправь ошибку при запуске (Lua 5.1, WoW 3.3.5, AccLua). Ошибка: " .. tostring(le.err) ..
        "\n```lua\n" .. Utf8Cut(le.code, 2200) .. "\n```\nВерни исправленный полный код одним блоком ```lua```."
    if SubmitText(request, "talk", true) then
        SysStatus(T("Отправлено ИИ: исправить ", "Sent to the AI: fix ") .. BlockLabel(le.blockIdx))
    end
end)
Tip(fixBtn, T("Исправить с AI", "Fix with AI"),
    T("Отправить ИИ (TALK) текст ошибки и код, который не запустился. Исправленный блок появится в TALK - выберите его и нажмите «Применить».",
        "Send the error and the failed code to the AI (TALK). Apply the fixed block from TALK when it arrives."))

unloadBlockBtn:SetScript("OnClick", function()
    local _, idx = ExtractApplyLua()
    if not idx or idx < 1 then
        SysStatus("|cffff7777" .. T("Нет выбранного блока", "No selected block") .. "|r")
        return
    end
    UnloadBlockByIdx(idx)
end)

unloadBtn:SetScript("OnClick", function()
    local frames, nInst = UnloadApplied()
    if frames > 0 or (nInst and nInst > 0) then
        SysStatus(string.format("|cff33dd66%s: %d %s / %d Apply.|r %s",
            T("Снято всё", "Unloaded all"), frames, T("фрейм(ов)", "frame(s)"), nInst or 0,
            T("Глобалы/хуки — только ReloadUI.", "Globals/hooks need ReloadUI.")))
    else
        SysStatus(T("Нечего снимать (нет отслеженных Apply). ReloadUI снимает всё.",
            "Nothing to unload (no tracked Applies). ReloadUI clears everything."))
    end
end)

end
do -- v17: scope block (Lua 5.1 200-local limit)
local fileMenu = CreateFrame("Frame", nil, frame)
fileMenu:SetWidth(160)
fileMenu:SetHeight(118) -- 4 rows
fileMenu:SetPoint("TOPRIGHT", fileBtn, "BOTTOMRIGHT", 0, -2)
-- Parent is FULLSCREEN_DIALOG: DIALOG strata draws *under* it → ghost text on black.
fileMenu:SetFrameStrata("FULLSCREEN_DIALOG")
fileMenu:SetFrameLevel((frame:GetFrameLevel() or 50) + 20)
fileMenu.rows = {}
fileMenu:SetScript("OnShow", function(self)
    local lvl = self:GetFrameLevel() or 70
    for _, r in ipairs(self.rows) do r:SetFrameLevel(lvl + 2) r:Show() end
end)
Backdrop(fileMenu, 0.12, 0.13, 0.16, 0.98)
fileMenu:Hide()
local function FileRow(y, label, onClick)
    local b = Button(fileMenu, 148, label)
    b:SetPoint("TOPLEFT", fileMenu, "TOPLEFT", 6, y)
    b:SetFrameLevel((fileMenu:GetFrameLevel() or 70) + 2)
    fileMenu.rows[#fileMenu.rows + 1] = b
    if b.text and b.text.SetTextColor then b.text:SetTextColor(1, 1, 1) end
    b:SetScript("OnClick", function()
        fileMenu:Hide()
        onClick()
    end)
    return b
end
FileRow(-8, T("Сохранить", "Save"), function()
    local code = ExtractApplyLua()
    if not code then
        SysStatus("|cffff7777" .. T("Нечего сохранять", "Nothing to save") .. "|r")
        return
    end
    if SaveWorkingScript(code) then
        SysStatus(T("Сохраняю working.lua...", "Saving working.lua..."))
    end
end)
FileRow(-34, T("Открыть", "Open"), function()
    Sys("[AI:SCRIPT_OPEN]")
    SysStatus(T("Открываю working.lua...", "Opening working.lua..."))
end)
FileRow(-60, T("В AI / показать", "To AI / show"), function()
    AccLuaAI.runFileNext = nil
    if AccLuaAI.workingCache and AccLuaAI.workingCache ~= "" then
        OpenCopy("-- AccLua AI working.lua (cache)\n\n" .. AccLuaAI.workingCache)
    end
    Sys("[AI:SCRIPT_GET]")
    SysStatus(T("Загружаю working.lua...", "Loading working.lua..."))
end)
-- Run the whole working.lua: the [SCRIPT]hex: reply is executed (Apply record blockIdx "file").
FileRow(-86, T("Запустить файл", "Run file"), function()
    AccLuaAI.runFileNext = true
    Sys("[AI:SCRIPT_GET]")
    SysStatus(T("Загружаю working.lua для запуска...", "Loading working.lua to run it..."))
end)
fileBtn:SetScript("OnClick", function()
    if fileMenu:IsShown() then fileMenu:Hide() else fileMenu:Show() end
end)
local _prevOnHide = frame:GetScript("OnHide")
frame:SetScript("OnHide", function(self)
    fileMenu:Hide()
    if _prevOnHide then _prevOnHide(self) end
end)

-- Click a tinted ```lua``` region to select it for Apply (see SyncCodeHits). RMB on Apply still cycles.
output:EnableMouse(true)

-- Model menu: filled from [MODELS]; installed -> switch, missing -> download (progress in the status line).
end
-- Each row: name, size, one-line description, hardware verdict; hover = full tooltip.
local menu, GB, MODEL_INFO, FIT, FitText, DisarmDelete, ShowModels, Clock, dlErrors, delErrors, ModelName
do -- v17: scope block (Lua 5.1 200-local limit)
menu = CreateFrame("Frame", nil, frame)
AccLuaAI.menu = menu
menu:SetPoint("TOPLEFT", modelBtn, "BOTTOMLEFT", 0, -2)
menu:SetWidth(460)
menu:SetFrameStrata("FULLSCREEN_DIALOG")
menu:SetFrameLevel((frame:GetFrameLevel() or 50) + 20)
Backdrop(menu, 0.10, 0.11, 0.13, 0.98)
menu:Hide()
menu.rows = {}
menu.head = menu:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
menu.head:SetPoint("TOPLEFT", menu, "TOPLEFT", 8, -7)
menu.head:SetWidth(444)
menu.head:SetJustifyH("LEFT")
menu.head:SetTextColor(0.65, 0.72, 0.84)
Font(menu.head, 11)
menu.hw = menu:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
menu.hw:SetPoint("TOPLEFT", menu.head, "BOTTOMLEFT", 0, -3)
menu.hw:SetWidth(444)
menu.hw:SetJustifyH("LEFT")
menu.hw:SetTextColor(0.65, 0.72, 0.84)
Font(menu.hw, 11)
local ROW_H, ROW_STEP = 36, 39
function GB(bytes) return string.format("%.1f %s", (tonumber(bytes) or 0) / 1073741824, T("ГБ", "GB")) end
local function MiB2GB(mib) return string.format("%.0f %s", (tonumber(mib) or 0) / 1024, T("ГБ", "GB")) end

-- What each model is good for (ids come from the host; unknown ids get a generic line).
MODEL_INFO = {
    ["qwen35-9b"] = {
        star = true,
        short = T("рекомендуем: лучший код и русский, думает перед ответом", "recommended: best code + Russian, thinks before answering"),
        long = T("Qwen3.5-9B (Alibaba, 2026). Лучшая модель для 8 ГБ видеопамяти: код (LiveCodeBench 65), 201 язык, режим размышления для кода и макросов. Целиком помещается в 8 ГБ. Ответ 2-6 с, код 15-40 с.",
            "Qwen3.5-9B (Alibaba, 2026). Best 8 GB-VRAM model: code (LiveCodeBench 65), 201 languages, thinking mode for code and macros. Fits fully in 8 GB. Reply 2-6 s, code 15-40 s."),
    },
    ["gemma4-12b"] = {
        short = T("умнее в рассуждениях, но тяжелее: 6.3 ГБ", "stronger reasoning, but heavier: 6.3 GB"),
        long = T("Gemma 4 12B (Google, 2026, QAT). Сильнее в рассуждениях и коде (LiveCodeBench 72), 140+ языков. 6.3 ГБ не помещаются целиком в 8 ГБ видеопамяти вместе с WoW: часть считает процессор, ответы в 2-4 раза медленнее. Для видеокарт 12+ ГБ - лучший выбор.",
            "Gemma 4 12B (Google, 2026, QAT). Stronger reasoning and code (LiveCodeBench 72), 140+ languages. 6.3 GB does not fully fit in 8 GB VRAM next to WoW: part runs on the CPU, replies 2-4x slower. Best choice for 12+ GB cards."),
    },
    ["qwen3-8b"] = {
        short = T("прошлое поколение (2025): быстрая, код и русский слабее", "previous generation (2025): fast, weaker code + Russian"),
        long = T("Qwen3-8B (Alibaba, 2025). Быстрая и надёжная, но код и русский заметно слабее Qwen3.5. Оставлена, если уже скачана.",
            "Qwen3-8B (Alibaba, 2025). Fast and reliable, but code and Russian are noticeably weaker than Qwen3.5. Kept if already downloaded."),
    },
}
FIT = {
    [1] = { T("потянет", "runs fine"), "|cff33dd66" },
    [2] = { T("потянет, но медленнее", "runs, but slower"), "|cffffcc00" },
    [3] = { T("не потянет: мало памяти", "will not run: not enough memory"), "|cffff5555" },
}
function FitText(fit)
    local f = FIT[fit]
    if not f then return "" end
    return f[2] .. f[1] .. "|r"
end

-- Delete: a red button on every installed row (the current model too: the host unloads it first).
-- The first click arms it for 3 s ("Точно?"), the second one sends [AI:DELETE=id].
local DEL_BG, DEL_HOVER, DEL_DOWN = { 0.62, 0.12, 0.12, 1 }, { 0.85, 0.20, 0.20, 1 }, { 0.45, 0.08, 0.08, 1 }
local DEL_LABEL, DEL_ARMED = T("Удалить", "Delete"), T("Точно? ещё раз", "Sure? again")
local DEL_W, DEL_ARMED_W = 64, 96
function DisarmDelete()
    local arm = AccLuaAI.delArm
    AccLuaAI.delArm = nil
    if arm and arm.btn then
        arm.btn.text:SetText(DEL_LABEL)
        arm.btn:SetWidth(DEL_W)
    end
end
local function DeleteTip(btn, m, current)
    if type(GameTooltip) ~= "table" then return end
    local arm = AccLuaAI.delArm
    GameTooltip:Hide()
    GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
    if arm and arm.id == m.id then
        GameTooltip:AddLine(T("Точно? нажмите ещё раз", "Sure? click again"), 1, 0.3, 0.3)
    end
    GameTooltip:AddLine(T("Удалить файл модели", "Delete the model file"), 1, 0.45, 0.45)
    GameTooltip:AddLine(m.name .. "  (" .. GB(m.size) .. T(" освободится на диске)", " freed on disk)"), 1, 1, 1)
    if m.id == current then
        GameTooltip:AddLine(T("Это текущая модель: ИИ остановит её перед удалением, потом выберите другую.",
            "This is the current model: the AI stops it before deleting; pick another one afterwards."), 1, 0.82, 0, true)
    end
    GameTooltip:AddLine(T("Второй щелчок в течение 3 с подтверждает удаление.", "A second click within 3 s confirms."), 0.6, 0.6, 0.6, true)
    GameTooltip:Show()
end

function ShowModels(list, current, hw)
    DisarmDelete()
    menu.head:SetText(T("Все модели: чат RU/EN, код и макросы 3.3.5, поиск в интернете", "All models: RU/EN chat, 3.3.5 code and macros, web search"))
    if hw and (hw.vram or 0) > 0 then
        local line = T("Ваш ПК: ", "Your PC: ") .. (hw.gpu ~= "" and hw.gpu or T("видеокарта", "GPU")) .. ", " ..
            MiB2GB(hw.vram) .. T(" видео, ", " VRAM, ") .. MiB2GB(hw.ram) .. T(" ОЗУ", " RAM")
        if hw.layers and hw.layers ~= "" then
            line = line .. T("; сейчас на видеокарте слоёв: ", "; layers on GPU now: ") .. hw.layers
        end
        menu.hw:SetText(line)
    elseif hw and (hw.ram or 0) > 0 then
        menu.hw:SetText(T("Ваш ПК: видеокарта не найдена, ", "Your PC: no GPU found, ") .. MiB2GB(hw.ram) .. T(" ОЗУ - ответы будут медленными", " RAM - replies will be slow"))
    else
        menu.hw:SetText("")
    end
    -- Rows start below the header lines (the hardware line can wrap with the bigger font).
    local top = 7 + (menu.head:GetStringHeight() or 12) + 3 + (menu.hw:GetStringHeight() or 12) + 6
    for i, m in ipairs(list) do
        local row = menu.rows[i]
        if not row then
            row = Button(menu, 444, "")
            row:SetHeight(ROW_H)
            row.text:ClearAllPoints()
            row.text:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -4)
            row.text:SetJustifyH("LEFT")
            Font(row.text, 12)
            row.sub = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.sub:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 6, 4)
            row.sub:SetWidth(430)
            row.sub:SetHeight(13)
            row.sub:SetJustifyH("LEFT")
            row.sub:SetTextColor(0.80, 0.86, 0.95)
            Font(row.sub, 11)
            -- Delete the model file (every installed model): red button at the right of the row.
            row.del = Button(row, DEL_W, DEL_LABEL)
            row.del:SetHeight(20)
            row.del:SetPoint("RIGHT", row, "RIGHT", -6, 0)
            row.del.bg:SetTexture(unpack(DEL_BG))
            row.del:SetScript("OnMouseDown", function(self) self.bg:SetTexture(unpack(DEL_DOWN)) end)
            row.del:SetScript("OnMouseUp", function(self) self.bg:SetTexture(unpack(DEL_HOVER)) end)
            menu.rows[i] = row
        end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", menu, "TOPLEFT", 8, -top - (i - 1) * ROW_STEP)
        local info = MODEL_INFO[m.id] or {
            short = T("локальная модель", "local model"),
            long = T("Модель из списка хоста.", "A model from the host list."),
        }
        local tag
        if m.id == current then tag = "|cff66ccff" .. T("текущая", "current") .. "|r"
        elseif m.state == 1 then tag = T("выбрать", "select")
        elseif m.state == 2 then
            -- v23: live progress inside the row (the status line is hidden under the open menu)
            tag = "|cffffd200" .. (AccLuaAI.dlId == m.id and AccLuaAI.dlLine or T("скачивается...", "downloading...")) .. "|r"
        else tag = T("скачать", "download") end
        row.text:SetText((info.star and "|cffffd200*|r " or "") .. m.name .. "  " .. GB(m.size) .. "  - " .. tag)
        local fit = FitText(m.fit)
        row.sub:SetText(info.short .. (fit ~= "" and ("  -  " .. fit) or ""))
        row:SetScript("OnClick", function()
            menu:Hide()
            if type(GameTooltip) == "table" then GameTooltip:Hide() end
            if m.id == current then return end
            if m.state == 1 then
                Sys("[AI:MODEL=" .. m.id .. "]")
                SysStatus(T("Переключаю на ", "Switching to ") .. m.name .. "...")
            else
                Sys("[AI:DOWNLOAD=" .. m.id .. "]")
                SysStatus(T("Запускаю скачивание ", "Starting download of ") .. m.name .. " (" .. GB(m.size) .. ")...")
            end
        end)
        row:SetScript("OnEnter", function(self)
            self.bg:SetTexture(unpack(HOVER))
            if type(GameTooltip) ~= "table" then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(m.name .. "  (" .. GB(m.size) .. ")", 0.4, 0.8, 1)
            GameTooltip:AddLine(info.long, 1, 1, 1, true)
            if m.fit and FIT[m.fit] then
                local need = (tonumber(m.size) or 0) / 1073741824 + 2
                local why
                if m.fit == 1 then
                    why = T("целиком на видеокарте: полная скорость", "fully on the GPU: full speed")
                elseif m.fit == 2 then
                    why = T("часть модели на процессоре: работает, но в 2-5 раз медленнее", "part of the model on the CPU: works, but 2-5x slower")
                else
                    why = T("не хватает ни видеопамяти, ни ОЗУ", "neither VRAM nor RAM is enough")
                end
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine(FitText(m.fit) .. " - " .. why, 1, 1, 1, true)
                if hw and (hw.vram or 0) > 0 then
                    GameTooltip:AddLine(string.format(T("Нужно ~%.1f ГБ видеопамяти (модель + WoW + кэш), у вас %.1f ГБ", "Needs ~%.1f GB VRAM (model + WoW + cache), you have %.1f GB"),
                        need, (tonumber(hw.vram) or 0) / 1024), 0.8, 0.8, 0.8, true)
                end
            end
            GameTooltip:AddLine(T("Поиск в интернете и память диалога одинаковы у всех моделей.", "Web search and conversation memory are the same for every model."), 0.6, 0.6, 0.6, true)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function(self)
            self.bg:SetTexture(unpack(ACCENT))
            if type(GameTooltip) == "table" then GameTooltip:Hide() end
        end)
        if m.state == 1 then
            row.del:SetScript("OnClick", function(self)
                local arm = AccLuaAI.delArm
                if not (arm and arm.id == m.id and GetTime() <= arm.untilT) then
                    DisarmDelete()
                    AccLuaAI.delArm = { id = m.id, untilT = GetTime() + 3, btn = self }
                    self:SetWidth(DEL_ARMED_W) -- grows to the left over the end of the description line
                    self.text:SetText(DEL_ARMED)
                    SysStatus(T("Точно? нажмите ещё раз: удалить ", "Sure? click again to delete ") .. m.name .. " (" .. GB(m.size) .. ")")
                    DeleteTip(self, m, current)
                    return
                end
                DisarmDelete()
                menu:Hide()
                if type(GameTooltip) == "table" then GameTooltip:Hide() end
                Sys("[AI:DELETE=" .. m.id .. "]")
                SysStatus(T("Удаляю ", "Deleting ") .. m.name .. "...")
            end)
            row.del:SetScript("OnEnter", function(self)
                self.bg:SetTexture(unpack(DEL_HOVER))
                DeleteTip(self, m, current)
            end)
            row.del:SetScript("OnLeave", function(self)
                self.bg:SetTexture(unpack(DEL_BG))
                if type(GameTooltip) == "table" then GameTooltip:Hide() end
            end)
            row.del.text:SetText(DEL_LABEL)
            row.del:SetWidth(DEL_W)
            row.del:Show()
            row.sub:SetWidth(362)
        else
            row.del:Hide()
            row.sub:SetWidth(430)
        end
        row:Show()
    end
    for i = #list + 1, #menu.rows do menu.rows[i]:Hide() end
    menu:SetHeight(top + #list * ROW_STEP + 4)
    menu:Show()
end
modelBtn:SetScript("OnClick", function()
    if menu:IsShown() then menu:Hide() return end
    AccLuaAI.menuWanted = true
    Sys("[AI:MODELS]")
end)
thinkBtn:SetScript("OnClick", function()
    Sys("[AI:THINK=" .. (AccLuaAI.think == false and "1" or "0") .. "]")
end)

-- Header / constructor tooltips (Russian).
Tip(modeBtn, "TALK", T("Вопросы, код, макросы, поиск в интернете (? в начале).", "Questions, code, macros, web search (leading ?)."))
Tip(actBtn, "ACTIONS", T("Действия персонажа: прыгни, сядь, открой сумку, иди к NPC.", "Character actions: jump, sit, open bags, go to NPC."))
Tip(chatBtn, "CHAT", T("ИИ общается в игровом чате: отвечает на ЛС и /say на любые темы. Всё выключено по умолчанию - включите переключатели под шапкой.",
    "The AI talks in the game chat: replies to whispers and /say on any topic. All off by default - enable the toggles under the header."))
Tip(modelBtn, T("Модель", "Model"),
    T("Выбор локальной модели KoboldCpp. В меню видно, потянет ли её ваш ПК (VRAM/RAM).",
        "Pick a local KoboldCpp model. The menu shows whether your PC can run it (VRAM/RAM)."))
Tip(thinkBtn, T("Размышление перед кодом", "Thinking before code"),
    T("Вкл: код и макросы точнее, но ответ 20–90 с. Выкл: ответ 5–15 с. Стоп рядом с Send прерывает долгий ответ.",
        "On: more accurate code/macros, 20–90 s. Off: 5–15 s. Stop next to Send cancels a long reply."))
Tip(runBtn, T("Запуск плана", "Run plan"),
    T("Подтвердить и выполнить план ACTIONS, который меняет диалог/квест.",
        "Confirm and run an ACTIONS plan that changes gossip/quest state."))
Tip(stopBtn, T("Стоп действия", "Stop action"),
    T("Остановить текущее локальное ACTION (движение/шаги плана).",
        "Stop the current local ACTION (movement / plan steps)."))
Tip(sayBtn, T("Сказать черновик", "Say draft"),
    T("Отправить подготовленный черновик реплики в чат.",
        "Send the prepared chat draft."))
Tip(reloadBtn, "ReloadUI",
    T("Полная перезагрузка интерфейса WoW (ReloadUI). Снимает любой Apply-код, хуки и фреймы.",
        "Full WoW UI reload (ReloadUI). Clears any Apply code, hooks and frames."))
Tip(applyBtn, T("Применить код", "Apply code"),
    T("По умолчанию — последний блок ```lua```. Клик по коду — выбрать (N/M), Shift+клик — копировать. ПКМ — цикл. Повторный Apply того же блока заменяет прошлый (старые фреймы снимаются). Ошибка — в TALK + «Исправить с AI».",
        "Default: last ```lua```. Click code to select (N/M), Shift+click copies. RMB cycles. Re-applying the same block replaces the previous one. Errors go to TALK + \"Fix with AI\"."))
Tip(unloadBlockBtn, T("Снять блок", "Unload block"),
    T("Снять последний Apply выбранного блока (по applyId). ПКМ по коду в чате — то же. Только CreateFrame-фреймы сессии Apply; глобалы/хуки — ReloadUI.",
        "Unload the latest Apply for the selected block (by applyId). RMB on code in chat does the same. Only CreateFrame frames from that Apply; globals/hooks need ReloadUI."))
Tip(unloadBtn, T("Снять всё", "Unload all"),
    T("Снять все отслеженные Apply (все applyId). Best-effort Hide/Unregister. Хуки/глобалы/таймеры — только ReloadUI.",
        "Unload every tracked Apply (all applyIds). Best-effort Hide/Unregister. Hooks/globals/timers need ReloadUI."))
Tip(fileBtn, T("Файл working.lua", "working.lua file"),
    T("Сохранить / Открыть в редакторе / Загрузить в AI / Запустить файл целиком. Путь: AiRuntime\\scripts\\working.lua.",
        "Save / Open in editor / Load into AI / Run the whole file. Path: AiRuntime\\scripts\\working.lua."))
Tip(copyBtn, T("Копировать", "Copy"),
    T("Открыть окно с последним ответом или всей историей для копирования.",
        "Open a window with the last answer or full history to copy."))
Tip(clearBtn, T("Очистить чат", "Clear chat"),
    T("Очистить текущий чат (TALK, ACTIONS или CHAT) и сбросить его контекст на хосте (у CHAT — только экран).",
        "Clear the current chat (TALK, ACTIONS or CHAT) and reset its host context (CHAT: the screen only)."))
Tip(closeBtn, T("Закрыть", "Close"),
    T("Скрыть окно AccLua AI. Хост и модель продолжают работать.",
        "Hide the AccLua AI window. Host and model keep running."))

function Clock(sec)
    sec = math.floor(tonumber(sec) or 0)
    if sec <= 0 then return "--" end
    if sec >= 3600 then return string.format("%d:%02d:%02d", sec / 3600, (sec % 3600) / 60, sec % 60) end
    return string.format("%d:%02d", sec / 60, sec % 60)
end
dlErrors = {
    ["1"] = T("мало места на диске", "not enough disk space"),
    ["2"] = T("нет сети - повторите, докачка продолжится", "network error - retry, it resumes"),
    ["3"] = T("файл повреждён - повторите", "checksum mismatch - retry"),
    ["4"] = T("нет прав на запись в AiRuntime", "cannot write to AiRuntime"),
}
delErrors = {
    current = T("это текущая модель", "it is the current model"),
    downloading = T("модель сейчас скачивается", "it is being downloaded"),
    busy = T("ИИ занят, повторите позже", "the AI is busy, retry later"),
    unknown = T("неизвестная модель", "unknown model"),
    error = T("файл не удалось удалить", "the file could not be deleted"),
}
function ModelName(id)
    for _, m in ipairs(AccLuaAI.models or {}) do if m.id == id then return m.name end end
    return tostring(id)
end

-- /reload: the host keeps both dialogues. [Q]q[/Q][A]a[/A] = TALK, [AQ]q[/AQ][AA]a[/AA] = ACTIONS,
-- each part {XX}-escaped. Items go right below the welcome/hint lines; restored plans are never executed.
end
local HandleSys
do -- v17: scope block (Lua 5.1 200-local limit)
local function RestoreHistory(block)
    for _, spec in ipairs({ { "talk", "Q", "A" }, { "actions", "AQ", "AA" } }) do
        local mode, q, a = spec[1], spec[2], spec[3]
        local items = {}
        local pattern = "%[" .. q .. "%](.-)%[/" .. q .. "%]%s*%[" .. a .. "%](.-)%[/" .. a .. "%]"
        for qe, ae in block:gmatch(pattern) do
            local question = Trim(Decode(qe)):gsub("^%[AI:ACTIONS%]%s*", "")
            -- Skip host IPC noise that an older host may have stored as a "question".
            if not question:find("^%[AI:", 1, true) then
                local shown, plain = FormatReply(Decode(ae))
                items[#items + 1] = { YouLine(question) .. AI_LINE .. shown, plain, question }
            end
        end
        local chat = Chat(mode)
        -- Restored questions are older than anything sent in this session: they go first in the Up/Down list.
        if items[1] then
            local sent = {}
            for _, it in ipairs(items) do if it[3] ~= "" then sent[#sent + 1] = it[3] end end
            for _, q in ipairs(chat.sent) do sent[#sent + 1] = q end
            while #sent > 30 do table.remove(sent, 1) end
            chat.sent, chat.recall = sent, nil
        end
        while items[1] and #items + #chat.history > 40 do table.remove(items, 1) end -- keep the newest
        for _, it in ipairs(items) do
            local pos = math.min((chat.top or 0) + 1, #chat.history + 1)
            chat.top = InsertEntry(mode, pos, it[1], it[2])
        end
    end
end

-- text: decoded reply without "[AI] "; raw: the same before Decode; kind: the chat wait;
-- cmd: the silent command this reply answers (nil: unsolicited or unknown).
function HandleSys(text, raw, kind, cmd)
    if cmd and AccLuaAI.afterTries and not text:find("busy", 1, true) then AccLuaAI.afterTries[cmd] = nil end
    local cancel = text:match("%[CANCEL%](.-)%[/CANCEL%]")
    if cancel then
        -- Ack of the request Stop (or of the startup cancel); the caller released the wait.
        if kind == "cancel" then status:SetText(T("Запрос отменён", "Request cancelled")) end
        return
    end
    -- DLL error for a silent command ([SYSERR], never a chat answer): shown in the status line only.
    local sysErr = text:match("%[SYSERR%](.-)%[/SYSERR%]")
    if sysErr then
        if cmd == "[AI:SCRIPT_GET]" then AccLuaAI.runFileNext = nil end
        -- Apply during an AI reply: an older DLL refuses silent commands -> save working.lua after it.
        if cmd and cmd:find("^%[AI:SCRIPT_SAVE=") and AfterChat(cmd) then
            SysStatus(T("working.lua сохранится после ответа", "working.lua is saved after the reply"))
            return
        end
        SysStatus("|cffff7777" .. Shown(sysErr) .. "|r")
        return
    end
    if text:find("^%[RESET%]") then
        -- The host keeps the context while it generates: reset again once the reply is in.
        if text:find("^%[RESET%]busy") and cmd and cmd:find("^%[AI:RESET") and AfterChat(cmd) then
            SysStatus(T("Контекст на сервере очистится после ответа", "The host context is cleared after the reply"))
        end
        return
    end
    local think = text:match("%[THINK%](%d)%[/THINK%]")
    if think then
        local was = AccLuaAI.think
        AccLuaAI.think = think == "1"
        thinkBtn.text:SetText(ThinkLabel(AccLuaAI.think))
        FitBtn(thinkBtn, 56)
        LayoutHeader()
        if AccLuaAI.think and was ~= nil and not was then
            SysStatus("|cffffd200" .. T("Думать: вкл - код точнее, но ответ 1-3 минуты на слабой модели. Выкл = 10-30 с.",
                "Think: on - better code, but 1-3 minutes per answer on a small model. Off = 10-30 s.") .. "|r")
        end
        return
    end
    local scriptMsg = text:match("%[SCRIPT%](.-)%[/SCRIPT%]")
    if scriptMsg then
        if scriptMsg:find("^ok,saved") then
            SysStatus("|cff33dd66" .. T("working.lua сохранён", "working.lua saved") .. "|r")
        elseif scriptMsg:find("^ok,open") then
            SysStatus("|cff33dd66" .. T("working.lua открыт в редакторе", "working.lua opened in editor") .. "|r")
        elseif scriptMsg:find("^ok,clear") then
            SysStatus(T("working.lua очищен", "working.lua cleared"))
        elseif scriptMsg == "empty" then
            AccLuaAI.runFileNext = nil
            SysStatus(T("working.lua пуст", "working.lua is empty"))
        elseif scriptMsg:find("^hex:") then
            local body = HexDecode(scriptMsg:sub(5))
            local runIt = AccLuaAI.runFileNext
            AccLuaAI.runFileNext = nil
            if body then
                AccLuaAI.workingCache = body
                if runIt then
                    -- File -> Run file: execute (replaces the previous "file" run; errors -> TALK + Fix).
                    if Trim(body) == "" then
                        SysStatus(T("working.lua пуст", "working.lua is empty"))
                    elseif not CanReloadOrApply() then
                        SysStatus("|cffff7777" .. T("Запуск только в мире", "Run only in-world") .. "|r")
                    else
                        RunApply(body, "file", nil, false)
                    end
                else
                    OpenCopy("-- AccLua AI working.lua\n\n" .. body)
                    SysStatus("|cff33dd66" .. T("working.lua загружен (показан)", "working.lua loaded (shown)") .. "|r")
                end
            else
                SysStatus("|cffff7777" .. T("Не удалось декодировать working.lua", "Failed to decode working.lua") .. "|r")
            end
        elseif scriptMsg:find("^fail") then
            AccLuaAI.runFileNext = nil
            SysStatus("|cffff7777SCRIPT: " .. Shown(scriptMsg) .. "|r")
        else
            SysStatus("SCRIPT: " .. Shown(scriptMsg))
        end
        return
    end
    -- Items are parsed before the transport Decode when possible, so escaped brackets cannot split them.
    local hist = tostring(raw or ""):match("%[HISTORY%](.-)%[/HISTORY%]") or text:match("%[HISTORY%](.-)%[/HISTORY%]")
    if hist then
        RestoreHistory(hist)
        return
    end
    local del = text:match("%[DELETE%](.-)%[/DELETE%]")
    if del then
        local state, id, reason = del:match("^(%a+),([%w%-%.]+),?(.*)$")
        local shown = ModelName(id)
        reason = Trim(reason)
        if state == "ok" then
            SysStatus(T("Удалено: ", "Deleted: ") .. shown)
            AccLuaAI.menuWanted = true -- reopen the menu with the new list
            Sys("[AI:MODELS]")
        elseif reason == "busy" and id and AfterChat("[AI:DELETE=" .. id .. "]") then
            SysStatus(T("Удалю после ответа: ", "Deleting after the reply: ") .. shown)
        else
            SysStatus(T("Не удалось удалить ", "Could not delete ") .. shown .. ": " ..
                (delErrors[reason] or (reason ~= "" and reason or T("ошибка", "error"))))
        end
        return
    end
    local models = text:match("%[MODELS%](.-)%[/MODELS%]")
    if models then
        -- "cur:none" (or an empty cur:): no model is installed/selected; the menu still lists downloads.
        local current = models:match("^cur:([%w%-%.]+)")
        if current == "none" then current = nil end
        -- ";hw:vram:<MiB>,ram:<MiB>,layers:<n/m>,gpu:<name>" (v4 host); absent on older hosts.
        local hw = { vram = tonumber(models:match(";hw:vram:(%d+)")) or 0, ram = tonumber(models:match(",ram:(%d+)")) or 0,
            layers = models:match(",layers:([%d/]*)") or "", gpu = models:match(",gpu:([^;]*)") or "" }
        local list, found = {}, false
        for id, name, size, state, fit in models:gmatch(";([%w%-]+),([^,;]+),(%d+),(%d),?(%d?)") do
            list[#list + 1] = { id = id, name = name, size = tonumber(size), state = tonumber(state), fit = tonumber(fit) }
            if id == current then found = true AccLuaAI.modelName = name modelBtn.text:SetText(name) end
            if tonumber(state) == 2 then AccLuaAI.dlPoll = GetTime() + 1 end
        end
        if not current then
            -- No model (never installed, or the current one was deleted): the button says so.
            AccLuaAI.modelName = nil
            modelBtn.text:SetText(T("нет модели", "no model"))
        elseif not found and list[1] then
            -- A current id the list does not know: the button stops naming the old model.
            AccLuaAI.modelName = nil
            modelBtn.text:SetText(T("Модель", "Model"))
        end
        AccLuaAI.models, AccLuaAI.hw = list, hw
        if AccLuaAI.menuWanted then
            AccLuaAI.menuWanted = nil
            ShowModels(list, current, hw)
        elseif not AccLuaAI.hintShown then
            -- One-time hint: the recommended model is not installed yet.
            AccLuaAI.hintShown = true
            local hinted = false
            for _, m in ipairs(list) do
                if MODEL_INFO[m.id] and MODEL_INFO[m.id].star and m.state == 0 and m.id ~= current then
                    hinted = true
                    status:SetText(T("Рекомендуем ", "Recommended: ") .. m.name .. " (" .. GB(m.size) .. ") - " ..
                        T("кнопка модели, там же скачивание", "model button, download there") ..
                        (m.fit and FIT[m.fit] and (" - " .. FitText(m.fit)) or ""))
                end
            end
            if not hinted and not current then
                status:SetText(T("Модель не выбрана: нажмите \"нет модели\" - выбор и скачивание",
                    "No model selected: press \"no model\" to pick or download one"))
            end
        end
        return
    end
    local model = text:match("%[MODEL%](.-)%[/MODEL%]")
    if model then
        local state, id, name = model:match("^(%a+),([%w%-]+),?([^,]*)")
        if state == "ok" then
            AccLuaAI.modelName = name
            modelBtn.text:SetText(name)
            AddHistory(AccLuaAI.mode, "|cff66ccff" .. T("Модель: ", "Model: ") .. name .. "|r " ..
                T("(загружается 10-30 с, контекст сброшен)", "(loading 10-30 s, context reset)"), "")
            SysStatus(T("Модель переключена: ", "Model switched: ") .. name)
        elseif state == "missing" then
            Sys("[AI:DOWNLOAD=" .. tostring(id) .. "]")
        elseif state == "busy" and id and AfterChat("[AI:MODEL=" .. id .. "]") then
            -- v26/v27: stop the running answer, then switch (AfterChat queues MODEL after cancel).
            -- Must use AccLuaAI.CancelRequest — local CancelRequest is not visible in this do-block.
            if IsChatKind(AccLuaAI.waitingKind) then
                if type(AccLuaAI.CancelRequest) == "function" then
                    AccLuaAI.CancelRequest()
                end
                SysStatus(T("Останавливаю ответ и переключаю модель: ", "Stopping the reply, then switching to: ") .. ModelName(id))
            else
                SysStatus(T("Переключу модель после ответа: ", "Switching the model after the reply: ") .. ModelName(id))
            end
        else
            SysStatus(T("Не удалось переключить модель", "Could not switch the model"))
        end
        return
    end
    -- run,<id>,<allDone>,<allTotal>,<speed>,<eta>,<err>,<stage>: done/total are absolute bytes of the whole file.
    local dl = text:match("%[DL%](.-)%[/DL%]")
    if dl then
        local f = {}
        for v in dl:gmatch("[^,]+") do f[#f + 1] = v end
        local state, id = f[1], f[2]
        local shown = id
        for _, m in ipairs(AccLuaAI.models or {}) do if m.id == id then shown = m.name end end
        if state == "started" or state == "busy" or state == "run" then
            AccLuaAI.dlId = id
            AccLuaAI.dlPoll = GetTime() + 1.5
            local done, total, speed, eta = tonumber(f[3] or 0) or 0, tonumber(f[4] or 0) or 0, tonumber(f[5] or 0) or 0, f[6]
            if state == "run" and total > 0 then
                AccLuaAI.dlLine = string.format("%d%%  %.1f %s  %s %s", math.floor(done * 100 / total),
                    speed / 1048576, T("МБ/с", "MB/s"), T("осталось", "left"), Clock(eta))
                SysStatus(string.format("%s %s: %s / %s (%s)", T("Скачивание", "Downloading"), shown,
                    GB(done), GB(total), AccLuaAI.dlLine))
            else
                AccLuaAI.dlLine = T("скачивается...", "downloading...")
                SysStatus(T("Скачивание ", "Downloading ") .. tostring(shown) .. "...")
            end
            -- keep the open menu row current (cheap: ~3 rows)
            if menu:IsShown() and AccLuaAI.models and type(AccLuaAI.hw) == "table" then
                local cur
                for _, m in ipairs(AccLuaAI.models) do if m.name == AccLuaAI.modelName then cur = m.id end end
                ShowModels(AccLuaAI.models, cur, AccLuaAI.hw)
            end
        elseif state == "done" or state == "installed" then
            AccLuaAI.dlPoll = nil
            SysStatus(T("Скачано: ", "Downloaded: ") .. tostring(shown))
            Sys("[AI:MODEL=" .. tostring(id) .. "]")
        elseif state == "fail" then
            AccLuaAI.dlPoll = nil
            SysStatus(T("Ошибка скачивания: ", "Download failed: ") .. (dlErrors[f[7] or ""] or ("err " .. tostring(f[7]))))
        else
            AccLuaAI.dlPoll = nil
        end
    end
end

-- ===== CHAT mode: the AI answers whispers / says in the game chat =====
-- Everything is off by default and nothing is ever sent without a toggle the user turned on.
-- Settings live in _G.AccLuaAIChatCfg (survive a re-run of this file, not /reload).
-- Its own function: the main chunk is at Lua 5.1's 200-locals limit; only two functions leave it.
end
local ChatTick, ChatGameReply = (function()
local ChatTick, ChatGameReply
local CHAT_MSG_MAX, CHAT_MERGE_S, CHAT_MUTE_S = 245, 2.5, 1
local CHAT_PART_GAP, CHAT_REPLY_GAP, CHAT_PER_MIN = 0.6, 1.5, 8
local cfg = type(_G.AccLuaAIChatCfg) == "table" and _G.AccLuaAIChatCfg or {}
if cfg.whisper == nil then cfg.whisper = false end
if cfg.say == nil then cfg.say = false end
if cfg.allowOnly == nil then cfg.allowOnly = true end
if cfg.draft == nil then cfg.draft = false end -- v19: replies are sent by the AI itself unless Draft is on
if type(cfg.allow) ~= "table" then cfg.allow = {} end
_G.AccLuaAIChatCfg = cfg
AccLuaAI.chatCfg = cfg
AccLuaAI.chatIn = {}    -- "CHANNEL:Name" -> { sender, channel, text, at }: merge buffer (2.5 s)
AccLuaAI.chatSendQ = {} -- auto-send queue { text, chatType, target, sender, first }
local chatSend = { lastAt = -1e9, lastReplyAt = -1e9 }
local chatSeq = 0

local function ChannelOn(channel)
    if channel == "WHISPER" then return cfg.whisper and true or false end
    if channel == "SAY" then return cfg.say and true or false end
    return false
end
local function CleanName(name)
    return (Trim(name):gsub("%-.*$", ""))
end
local function IsAllowed(name)
    local low = name:lower()
    for _, n in ipairs(cfg.allow) do
        if n == name or n:lower() == low then return true end
    end
    return false
end
-- One chat line: no colour/link escapes, no pipes, no line breaks, no 4-byte UTF-8 (the client drops them).
local function CleanChatReply(text)
    text = tostring(text or "")
    text = text:gsub("```%w*", " ")
    text = text:gsub("|H.-|h(.-)|h", "%1"):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|", "")
    text = text:gsub("[\240-\244][\128-\191][\128-\191][\128-\191]", "")
    text = text:gsub("%c+", " "):gsub("%s+", " ")
    return Trim(text)
end
-- UTF-8-safe pieces of <= limit bytes, cut at a space when one is in the second half.
local function Utf8Chunks(text, limit)
    local out, rest = {}, Trim(text)
    while rest ~= "" do
        if #rest <= limit then out[#out + 1] = rest break end
        local piece = Utf8Cut(rest, limit)
        local sp = piece:match("^.*()%s")
        if sp and sp > limit / 2 then piece = piece:sub(1, sp - 1) end
        if piece == "" then piece = Utf8Cut(rest, limit) end
        out[#out + 1] = Trim(piece)
        rest = Trim(rest:sub(#piece + 1))
    end
    return out
end
local function ChanTag(channel)
    return channel == "WHISPER" and T("[ЛС]", "[W]") or T("[Сказать]", "[Say]")
end

-- Options UI (two lines in chatRow): toggles; allowlist edit + Добавить / Очистить + the list.
local chatUI = {}
AccLuaAI.chatUI = chatUI
local function Toggle(key, label, tipTitle, tipBody)
    local b = CreateFrame("Button", nil, chatRow)
    b:SetHeight(18)
    b.box = b:CreateTexture(nil, "ARTWORK")
    b.box:SetTexture("Interface\\Buttons\\UI-CheckBox-Up")
    b.box:SetWidth(18)
    b.box:SetHeight(18)
    b.box:SetPoint("LEFT", b, "LEFT", 0, 0)
    b.check = b:CreateTexture(nil, "OVERLAY")
    b.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    b.check:SetAllPoints(b.box)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.text:SetPoint("LEFT", b.box, "RIGHT", 1, 0)
    b.text:SetText(label)
    local tw = b.text.GetStringWidth and b.text:GetStringWidth() or 0
    b:SetWidth(18 + math.max(40, tonumber(tw) or 0) + 8)
    b.key = key
    b:SetScript("OnClick", function(self)
        cfg[self.key] = not cfg[self.key]
        if AccLuaAI.RefreshChatUI then AccLuaAI.RefreshChatUI() end
    end)
    Tip(b, tipTitle, tipBody)
    chatUI[key] = b
    return b
end
local tWhisper = Toggle("whisper", T("Отвечать в ЛС", "Reply to whispers"), T("Отвечать в ЛС", "Reply to whispers"),
    T("ИИ отвечает на личные сообщения (/w). По умолчанию выключено. С «Черновик» ответ только вставляется в поле чата - отправляете вы сами.",
        "The AI answers whispers. Off by default. With Draft the reply is only put into the chat input: you send it."))
tWhisper:SetPoint("TOPLEFT", chatRow, "TOPLEFT", 0, 0)
local tSay = Toggle("say", T("Отвечать в /say", "Reply in /say"), T("Отвечать в /say", "Reply in /say"),
    T("ИИ отвечает на /say (Сказать) игроков рядом. По умолчанию выключено. Без белого списка ответит любому - осторожно.",
        "The AI answers /say of nearby players. Off by default. Without the allowlist it answers anyone - careful."))
tSay:SetPoint("LEFT", tWhisper, "RIGHT", 6, 0)
local tAllow = Toggle("allowOnly", T("Только белый список", "Allowlist only"), T("Только белый список", "Allowlist only"),
    T("Отвечать только никам из списка (вторая строка). По умолчанию включено; пустой список = никому.",
        "Answer only the names in the list (second line). On by default; an empty list = nobody."))
tAllow:SetPoint("LEFT", tSay, "RIGHT", 6, 0)
local tDraft = Toggle("draft", T("Черновик (Enter вручную)", "Draft (Enter to send)"), T("Черновик", "Draft"),
    T("Выкл (по умолчанию): ИИ отправляет ответ сам - не чаще 1 раза в 1.5 с и не больше 3 ответов в минуту одному игроку. Вкл: ответ только вставляется в поле чата («/w Имя ...»), отправляете Enter.",
        "Off (default): the AI sends the reply itself - at most once per 1.5 s and 3 replies per minute per player. On: the reply is only put into the chat input (\"/w Name ...\"), Enter sends it."))
tDraft:SetPoint("LEFT", tAllow, "RIGHT", 6, 0)

local allowLabel = chatRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
allowLabel:SetPoint("TOPLEFT", chatRow, "TOPLEFT", 2, -27)
allowLabel:SetTextColor(0.65, 0.72, 0.84)
allowLabel:SetText(T("Белый список:", "Allowlist:"))
local nickEdit = CreateFrame("EditBox", nil, chatRow, "InputBoxTemplate")
nickEdit:SetAutoFocus(false)
nickEdit:SetMaxLetters(24)
nickEdit:SetWidth(96)
nickEdit:SetHeight(18)
nickEdit:SetPoint("LEFT", allowLabel, "RIGHT", 10, 0)
chatUI.nick = nickEdit
local addNickBtn = Button(chatRow, 60, T("Добавить", "Add"))
addNickBtn:SetHeight(18)
addNickBtn:SetPoint("LEFT", nickEdit, "RIGHT", 6, 0)
FitBtn(addNickBtn, 56)
chatUI.add = addNickBtn
local clearNickBtn = Button(chatRow, 60, T("Очистить", "Clear"))
clearNickBtn:SetHeight(18)
clearNickBtn:SetPoint("LEFT", addNickBtn, "RIGHT", 3, 0)
FitBtn(clearNickBtn, 56)
chatUI.clear = clearNickBtn
local allowList = chatRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
allowList:SetPoint("LEFT", clearNickBtn, "RIGHT", 8, 0)
allowList:SetPoint("RIGHT", chatRow, "RIGHT", -2, 0)
allowList:SetJustifyH("LEFT")
if allowList.SetWordWrap then allowList:SetWordWrap(false) end
chatUI.list = allowList

AccLuaAI.RefreshChatUI = function()
    for _, key in ipairs({ "whisper", "say", "allowOnly", "draft" }) do
        local b = chatUI[key]
        if b then
            if cfg[key] then b.check:Show() else b.check:Hide() end
        end
    end
    local names = table.concat(cfg.allow, ", ")
    if names == "" then
        names = "|cff999999" .. T("список пуст", "the list is empty") .. "|r"
    elseif #names > 70 then
        names = Utf8Cut(names, 67) .. "..."
    end
    allowList:SetText(names)
end
local function AddNick()
    local name = CleanName(nickEdit:GetText() or "")
    if name ~= "" and not name:find("[%s|%[%]]") then
        if not IsAllowed(name) then cfg.allow[#cfg.allow + 1] = name end
        nickEdit:SetText("")
    end
    nickEdit:ClearFocus()
    AccLuaAI.RefreshChatUI()
end
addNickBtn:SetScript("OnClick", AddNick)
nickEdit:SetScript("OnEnterPressed", AddNick)
nickEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
clearNickBtn:SetScript("OnClick", function()
    cfg.allow = {}
    AccLuaAI.RefreshChatUI()
end)
Tip(nickEdit, T("Ник игрока", "Player name"),
    T("Ник как в игре (регистр важен). Enter или «Добавить» - в белый список.",
        "The name as in game (case matters). Enter or Add puts it into the allowlist."))
Tip(addNickBtn, T("Добавить ник", "Add name"),
    T("Добавить ник из поля в белый список.", "Add the name from the field to the allowlist."))
Tip(clearNickBtn, T("Очистить список", "Clear the list"),
    T("Удалить все ники из белого списка (при «Только белый список» ИИ никому не ответит).",
        "Remove every name from the allowlist (with Allowlist only the AI answers nobody)."))
AccLuaAI.RefreshChatUI()

-- Game-chat send queue: 0.6 s between messages, a new reply at most once per 1.5 s. A toggle turned
-- off (or Draft turned on) meanwhile drops what is still queued.
local function PumpChatSend(now)
    local q = AccLuaAI.chatSendQ
    local p = q[1]
    if not p then return end
    if not ChannelOn(p.chatType) or cfg.draft then
        table.remove(q, 1)
        return
    end
    if now < chatSend.lastAt + CHAT_PART_GAP then return end
    if p.first and now < chatSend.lastReplyAt + CHAT_REPLY_GAP then return end
    table.remove(q, 1)
    chatSend.lastAt = now
    if p.first then chatSend.lastReplyAt = now end
    PeerState(p.sender).muteUntil = now + CHAT_MUTE_S -- anti-loop: their next lines are ignored for 3 s
    if p.chatType == "SAY" then AccLuaAI.chatSayMuteUntil = now + CHAT_MUTE_S end
    if type(SendChatMessage) == "function" then pcall(SendChatMessage, p.text, p.chatType, nil, p.target) end
end

-- A merged incoming text becomes one [AI:CHAT] request (sent now or queued like TALK/ACTIONS).
local function DispatchIncoming(buf, now)
    if not ChannelOn(buf.channel) then return end
    if cfg.allowOnly and not IsAllowed(buf.sender) then return end
    local st = PeerState(buf.sender)
    local recent = {}
    for _, t in ipairs(st.hits) do if now - t < 60 then recent[#recent + 1] = t end end
    st.hits = recent
    if #recent >= CHAT_PER_MIN then
        AddHistory("chat", "|cff999999" .. string.format(T("(лимит: не больше %d ответов в минуту для %s - пропущено)",
            "(limit: at most %d replies per minute to %s - skipped)"), CHAT_PER_MIN, Shown(buf.sender)) .. "|r", "")
        return
    end
    local text = Utf8Cut(buf.text, 600)
    local item = { mode = "chat", game = true, sender = buf.sender, channel = buf.channel, text = text,
        host = "[AI:CHAT]" .. buf.sender .. " (" .. buf.channel .. "): " .. text }
    -- Marked before the send: a reply delivered at once must find (and release) the pending slot.
    st.pending = true
    st.hits[#st.hits + 1] = now
    if not (ChatBlocked() or AccLuaAI.queue[1]) and SendRequest(item) then
        UpdateContext()
        return
    end
    if #AccLuaAI.queue >= 10 then
        st.pending = nil
        table.remove(st.hits)
        AddHistory("chat", "|cffff7777" .. T("Очередь заполнена - сообщение от ", "Queue is full - message from ") ..
            Shown(buf.sender) .. T(" пропущено", " skipped") .. "|r", "")
        return
    end
    item.idx = AddHistory("chat", GameHead(item) .. " |cff999999" .. T("(в очереди)", "(queued)") .. "|r", "")
    table.insert(AccLuaAI.queue, item)
    UpdateContext()
end

-- Ticker step: merged buffers whose 2.5 s ran out (one pending request per player), then the send queue.
ChatTick = function(now)
    local ready = {}
    for key, buf in pairs(AccLuaAI.chatIn) do
        if now >= buf.at and not PeerState(buf.sender).pending then ready[#ready + 1] = key end
    end
    -- First come, first served (pairs order is arbitrary).
    table.sort(ready, function(a, b) return AccLuaAI.chatIn[a].seq < AccLuaAI.chatIn[b].seq end)
    for _, key in ipairs(ready) do
        local buf = AccLuaAI.chatIn[key]
        AccLuaAI.chatIn[key] = nil
        DispatchIncoming(buf, now)
    end
    PumpChatSend(now)
end

local function OnChatEvent(_, event, msg, author)
    local channel = (event == "CHAT_MSG_WHISPER" and "WHISPER") or (event == "CHAT_MSG_SAY" and "SAY") or nil
    if not channel or not ChannelOn(channel) then return end
    local sender = CleanName(tostring(author or ""))
    msg = Trim(msg)
    if sender == "" or msg == "" then return end
    local me = type(UnitName) == "function" and UnitName("player") or nil
    if me and sender == me then return end
    if cfg.allowOnly and not IsAllowed(sender) then return end
    local now = GetTime()
    local st = PeerState(sender)
    if now < (st.muteUntil or 0) then return end
    if channel == "SAY" and now < (AccLuaAI.chatSayMuteUntil or 0) then return end
    -- Another AI's own marker: never answer it (bot-to-bot loops).
    if msg:find("^%[AI") then return end
    AddHistory("chat", "|cffffc864" .. ChanTag(channel) .. " " .. Shown(sender) .. ":|r " .. NoFence(Shown(msg)), "")
    local key = channel .. ":" .. sender
    local buf = AccLuaAI.chatIn[key]
    if buf then
        buf.text = Utf8Cut(buf.text .. " " .. msg, 600)
        buf.at = now + CHAT_MERGE_S
    else
        chatSeq = chatSeq + 1
        AccLuaAI.chatIn[key] = { sender = sender, channel = channel, text = msg, at = now + CHAT_MERGE_S, seq = chatSeq }
    end
end
local chatEvFrame = CreateFrame("Frame")
AccLuaAI.chatEvFrame = chatEvFrame
chatEvFrame:RegisterEvent("CHAT_MSG_WHISPER")
chatEvFrame:RegisterEvent("CHAT_MSG_SAY")
chatEvFrame:SetScript("OnEvent", OnChatEvent)

-- The host's reply to a game request: one clean line, then a draft in the chat input or the send queue.
ChatGameReply = function(item, text)
    local qaError = tostring(text or ""):match("%[QA_ERROR%](.-)%[/QA_ERROR%]")
    if qaError then
        status:SetText(qaError)
        Answer("|cffff7777" .. Shown(qaError) .. "|r", "")
        return
    end
    local clean = CleanChatReply(text)
    if clean == "" then
        Answer("|cff999999" .. T("(пустой ответ - ничего не отправлено)", "(empty reply - nothing sent)") .. "|r", "")
        return
    end
    local parts = Utf8Chunks(clean, CHAT_MSG_MAX)
    local note
    if not ChannelOn(item.channel) then
        note = T("(не отправлено: переключатель выключен)", "(not sent: the toggle is off)")
    elseif cfg.draft then
        local draft = parts[1] or ""
        local line = item.channel == "WHISPER" and ("/w " .. item.sender .. " " .. draft) or ("/s " .. draft)
        if type(ChatFrame_OpenChat) == "function" then pcall(ChatFrame_OpenChat, line) end
        PeerState(item.sender).muteUntil = GetTime() + CHAT_MUTE_S
        note = T("(черновик в поле чата - Enter отправит)", "(draft in the chat input - Enter sends it)")
        if parts[2] then note = note .. T(" (обрезано до 245 байт)", " (cut to 245 bytes)") end
    else
        for k = 1, math.min(2, #parts) do
            table.insert(AccLuaAI.chatSendQ, { text = parts[k], chatType = item.channel,
                target = item.channel == "WHISPER" and item.sender or nil, sender = item.sender, first = k == 1 })
        end
        note = T("(отправляется)", "(sending)")
    end
    Answer(Shown(clean) .. " |cff999999" .. note .. "|r", clean)
    status:SetText(T("CHAT: ответ для ", "CHAT: reply for ") .. Shown(item.sender) .. " " .. note)
end
return ChatTick, ChatGameReply
end)() -- CHAT mode

do -- v17: scope block (Lua 5.1 200-local limit)
local actionFrame = CreateFrame("Frame")
actionFrame:SetScript("OnUpdate", function()
    if not executor.active then return end
    if not IsWorldReady() then
        ForceStop(T("Действие остановлено: мир не готов", "Action stopped: world is no longer ready"))
        return
    end
    if executor.navigation then
        UpdateNpcNavigation()
        return
    end
    local step = executor.steps[1]
    if not step then
        ForceStop(executor.completionStatus or T("Действие выполнено", "Action completed"))
        return
    end
    if GetTime() < step.at then return end
    if not DispatchStatic(step.action, step.arg, step.text) then
        ForceStop("Action stopped: Tesq1 is unavailable")
        return
    end
    table.remove(executor.steps, 1) -- one semantic action per frame
end)
actionFrame:RegisterEvent("PLAYER_LEAVING_WORLD")
actionFrame:RegisterEvent("PLAYER_LOGOUT")
actionFrame:RegisterEvent("PLAYER_DEAD")
actionFrame:SetScript("OnEvent", function() ForceStop(T("Действие остановлено игрой", "Action stopped by game state")) end)

-- Always-on ticker (cheap): auto-scroll, silent commands, download polling, waiting status, queue.
local tick = 0
local ticker = CreateFrame("Frame")
ticker:SetScript("OnUpdate", function(_, elapsed)
    if scrollPending > 0 and frame:IsShown() then
        scrollPending = scrollPending - 1
        output:UpdateScrollChildRect()
        SyncBar(output, outputBar, true) -- scroll offset and slider value both go to the end
    end
    tick = tick + (elapsed or 0)
    if tick < 0.2 then return end
    tick = 0
    local now = GetTime()
    -- v20: title dot = current state (busy while a reply is awaited, red for 8 s after an error).
    if AccLuaAI.SetDot then
        if IsChatKind(AccLuaAI.waitingKind) then AccLuaAI.SetDot("busy")
        elseif AccLuaAI.lastError or now < (AccLuaAI.errAt or 0) + 8 then AccLuaAI.SetDot("err")
        else AccLuaAI.SetDot("ready") end
    end
    if bootAt and now > bootAt then
        bootAt = nil
        -- Startup, in this order and ahead of anything clicked meanwhile: drop a request left running by
        -- the UI before /reload, then the model list, then both dialogues.
        table.insert(sysQueue, 1, "[AI:CANCEL]")
        table.insert(sysQueue, 2, "[AI:MODELS]")
        table.insert(sysQueue, 3, "[AI:HISTORY]")
        table.insert(sysQueue, 4, "[AI:THINK]")
    end
    -- Timeouts first: an expired talk/actions request must get its "timeout" line before anything is sent.
    local kind = AccLuaAI.waitingKind
    if kind and now >= (AccLuaAI.waitingUntil or 0) then
        AccLuaAI.waitingKind, AccLuaAI.waitingSince, AccLuaAI.waitingUntil = nil, nil, nil
        if IsChatKind(kind) then
            Answer("|cffff7777" .. T("нет ответа (таймаут)", "no reply (timeout)") .. "|r", "")
            status:SetText(T("Нет ответа от ИИ", "No reply from the AI host"))
        end -- "cancel": the entry already says "cancelled"; the queue just moves on
    end
    if AccLuaAI.waitingSys and now >= (AccLuaAI.waitingSysUntil or 0) then
        AccLuaAI.waitingSys, AccLuaAI.waitingSysUntil = nil, nil -- no answer to a silent command: move on
    end
    if AccLuaAI.delArm and now > AccLuaAI.delArm.untilT then DisarmDelete() end
    if AccLuaAI.afterChat and not AccLuaAI.waitingKind and now >= (AccLuaAI.afterChatAt or 0) then
        local cmds = {}
        for cmd in pairs(AccLuaAI.afterChat) do cmds[#cmds + 1] = cmd end
        table.sort(cmds)
        AccLuaAI.afterChat = nil
        for _, cmd in ipairs(cmds) do Sys(cmd) end
    end
    if AccLuaAI.dlPoll and now > AccLuaAI.dlPoll and #sysQueue == 0 then
        AccLuaAI.dlPoll = now + 1.5
        Sys("[AI:DLSTATUS]")
    end
    if sysQueue[1] and SendTracked("sys", sysQueue[1]) then table.remove(sysQueue, 1) end
    PumpQueue()
    ChatTick(now)
    if frame:IsShown() then UpdateContext() end
    kind = AccLuaAI.waitingKind
    if IsChatKind(kind) and AccLuaAI.waitingSince and frame:IsShown() then
        -- "Answering", not "Thinking": the Think toggle is a different thing. Code + think on: thinking about code.
        local label = T("Отвечаю...", "Answering...")
        if AccLuaAI.pendingCode and AccLuaAI.think ~= false then label = T("Думаю над кодом...", "Thinking about the code...") end
        local note = AccLuaAI.note and now < (AccLuaAI.noteUntil or 0) and AccLuaAI.note
        status:SetText(string.format("%s %d %s", label, now - AccLuaAI.waitingSince, T("с", "s")) ..
            (AccLuaAI.queue[1] and (", " .. QueueText()) or "") .. (note and ("  -  " .. note) or ""))
    end
end)

local SYS_TAGS = { "MODELS", "MODEL", "DL", "RESET", "HISTORY", "DELETE", "CANCEL", "THINK", "SYSERR", "SCRIPT" }
local function IsSysReply(text)
    for _, tag in ipairs(SYS_TAGS) do
        if text:find("^%[" .. tag .. "%]") then return true end
    end
    return false
end

function _G.AccLuaAI_Receive(text)
    local raw = tostring(text or ""):gsub("^%[AI%]%s*", "")
    local visibleText = Decode(raw)
    -- Misrouted outbound IPC (e.g. SCRIPT_SAVE hex) must never become a chat You/AI line.
    if visibleText:find("^%[AI:SCRIPT") or visibleText:find("^%[AI:MODELS")
            or visibleText:find("^%[AI:THINK") or visibleText:find("^%[AI:RESET")
            or visibleText:find("^%[AI:DELETE=") or visibleText:find("^%[AI:DLSTATUS")
            or visibleText:find("^%[AI:HISTORY") or visibleText:find("^%[AI:CANCEL")
            or visibleText:find("^%[AI:MODEL=") or visibleText:find("^%[AI:DOWNLOAD=")
            or visibleText:find("^%[AI:SCRIPT_") then
        if SysAwaited(GetTime()) then AccLuaAI.waitingSys, AccLuaAI.waitingSysUntil = nil, nil end
        return
    end
    local now = GetTime()
    local kind = AccLuaAI.waitingKind
    local sysCmd = SysAwaited(now) and AccLuaAI.waitingSys or nil
    local sysReply = IsSysReply(visibleText)
    -- v26: only a reply that IS an error counts; a structured sys payload may merely contain the tag.
    local qaError = (not sysReply) and visibleText:find("%[QA_ERROR%]") ~= nil
    if qaError then AccLuaAI.errAt = now end
    local function ReleaseSys() AccLuaAI.waitingSys, AccLuaAI.waitingSysUntil = nil, nil end
    -- An older DLL keeps one request at a time: its "busy" answers the silent command sent next to the chat
    -- request (sent more than 1 s ago; the host's own "busy" for a fresh chat request comes at once).
    -- Put the command back and send silent commands only between chat replies from now on.
    if qaError and sysCmd and kind and now - (AccLuaAI.waitingSince or now) > 1
            and visibleText:find("AI is busy", 1, true) then
        ReleaseSys()
        table.insert(sysQueue, 1, sysCmd)
        AccLuaAI.sysSerial = true
        return
    end
    if sysReply then
        -- A sys reply releases only the sys wait: a TALK/ACTIONS request keeps waiting for its answer.
        if visibleText:find("^%[CANCEL%]") then
            -- Ack of the request Stop (chat wait "cancel") or of the startup cancel (a silent command).
            if kind == "cancel" then
                AccLuaAI.waitingKind, AccLuaAI.waitingSince, AccLuaAI.waitingUntil = nil, nil, nil
            elseif sysCmd == "[AI:CANCEL]" then
                ReleaseSys()
            end
            HandleSys(visibleText, raw, kind)
        else
            ReleaseSys()
            if not qaError then HandleSys(visibleText, raw, kind, sysCmd) end
        end
        PumpQueue()
        UpdateContext()
        return
    end
    -- Output of the cancelled request is dropped (its entry says "cancelled").
    if kind == "cancel" then return end
    if not IsChatKind(kind) and sysCmd then
        -- No chat reply is awaited: this answers the silent command (e.g. an older DLL's plain [QA_ERROR]).
        ReleaseSys()
        if not qaError then HandleSys(visibleText, raw, kind, sysCmd) end
        PumpQueue()
        UpdateContext()
        return
    end
    AccLuaAI.waitingKind, AccLuaAI.waitingSince, AccLuaAI.waitingUntil = nil, nil, nil
    -- CHAT game request: the reply goes to that player (draft / send queue), the window is not popped up.
    local gameItem = AccLuaAI.pendingItem
    if type(gameItem) == "table" and gameItem.game then
        ChatGameReply(gameItem, visibleText)
        UpdateContext()
        PumpQueue()
        return
    end
    -- The chat/mode the request was sent from (kind nil: a late reply after a timeout -> current mode).
    local reqMode = ModeOf(AccLuaAI.pendingMode or kind or AccLuaAI.mode)
    if not frame:IsShown() then frame:Show() end
    local shown, plain, steps, planStatus, requiresConfirm, qaError = FormatReply(visibleText)
    if qaError then
        status:SetText(qaError)
        Answer(shown, plain)
        UpdateContext()
        PumpQueue()
        return
    end
    -- Plans belong to ACTIONS: a TALK reply without a plan leaves a plan waiting for Run alone.
    if steps or reqMode == "actions" then
        executor.plan = steps
        executor.requiresConfirm = requiresConfirm and true or false
        SetRun(steps and executor.requiresConfirm)
    end
    if steps and reqMode == "actions" and not executor.requiresConfirm then
        StartConfirmedPlan()
    elseif steps and reqMode == "actions" then
        status:SetText(T("План меняет диалог/квест - нажмите Run", "Plan changes UI/quest state - press Run"))
    elseif steps then
        status:SetText(T("План готов - включите ACTIONS для запуска", "Plan ready - switch to ACTIONS to run it"))
    else
        status:SetText(planStatus or T("Готово", "Done"))
    end
    Answer(shown, plain)
    UpdateContext()
    PumpQueue()
end

function _G.AccLuaAI_Disable()
    AccLuaAI.chat.draft = nil
    -- CHAT mode stops answering the game chat with the AI off (toggles back off, queues dropped).
    AccLuaAI.chatSendQ, AccLuaAI.chatIn = {}, {}
    for _, st in pairs(AccLuaAI.chatPeers) do st.pending = nil end
    if type(AccLuaAI.chatCfg) == "table" then AccLuaAI.chatCfg.whisper, AccLuaAI.chatCfg.say = false, false end
    if type(AccLuaAI.RefreshChatUI) == "function" then AccLuaAI.RefreshChatUI() end
    AccLuaAI.waitingKind, AccLuaAI.waitingSince, AccLuaAI.waitingUntil = nil, nil, nil
    AccLuaAI.waitingSys, AccLuaAI.waitingSysUntil, AccLuaAI.afterChat = nil, nil, nil
    DropQueue()
    ForceStop(T("ИИ выключен", "AI disabled"))
    copyFrame:Hide()
    menu:Hide()
    frame:Hide()
end

-- The bar's AI button calls this every click: v21 toggles (second click closes the window).
function _G.AccLuaAI_Show()
    if frame:IsShown() then frame:Hide() else frame:Show() end
end

-- No /accluaai slash: open via AccLuaBar AI button when Нейросеть is enabled.

UpdateMode()
runBtn:Hide()
stopBtn:Hide()
sayBtn:Hide()
UpdateContext()
RenderHistory(false)
Resized()
end
