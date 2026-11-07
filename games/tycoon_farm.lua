--[[
    tycoon_farm.lua - infinite money / autobuy / button ESP for a single-player tycoon

    Written as a LuaVM stress test: Drawing panel with clickable rows, remote firing,
    instance tree walks, firetouchinterest and a world-to-screen overlay.

    What it uses from the game:
      ReplicatedStorage.Remotes.changerValue          RemoteEvent(number)   infinite money
      ReplicatedStorage.DropperEvents.CollectDrop     RemoteEvent(Vector3, number)  fallback
      Workspace.Plots.<n>.Claimed                     which plot is yours
      Workspace.Plots.<n>.Buttons                     the buy pads

    Auto Buy       touches each open pad in numeric order with firetouchinterest (your root
                   part against the pad's TouchInterest part, touch then untouch), then checks
                   that the pad is gone. You stay where you are - no teleports.
    Infinite Money fires changerValue(INF_VALUE) once a second; if that remote is missing
                   it falls back to CollectDrop with INF_AMOUNT.
    Button ESP     a ring on every open pad with a tag: number, price, distance.

    FireServer in Calamity goes out through Remote Spy's hook: the first call brings the hook
    up, argument types are copied from calls the game made itself, and the call leaves the
    next time the game fires a remote of its own. "waiting" / "starting" in the console
    clears by itself while the game runs.

    The panel is only the three toggles. Keys: F3 buy, F4 infinite, F6 ESP, F1 hide the
    panel, F7 dump what the script sees to the console and Workspace/tycoon_dump.txt.
    What the script is doing is printed to the console, once per change.
    Running it again replaces the old copy.

    Cost: everything per frame is the ESP (two projections per open pad) and the mouse and
    key polls. The rest runs on timers: the pad list refreshes once a second, and only while
    Auto Buy or the ESP is on.
]]

if _G.__tycoon_farm and _G.__tycoon_farm.stop then pcall(_G.__tycoon_farm.stop) end

local CFG = {
    -- the plot to use when none of them says it is yours (Claimed is read first)
    PLOT            = "8",
    INF_VALUE       = 1e21,        -- Remotes.changerValue:FireServer(INF_VALUE)
    INF_INTERVAL    = 1.0,
    -- fallback when changerValue is missing
    COLLECT_POS     = Vector3.new(-1611.95, 1.9511, 271.025),
    INF_AMOUNT      = 999999999,
    OPEN_BELOW      = 0.9,         -- a pad more transparent than this is locked (when pads differ)
    -- auto buy
    TOUCH_HOLD      = 0.1,         -- seconds between the touch and the untouch
    TOUCH_WAIT      = 0.45,        -- seconds after the untouch before checking the pad is gone
    RETRY_AFTER     = 6.0,         -- a pad that survived a touch waits this long
    MAX_FAILS       = 3,           -- ... and is skipped for good after this many touches
    SCAN_BUY        = 1.0,         -- seconds between pad refreshes while Auto Buy is on
    SCAN_ESP        = 1.5,         -- ... while only the ESP is on
    -- esp
    ESP_MAX         = 48,
    ESP_Y_OFFSET    = 0,           -- studs; nudge the ring up (+) or down (-) if it is off the pad
    -- ui
    UI_X            = 20,
    UI_Y            = 240,
    UI_W            = 200,
    KEYS            = { ui = "F1", buy = "F3", inf = "F4", esp = "F6", dump = "F7" },
    -- cursor position is in screen pixels; shift it if the overlay is offset (windowed Roblox)
    MOUSE_DX        = 0,
    MOUSE_DY        = 0,
}

local clock = os.clock or tick

-- ---------------------------------------------------------------------------
-- helpers
-- Reads go through pcall(idx, obj, key) rather than pcall(function() ... end): a closure is
-- built per call otherwise, and a frame can make hundreds of reads.
-- ---------------------------------------------------------------------------

local function idx(o, k) return o[k] end
local function call(o, m, ...) return o[m](o, ...) end

local function prop(o, k)
    local ok, v = pcall(idx, o, k)
    if ok then return v end
    return nil
end

-- varargs, not a fixed (o, m, a): GetChildren and friends reject an extra nil argument
local function ask(o, m, ...)
    local ok, v = pcall(call, o, m, ...)
    if ok then return v end
    return nil
end

local EMPTY = {}

local function child(inst, name)
    if not inst then return nil end
    return ask(inst, "FindFirstChild", name)
end

local function children(inst)
    if not inst then return EMPTY end
    return ask(inst, "GetChildren") or EMPTY
end

local function clip(s, n)
    s = tostring(s)
    if #s > n then return s:sub(1, n - 1) .. "~" end
    return s
end

-- 1500 -> "1.5K", 2e6 -> "2M"
local SHORT_UNITS = { { 1e15, "Q" }, { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }
local function short(n)
    for _, u in ipairs(SHORT_UNITS) do
        if n >= u[1] then
            local v = string.format("%.1f", n / u[1]):gsub("%.0$", "")
            return v .. u[2]
        end
    end
    return string.format("%.0f", n)
end

local function fmt(n)
    if type(n) ~= "number" then return tostring(n) end
    if n ~= n then return "nan" end
    if n >= 1e15 or n <= -1e15 then return string.format("%.3e", n) end
    local s = string.format("%.0f", math.abs(n))
    s = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return (n < 0 and "-" or "") .. s
end

local BASEPART = {
    Part = true, MeshPart = true, UnionOperation = true, WedgePart = true, CornerWedgePart = true,
    TrussPart = true, SpawnLocation = true, Seat = true, VehicleSeat = true,
}
local PAD_NAMES = { button = true, touch = true, pad = true, hitbox = true, touchpart = true }

-- the part of a buy pad that is touched: the one with a TouchInterest (what the game's Touched
-- script listens on), else the pad itself, else the best-named part inside it
local function find_part(inst, parts)
    for _, d in ipairs(parts) do
        if ask(d, "FindFirstChildOfClass", "TouchTransmitter") then return d end
    end
    if parts[1] == inst then return inst end
    local best
    for _, d in ipairs(parts) do
        local n = prop(d, "Name")
        if n and PAD_NAMES[n:lower()] then return d end
        best = best or d
    end
    return best
end

-- every BasePart in (or being) a pad, capped; their transparency says whether the pad is shown
local function base_parts(inst)
    local out = {}
    local cls = prop(inst, "ClassName")
    if cls and BASEPART[cls] then out[1] = inst; return out end
    for _, d in ipairs(ask(inst, "GetDescendants") or EMPTY) do
        local c = prop(d, "ClassName")
        if c and BASEPART[c] then
            out[#out + 1] = d
            if #out >= 8 then break end
        end
    end
    return out
end

local function find_price(inst)
    for _, c in ipairs(children(inst)) do
        local n = prop(c, "Name")
        if n then
            n = n:lower()
            if n == "price" or n == "cost" then
                local cls = prop(c, "ClassName")
                if cls == "IntValue" or cls == "NumberValue" then
                    local v = prop(c, "Value")
                    if type(v) == "number" then return v end
                end
            end
        end
    end
    return nil
end

local function my_position()
    local x, y, z = GetLocalPlayerPosition()
    if not x or (x == 0 and y == 0 and z == 0) then return nil end
    return Vector3.new(x, y, z)
end

-- the part that does the touching: your character's HumanoidRootPart
local function my_root()
    local lp = prop(game:GetService("Players"), "LocalPlayer")
    local char = lp and (prop(lp, "Character") or child(workspace, prop(lp, "Name")))
    return char and child(char, "HumanoidRootPart")
end

-- ---------------------------------------------------------------------------
-- state
-- ---------------------------------------------------------------------------

local S = { running = true, visible = true, buy = true, inf = false, esp = true }   -- test copy: Auto Buy on at start

local Players = game:GetService("Players")

local W = {                       -- the world: plot, pads, remotes
    plot = nil, plot_why = "", plot_t = -99,
    kids = {}, known = {}, buttons = {}, open_list = {}, scan_t = -99,
    remotes = {}, filter = false, open = 0,
    me = nil, me_t = -99,
}

local F = { next = 0, sent = 0, status = "idle", ok = true }
local B = { state = "idle", cur = nil, root = nil, t = 0, nxt = 0, bought = 0,
            retry = {}, fails = {}, skipped = 0, msg = "off" }

-- ---------------------------------------------------------------------------
-- world reads
-- ---------------------------------------------------------------------------

local function local_player()
    return prop(Players, "LocalPlayer")
end

local function claimed_by_me(v, lp, name, uid)
    if v ~= nil and lp ~= nil and v == lp then return true end   -- ObjectValue -> the player
    local t = type(v)
    if t == "number" then return v == uid end
    if t == "string" then return v == name or v == tostring(uid) end
    return false
end

local function find_plot()
    local plots = child(workspace, "Plots")
    if not plots then return nil, "no Workspace.Plots" end
    local lp = local_player()
    local name = lp and prop(lp, "Name")
    local uid = lp and prop(lp, "UserId")
    local claimed_true, forced = {}, nil
    for _, p in ipairs(children(plots)) do
        local c = child(p, "Claimed")
        if c then
            local v = prop(c, "Value")
            if claimed_by_me(v, lp, name, uid) then return p, "claimed by you" end
            if v == true then claimed_true[#claimed_true + 1] = p end
        end
        if prop(p, "Name") == CFG.PLOT then forced = p end
    end
    if #claimed_true == 1 then return claimed_true[1], "the only claimed plot" end
    if forced then return forced, "from CFG.PLOT" end
    return nil, "no plot found"
end

local REMOTE_PATHS = {
    collect = { "DropperEvents", "CollectDrop" },
    inf     = { "Remotes", "changerValue" },
}

local function get_remote(now, key)
    local r = W.remotes[key]
    if not r then r = { t = -99 }; W.remotes[key] = r end
    if r.inst and now - r.t < 5 then return r.inst end
    r.t = now
    local at = ask(game, "GetService", "ReplicatedStorage")
    for _, name in ipairs(REMOTE_PATHS[key]) do at = child(at, name) end
    r.inst = at
    return at
end

local function min_transparency(parts)
    local lo
    for i = 1, #parts do
        local t = prop(parts[i], "Transparency")
        if type(t) == "number" and (not lo or t < lo) then lo = t end
    end
    return lo
end

local function same_list(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

local function new_pad(k, order)
    local name = prop(k, "Name") or "?"
    local parts = base_parts(k)
    local part = find_part(k, parts)
    local e = {
        inst = k, name = name, num = tonumber(name) or 1e18, class = prop(k, "ClassName") or "?",
        price = find_price(k), part = part, parts = parts, order = order,
    }
    if part then
        local p, s = prop(part, "Position"), prop(part, "Size")
        if p and p.X then
            e.pos, e.size = p, s
            -- ESP anchor: the base of the pad, and a point one radius to the side to measure the ring by
            local sy = s and s.Y or 1
            local wr = s and math.max(s.X, s.Z) * 0.5 or 2
            e.anchor = Vector3.new(p.X, p.Y - sy * 0.5 + CFG.ESP_Y_OFFSET, p.Z)
            e.edge = Vector3.new(p.X + wr, e.anchor.Y, p.Z)
        end
    end
    return e
end

-- The pad list: rebuilt and re-sorted only when pads come or go (the Buttons children are the
-- same addresses in the same order otherwise); transparency is re-read every scan, because
-- that is what flips when the game unlocks a pad.
local function scan_buttons(now)
    W.scan_t = now
    local btns = W.plot and child(W.plot, "Buttons")
    local kids = children(btns)
    if not same_list(kids, W.kids) then
        W.kids = kids
        local list, seen = {}, {}
        for i, k in ipairs(kids) do
            seen[k] = true
            local e = W.known[k]
            if not e then e = new_pad(k, i); W.known[k] = e end
            e.order = i
            list[#list + 1] = e
        end
        for k in pairs(W.known) do
            if not seen[k] then W.known[k] = nil end
        end
        -- numeric name first (the game numbers its pads in unlock order), then price, then tree order
        table.sort(list, function(a, b)
            if a.num ~= b.num then return a.num < b.num end
            local pa, pb = a.price or 1e18, b.price or 1e18
            if pa ~= pb then return pa < pb end
            return a.order < b.order
        end)
        W.buttons = list
    end

    -- Locked pads are usually in the tree but hidden. When the pads split into visible and
    -- hidden groups, only the visible ones are open; when they all look alike there is
    -- nothing to tell them apart by, so every pad counts as open.
    local list, low, high = W.buttons, false, false
    for i = 1, #list do
        local e = list[i]
        local tr = min_transparency(e.parts)
        e.tr = tr
        if tr then
            if tr < CFG.OPEN_BELOW then low = true else high = true end
        end
    end
    W.filter = low and high
    local open_list = {}
    for i = 1, #list do
        local e = list[i]
        e.open = (not W.filter) or e.tr == nil or e.tr < CFG.OPEN_BELOW
        if e.open then open_list[#open_list + 1] = e end
    end
    W.open_list, W.open = open_list, #open_list
end

-- ---------------------------------------------------------------------------
-- panel: a 256-UI window (menu key P by default)
-- ---------------------------------------------------------------------------

local UI_URL = "https://raw.githubusercontent.com/ars240/256-UI/refs/heads/main/src.lua"
local Lib = loadstring(game:HttpGet(UI_URL))() or UI256

local COL = {                     -- the ESP's colours
    bg     = Color3.fromRGB(14, 15, 20),
    accent = Color3.fromRGB(88, 166, 255),
    on     = Color3.fromRGB(80, 220, 120),
    text   = Color3.fromRGB(232, 234, 240),
    warn   = Color3.fromRGB(255, 190, 80),
    bad    = Color3.fromRGB(255, 100, 100),
}
local dump
local TOGGLES = {
    { key = "buy", name = "Auto Buy",       hot = CFG.KEYS.buy },
    { key = "inf", name = "Infinite Money", hot = CFG.KEYS.inf },
    { key = "esp", name = "Button ESP",     hot = CFG.KEYS.esp },
}
local rows = {}          -- key -> the window's toggle row

local function set_toggle(key, on)
    S[key] = on and true or false
    if key == "buy" and S.buy then
        B.retry, B.fails, B.skipped, B.nxt = {}, {}, 0, 0
    end
    if key == "inf" and S.inf then F.next = 0 end
    print("[tycoon] " .. key .. (S[key] and " on" or " off"))
end

-- the hotkeys flip the window's toggle, so the window and the script never disagree
local function flip(key)
    local r = rows[key]
    if r then r:Set(not r:Get()) else set_toggle(key, not S[key]) end
end

local function build_panel()
    local win = Lib:CreateWindow({ title = "Tycoon Farm", subtitle = "Calamity Hub", size = Vector2.new(560, 380) })
    local tab = win:Tab("Farm", "crosshair")
    local sec = tab:Section("Automation", "Left")
    for _, t in ipairs(TOGGLES) do
        rows[t.key] = sec:Toggle(t.name, S[t.key], function(on) set_toggle(t.key, on) end, "hotkey " .. t.hot)
    end
    local info = tab:Section("Status", "Right")
    info:Label(function() return "Open pads: " .. W.open end)
    info:Label(function() return "Bought: " .. B.bought end)
    info:Label(function() return "Buy: " .. tostring(B.msg) end)
    info:Label(function() return "Money: " .. tostring(F.status) end)
    info:Button("Dump to console", function() dump() end)
    win:AddSettingsTab("cog")
end

-- ---------------------------------------------------------------------------
-- button ESP: a ring on the pad, the tag centred in it
-- ---------------------------------------------------------------------------

local esp = {}
local have_w2s = draw and type(draw.WorldToScreen) == "function"
local w2s = have_w2s and draw.WorldToScreen
local TAG_CHAR, TAG_H, LABEL_EVERY = 7.6, 18, 0.25

local function esp_slot(i)
    local s = esp[i]
    if not s then
        s = {
            ring = Drawing.new("Circle"),
            bg   = Drawing.new("Square"),
            bar  = Drawing.new("Square"),
            t    = Drawing.new("Text"),
            visible = false, label_t = -99, label = "", tw = 0,
        }
        s.ring.NumSides, s.ring.Filled, s.ring.Thickness, s.ring.Transparency, s.ring.ZIndex = 32, false, 2, 1, 6
        s.bg.Filled, s.bg.Color, s.bg.Transparency, s.bg.ZIndex = true, COL.bg, 0.8, 6
        s.bar.Filled, s.bar.Transparency, s.bar.ZIndex = true, 1, 7
        s.t.Outline, s.t.Color, s.t.ZIndex = true, COL.text, 8
        s.ring.Visible, s.bg.Visible, s.bar.Visible, s.t.Visible = false, false, false, false
        esp[i] = s
    end
    return s
end

local function esp_show(s, v)
    if s.visible == v then return end
    s.visible = v
    s.ring.Visible, s.bg.Visible, s.bar.Visible, s.t.Visible = v, v, v, v
end

local function pad_color(e)
    if B.cur == e then return COL.on end
    local f = B.fails[e.name]
    if f then return f >= CFG.MAX_FAILS and COL.bad or COL.warn end
    return COL.accent
end

local function update_esp(now)
    local shown = 0
    if S.esp and S.visible and have_w2s then
        if now - W.me_t >= LABEL_EVERY then W.me, W.me_t = my_position(), now end
        local me = W.me
        local list = W.open_list
        for i = 1, #list do
            if shown >= CFG.ESP_MAX then break end
            local e = list[i]
            local a = e.anchor
            if a then
                local x, y = w2s(a)
                if x then
                    shown = shown + 1
                    local s = esp_slot(shown)

                    -- ring radius: the pad's world radius, measured in screen pixels
                    local r = 8
                    local rx, ry = w2s(e.edge)
                    if rx then r = math.sqrt((rx - x) ^ 2 + (ry - y) ^ 2) end
                    if r < 5 then r = 5 elseif r > 90 then r = 90 end

                    local col = pad_color(e)
                    if s.col ~= col then
                        s.col = col
                        s.ring.Color, s.bar.Color = col, col
                    end

                    -- the label (and so the tag width) changes a few times a second, not every frame
                    local relabel = false
                    if now - s.label_t >= LABEL_EVERY or s.e ~= e then
                        s.label_t, s.e = now, e
                        local label = tonumber(e.name) and ("#" .. e.name) or clip(e.name, 14)
                        if e.price then label = label .. "  $" .. short(e.price) end
                        if me then
                            local dx, dy, dz = e.pos.X - me.X, e.pos.Y - me.Y, e.pos.Z - me.Z
                            label = label .. "  " .. math.floor(math.sqrt(dx * dx + dy * dy + dz * dz) + 0.5) .. "m"
                        end
                        if label ~= s.label then
                            s.label = label
                            s.t.Text = label
                            s.tw = #label * TAG_CHAR + 16
                            s.bg.Size = Vector2.new(s.tw, TAG_H)
                            relabel = true
                        end
                    end

                    if relabel or s.x ~= x or s.y ~= y then
                        s.x, s.y = x, y
                        s.ring.Position = Vector2.new(x, y)
                        local tx, ty = x - s.tw * 0.5, y - TAG_H * 0.5
                        s.bg.Position = Vector2.new(tx, ty)
                        s.bar.Position = Vector2.new(tx, ty)
                        s.t.Position = Vector2.new(tx + 9, ty + 2)
                    end
                    if s.bar_h ~= TAG_H then s.bar_h = TAG_H; s.bar.Size = Vector2.new(3, TAG_H) end
                    if s.r ~= r and (not s.r or math.abs(s.r - r) >= 0.5) then
                        s.r = r
                        s.ring.Radius = r
                    end
                    esp_show(s, true)
                end
            end
        end
    end
    for i = shown + 1, #esp do esp_show(esp[i], false) end
end

-- ---------------------------------------------------------------------------
-- money
-- ---------------------------------------------------------------------------

local function money_step(now)
    if not S.inf or now < F.next then return end
    -- changerValue first; CollectDrop with a big amount only if that remote is missing
    local remote = get_remote(now, "inf")
    local amount, a1, a2 = CFG.INF_VALUE, CFG.INF_VALUE, nil
    if not remote then
        remote = get_remote(now, "collect")
        amount, a1, a2 = CFG.INF_AMOUNT, CFG.COLLECT_POS, CFG.INF_AMOUNT
    end
    if not remote then
        F.status, F.ok, F.next = "remote not found", false, now + 1
        return
    end
    local ok, err
    if a2 ~= nil then ok, err = pcall(call, remote, "FireServer", a1, a2)
    else ok, err = pcall(call, remote, "FireServer", a1) end
    if ok then
        F.sent = F.sent + 1
        F.ok, F.status = true, "queued " .. fmt(amount) .. " (#" .. F.sent .. ")"
        F.next = now + CFG.INF_INTERVAL
    else
        local e = tostring(err):gsub("^.-FireServer: ", "")
        F.ok = false
        if e:find("has not sent one yet", 1, true) then
            F.status = "waiting for the game to send " .. (e:match("is (a [%w]+)") or "an arg")
        elseif e:find("starting", 1, true) then
            F.status = "Remote Spy hook starting..."
        else
            F.status = e
        end
        F.next = now + 1
    end
end

-- ---------------------------------------------------------------------------
-- buying
-- ---------------------------------------------------------------------------

local function pick_candidate(now)
    local list = W.open_list
    for i = 1, #list do
        local e = list[i]
        if (B.fails[e.name] or 0) < CFG.MAX_FAILS and (B.retry[e.name] or 0) <= now and e.pos then
            return e
        end
    end
    return nil
end

local function count_skipped()
    local n, list = 0, W.open_list
    for i = 1, #list do
        local e = list[i]
        if (B.fails[e.name] or 0) >= CFG.MAX_FAILS or not e.pos then n = n + 1 end
    end
    B.skipped = n
end

local function buy_step(now)
    if not S.buy then
        if B.state ~= "idle" then B.state, B.cur = "idle", nil end
        B.msg = "off"
        return
    end
    if not W.plot then B.msg = "no plot yet"; return end
    if type(firetouchinterest) ~= "function" then
        S.buy = false
        if rows.buy then rows.buy:Set(false) end
        print("[tycoon] Auto Buy needs firetouchinterest, which this Calamity does not have - switched off")
        return
    end

    -- A failed touch (no root part, a pad that went away mid-touch) counts against the pad like
    -- a touch that bought nothing.
    local function failed(e)
        B.fails[e.name] = (B.fails[e.name] or 0) + 1
        B.retry[e.name] = now + CFG.RETRY_AFTER
        B.cur, B.state, B.nxt = nil, "idle", now + 0.1
    end

    if B.state == "idle" then
        if now < B.nxt then return end
        local cand = pick_candidate(now)
        if not cand then
            count_skipped()
            B.msg = (#W.buttons == 0) and "nothing left to buy"
                or (W.open == 0 and "no open pads (waiting for unlock)" or "open pads waiting / skipped")
            B.nxt = now + 0.1
            return
        end
        local root = my_root()
        if not root then B.msg = "no character to touch with"; B.nxt = now + 1; return end
        if not cand.part then failed(cand); return end
        -- only an explicit false is a failure: Calamity's pcall can hand back nil for a C function that
        -- returned nothing
        local ok, err = pcall(firetouchinterest, root, cand.part, 0)
        if ok == false then
            print("[tycoon] touch failed on " .. clip(cand.name, 22) .. ": " .. tostring(err))
            failed(cand)
            return
        end
        B.cur, B.root, B.state, B.t = cand, root, "touching", now
        B.msg = "touching " .. clip(cand.name, 22)

    elseif B.state == "touching" then
        if now - B.t < CFG.TOUCH_HOLD then return end
        pcall(firetouchinterest, B.root, B.cur.part, 1)
        B.state, B.t = "settle", now

    elseif B.state == "settle" then
        if now - B.t < CFG.TOUCH_WAIT then return end
        scan_buttons(now)
        local e, gone = B.cur, true
        for _, b in ipairs(W.buttons) do
            if b.name == e.name then gone = false; break end
        end
        if gone then
            B.bought = B.bought + 1
            B.fails[e.name], B.retry[e.name] = nil, nil
        else
            B.fails[e.name] = (B.fails[e.name] or 0) + 1
            B.retry[e.name] = now + CFG.RETRY_AFTER
        end
        B.cur, B.state, B.nxt = nil, "idle", now + 0.05
    end
end

-- ---------------------------------------------------------------------------
-- dump (F7): what the script actually sees, for fixing a wrong guess
-- ---------------------------------------------------------------------------

local function v3(v)
    if not (v and v.X) then return "nil" end
    return string.format("(%.1f, %.1f, %.1f)", v.X, v.Y, v.Z)
end

-- Goes to Workspace/tycoon_dump.txt as well as the console; a long list is unreadable in the
-- console. Per pad: name, class, price, pad part, position, size, the transparency of each
-- part, whether the script counts it open, and its children.
function dump()
    local lines = {}
    local function out(...)
        local t = {}
        for i = 1, select("#", ...) do t[i] = tostring((select(i, ...))) end
        lines[#lines + 1] = table.concat(t, " ")
    end
    local now = clock()
    out("---- tycoon dump ----")
    local lp = local_player()
    out("player", lp and prop(lp, "Name"), "uid", lp and prop(lp, "UserId"))
    for _, p in ipairs(children(child(workspace, "Plots"))) do
        local c = child(p, "Claimed")
        out(string.format("plot %s  Claimed=%s %s", tostring(prop(p, "Name")),
            c and tostring(prop(c, "ClassName")) or "none", c and tostring(prop(c, "Value")) or ""))
    end
    out("using plot", W.plot and prop(W.plot, "Name"), "(" .. W.plot_why .. ")")
    for key in pairs(REMOTE_PATHS) do
        local r = get_remote(now, key)
        out("remote", key, r and prop(r, "ClassName") or "NOT FOUND")
    end
    out("queued so far", F.sent, "  fire status:", F.status)
    scan_buttons(now)
    out(string.format("pads %d, open %d, filter by transparency: %s", #W.buttons, W.open, tostring(W.filter)))
    for i, e in ipairs(W.buttons) do
        local kids = {}
        for _, c in ipairs(children(e.inst)) do
            kids[#kids + 1] = (prop(c, "Name") or "?") .. ":" .. (prop(c, "ClassName") or "?")
        end
        local trs = {}
        for _, p in ipairs(e.parts) do
            local t = prop(p, "Transparency")
            trs[#trs + 1] = type(t) == "number" and string.format("%.2f", t) or "?"
        end
        out(string.format("%3d %-14s %-10s price=%s open=%s tr=%s parts=[%s] pos=%s size=%s kids={%s}",
            i, clip(e.name, 14), e.class, tostring(e.price), tostring(e.open),
            e.tr and string.format("%.2f", e.tr) or "?", table.concat(trs, ","), v3(e.pos), v3(e.size),
            table.concat(kids, ",")))
    end
    local text = table.concat(lines, "\n")
    for _, l in ipairs(lines) do print("[tycoon] " .. l) end
    local ok, err = pcall(writefile, "tycoon_dump.txt", text .. "\n")
    print("[tycoon] " .. (ok and "dump written to Workspace\\tycoon_dump.txt" or ("dump file failed: " .. tostring(err))))
end

-- ---------------------------------------------------------------------------
-- input
-- ---------------------------------------------------------------------------

local function keys_step()
    local K = CFG.KEYS
    for _, t in ipairs(TOGGLES) do
        if waskeypressed(t.hot) then flip(t.key) end
    end
    if waskeypressed(K.dump) then dump() end
end

-- ---------------------------------------------------------------------------
-- main loop
-- ---------------------------------------------------------------------------

local P = { errors = 0, last_err = "", said_money = nil, said_buy = nil }

local function step()
    local now = tick()

    keys_step()

    -- the world is only read while something uses it
    local need = S.buy or (S.esp and S.visible)
    if need then
        if W.plot == nil and now - W.plot_t >= 3 or W.plot ~= nil and now - W.plot_t >= 10 then
            W.plot_t = now
            local p, why = find_plot()
            if p ~= W.plot then
                W.known, W.kids, W.buttons, W.open_list, W.open, W.scan_t = {}, {}, {}, {}, 0, -99
            end
            W.plot, W.plot_why = p, why
        end
        if W.plot and B.state == "idle" and now - W.scan_t >= (S.buy and CFG.SCAN_BUY or CFG.SCAN_ESP) then
            scan_buttons(now)
        end
    end

    money_step(now)
    buy_step(now)
    update_esp(now)

    -- the panel is only toggles, so what the script is doing goes to the console, once per change
    if S.inf and F.status ~= P.said_money then P.said_money = F.status; print("[tycoon] money: " .. F.status) end
    if S.buy and B.msg ~= P.said_buy then P.said_buy = B.msg; print("[tycoon] buy: " .. B.msg) end
end

local function stop()
    S.running = false
    pcall(function() Lib:Destroy() end)
    for _, s in ipairs(esp) do
        for _, d in ipairs({ s.ring, s.bg, s.bar, s.t }) do pcall(call, d, "Remove") end
    end
    esp = {}
end
_G.__tycoon_farm = { stop = stop, state = S, cfg = CFG, dump = dump }

build_panel()

spawn(function()
    while S.running do
        local ok, err = pcall(step)
        if not ok then
            P.errors = P.errors + 1
            if tostring(err) ~= P.last_err then
                P.last_err = tostring(err)
                print("[tycoon] step error: " .. P.last_err)
            end
            -- a loop that errors every frame turns the automation off rather than spamming the game
            if P.errors >= 200 then
                if rows.inf then rows.inf:Set(false) end
                if rows.buy then rows.buy:Set(false) end
                S.inf, S.buy = false, false
                print("[tycoon] too many errors, automation switched off")
                P.errors = 0
            end
        end
        wait(0)      -- once per frame; everything heavy in step() is on its own timer
    end
end)

print("[tycoon] loaded. " .. CFG.KEYS.buy .. " buy, " .. CFG.KEYS.inf .. " infinite money, "
    .. CFG.KEYS.esp .. " ESP, " .. CFG.KEYS.dump .. " dump")
