--[[
    fisch_autofish.lua - unattended auto fishing for Fisch

    SAFE BY DESIGN: this script fires no remotes at all. Everything it does is real mouse and
    keyboard input, the same as a player:

      equip  the hotbar key that puts the rod in your hand (1-9, tried in turn)
      cast   hold the left mouse button and let go (the power bar)
      shake  click the shake button where it is on screen
      reel   play the bar: hold the mouse while the fish is right of your bar, let go while left

    Why no remotes: Fisch moved fishing onto its Net package (RF/FishingRod/Cast, RE/Reel/Finish,
    ...) and left the old ReplicatedStorage.events.reelfinished behind as a trap - firing it is an
    instant kick ("son... im crine", 2026-10-30). The new ones check what they are sent server-side.
    Input is what the game expects, so there is nothing for it to catch.

    Screen positions come from the GUI objects' AbsolutePosition / AbsoluteSize, read from memory.
    The offset of those fields changes between Roblox builds and Calamity's own value was wrong on
    this one (0xf4 read nothing), so the script finds it on the shake button: the first offset where
    four floats make a square-ish rectangle on the screen. It is checked again on the reel bar.

    Needs Roblox in the foreground (clicks would go to whatever window is in front); the loop
    waits while it is not. No key binds: the 256-UI panel (menu key P) has the toggles,
    the numbers and a teleport to any of the listed places.
    Files in Workspace\:
      fisch_status.txt   rewritten every 2 s
      fisch_log.txt      everything said to the console, with times
      fisch_dump.txt     _G.__fisch.dump(): the shake / reel GUI trees and their rectangles
    Running it again replaces the old copy.
]]

if _G.__fisch and _G.__fisch.stop then pcall(_G.__fisch.stop) end

local CFG = {
    CAST_HOLD     = 0.95,     -- seconds the mouse is held for a cast (the power bar)
    CAST_TIMEOUT  = 35,       -- seconds after a cast with no shake or reel before casting again
    SHAKE_GAP     = 0.1,      -- seconds between shake clicks (each click itself takes ~0.2 s)
    INSETS        = { 0, 58, 36 },  -- y added to AbsolutePosition: tried in turn until a click lands
    REEL_TIMEOUT  = 60,       -- a reel open longer than this is let go
    REEL_LOOKAHEAD = 0.25,    -- seconds ahead the bars are predicted (their momentum)
    REEL_ZONE     = 0.18,     -- of the player bar's width: the fish this close to its middle is "on"
    AFTER_CATCH   = 2.0,      -- seconds between a catch and the next cast
    MOUSE_DX      = 0,        -- shift every click (windowed Roblox: the window's client origin)
    MOUSE_DY      = 0,
}

local SCRIPT = "[fisch]"

-- ---------------------------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------------------------

local function idx(o, k) return o[k] end
local function call(o, m, ...) return o[m](o, ...) end
local function prop(o, k)
    if not o then return nil end
    local ok, v = pcall(idx, o, k)
    if ok then return v end
    return nil
end
local function ask(o, m, ...)
    if not o then return nil end
    local ok, v = pcall(call, o, m, ...)
    if ok then return v end
    return nil
end
local EMPTY = {}
local function child(o, name) return o and ask(o, "FindFirstChild", name) or nil end
local function children(o) return o and ask(o, "GetChildren") or EMPTY end
local function name_of(o) return prop(o, "Name") or "?" end
local function class_of(o) return prop(o, "ClassName") or "?" end

local T0 = tick()
local function log(...)
    local t = {}
    for i = 1, select("#", ...) do t[i] = tostring((select(i, ...))) end
    local line = SCRIPT .. " " .. table.concat(t, " ")
    print(line)
    pcall(appendfile, "fisch_log.txt", string.format("[%7.1f] %s\n", tick() - T0, line))
end

-- the same message only once until it changes
local said = {}
local function say(key, msg)
    if said[key] ~= msg then said[key] = msg; log(msg) end
end

-- ---------------------------------------------------------------------------------------------
-- screen
-- ---------------------------------------------------------------------------------------------

local function viewport()
    local cam = prop(workspace, "CurrentCamera")
    local v = cam and prop(cam, "ViewportSize")
    if v and v.X and v.X > 100 then return v.X, v.Y end
    return nil, nil      -- unreadable: callers do nothing rather than guess a resolution
end

local function readf(a)
    local ok, v = pcall(memory_read, "float", a)
    if ok and type(v) == "number" and v == v and v > -1e6 and v < 1e6 then return v end
    return nil
end
local function quad(inst, off)
    return readf(inst + off), readf(inst + off + 4), readf(inst + off + 8), readf(inst + off + 12)
end
local function on_screen(x, y, w, h)
    if not (x and y and w and h) then return false end
    local vw, vh = viewport()
    if not vw then return false end
    return x >= -64 and y >= -128 and x <= vw + 64 and y <= vh + 64 and
           w >= 6 and h >= 6 and w <= vw * 1.2 and h <= vh * 1.2
end

-- AbsolutePosition's offset: Calamity's value first, the last one known to work second, then a scan
local ABS, ABS_OK = nil, false
local ABS_FIRST = {}
do
    local ok, v = pcall(getoffset, "GuiBase2D::AbsolutePosition")
    if ok and type(v) == "number" then ABS_FIRST[#ABS_FIRST + 1] = v end
    ABS_FIRST[#ABS_FIRST + 1] = 0x10c
    local ok2, saved = pcall(readfile, "fisch_offset.txt")
    local n = ok2 and tonumber(saved)
    if n then table.insert(ABS_FIRST, 1, n) end
end

-- the shake button is a square-ish button: the offset where it reads as one
local function calibrate(button)
    -- AbsoluteSize is whole pixels: the scan wants that too, so a stray pair of floats elsewhere in
    -- the object is not taken for it (the known offsets are trusted without it)
    local tried = {}
    local function whole(v) return math.abs(v - math.floor(v + 0.5)) < 0.01 end
    local function try(off, strict)
        if tried[off] then return false end
        tried[off] = true
        local x, y, w, h = quad(button, off)
        if on_screen(x, y, w, h) and math.abs(w - h) <= 0.3 * math.max(w, h) and
           (not strict or (whole(w) and whole(h))) then
            ABS, ABS_OK = off, true
            pcall(writefile, "fisch_offset.txt", tostring(off))
            log(string.format("AbsolutePosition is at 0x%x (button at %.0f,%.0f size %.0fx%.0f)", off, x, y, w, h))
            return true
        end
        return false
    end
    for _, off in ipairs(ABS_FIRST) do if try(off, false) then return true end end
    for off = 0x60, 0x400, 4 do if try(off, true) then return true end end
    return false
end

local function rect(inst)
    -- (instances are objects that print as their name, not plain numbers: no type check here)
    if not (ABS and inst) then return nil end
    local x, y, w, h = quad(inst, ABS)
    if not (x and y and w and h) or w <= 0 or h <= 0 then return nil end
    return x, y, w, h
end

local function foreground()
    return type(isrbxactive) ~= "function" or isrbxactive()
end

-- when the script last moved or pressed the mouse: the panel ignores presses around then, so the
-- script's own clicks never flip a toggle
local own_t = 0
local function move(x, y)
    own_t = tick()
    mousemoveabs(math.floor(x + CFG.MOUSE_DX), math.floor(y + CFG.MOUSE_DY))
end

local held = false
local function hold(on)
    if on and not held then own_t = tick(); mouse1press(); held = true
    elseif not on and held then own_t = tick(); mouse1release(); held = false end
end

-- Roblox has to see the cursor over a button before the press counts as a click on it: move
-- there, give it a frame or two, nudge by a pixel (a move event it cannot coalesce away), then
-- press and release with a real hold. A bare move-press-release 40 ms apart did nothing.
local function click_at(x, y)
    hold(false)
    move(x, y)
    task.wait(0.08)
    move(x + 1, y + 1)
    task.wait(0.05)
    mouse1press()
    task.wait(0.07)
    mouse1release()
end

local function tap(vk, secs)
    input.KeyDown(vk)
    task.wait(secs or 0.07)
    input.KeyUp(vk)
end

-- where casts and reel holds are clicked: the middle of the screen, a bit above it
local function rest_point()
    local vw, vh = viewport()
    if not vw then return nil, nil end
    return vw * 0.5, vh * 0.42
end

-- ---------------------------------------------------------------------------------------------
-- the game
-- ---------------------------------------------------------------------------------------------

local Players = game:GetService("Players")

local function me() return prop(Players, "LocalPlayer") end
local function character()
    local lp = me()
    return lp and (prop(lp, "Character") or child(workspace, name_of(lp)))
end
-- PlayerGui does not change for the life of the player: looked up again only every few seconds
-- (and right away when the last one went missing), instead of two reads every tick
local gui_cache, gui_t = nil, -99
local function player_gui()
    local now = tick()
    if gui_cache and now - gui_t < 3 then return gui_cache end
    gui_t = now
    local lp = me()
    gui_cache = lp and child(lp, "PlayerGui") or nil
    return gui_cache
end

local function is_rod(t)
    return class_of(t) == "Tool" and name_of(t):lower():find("rod", 1, true) ~= nil
end
local function equipped_rod()
    for _, c in ipairs(children(character())) do
        if is_rod(c) then return c end
    end
    return nil
end
local function backpack_rod()
    local lp = me()
    for _, c in ipairs(children(lp and child(lp, "Backpack"))) do
        if is_rod(c) then return c end
    end
    return nil
end

-- ---------------------------------------------------------------------------------------------
-- state
-- ---------------------------------------------------------------------------------------------

local S = {
    running = true, paused = true,      -- off until switched on in the panel
    state = "start", state_t = tick(),
    caught = 0, casts = 0, shakes = 0, shake_miss = 0, lost = 0,
    inset_i = 1, inset_ok = false,
    last_err = "", errors = 0,
}

local function set_state(s)
    if S.state ~= s then S.state, S.state_t = s, tick() end
end

-- ---------------------------------------------------------------------------------------------
-- steps
-- ---------------------------------------------------------------------------------------------

local EQUIP_KEYS = { 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39 }
local equip_key = nil
local function equip()
    if equipped_rod() then return true end
    if not backpack_rod() then
        say("equip", "no rod in the character or the Backpack - waiting")
        return false
    end
    local keys = equip_key and { equip_key } or EQUIP_KEYS
    for _, vk in ipairs(keys) do
        tap(vk)
        task.wait(0.4)
        if equipped_rod() then
            equip_key = vk
            say("equip", "rod equipped with key " .. string.char(vk) .. ": " .. name_of(equipped_rod()))
            return true
        end
        -- something else came out: put it back
        for _, c in ipairs(children(character())) do
            if class_of(c) == "Tool" then tap(vk); task.wait(0.3); break end
        end
    end
    if equip_key then equip_key = nil end    -- the hotbar changed: try every key next time
    say("equip", "could not equip the rod with keys 1-9")
    return false
end

local function cast()
    if not equipped_rod() then return false end
    S.casts = S.casts + 1
    hold(false)
    local x, y = rest_point()
    if not x then say("cast", "screen size unreadable - not casting"); return false end
    move(x, y)
    task.wait(0.05)
    mouse1press()
    task.wait(CFG.CAST_HOLD)
    mouse1release()
    say("cast", "casting (" .. CFG.CAST_HOLD .. " s hold)")
    set_state("waiting")
    return true
end

-- The button to click: safezone's button ("default" in this version, "button" in older ones).
-- shakeui stays in PlayerGui between shakes, so a shake is on only while the ScreenGui is enabled,
-- the button is visible and it has a size on screen - a click while waiting for a bite could
-- pull the line in.
local said_vis = false
local function shake_button(ui)
    local sz = child(ui, "safezone")
    if not sz then return nil end
    local b
    for _, c in ipairs(children(sz)) do
        local cls = class_of(c)
        if cls == "ImageButton" or cls == "TextButton" then b = c; break end
    end
    if not b then return nil end
    local en, vis, zvis = prop(ui, "Enabled"), prop(b, "Visible"), prop(sz, "Visible")
    if not said_vis then
        said_vis = true
        log("shake ui reads Enabled=" .. tostring(en) .. " safezone.Visible=" .. tostring(zvis) .. " button.Visible=" .. tostring(vis))
    end
    if en == false or vis == false or zvis == false then return nil end
    if not ABS_OK then return b end           -- shake() looks for the offset on it
    local x, y, w, h = rect(b)
    if not on_screen(x, y, w, h) then return nil end
    return b
end

local last_click = { btn = nil, x = nil, y = nil, t = 0 }
local function shake(b, now)
    set_state("shake")
    hold(false)
    if now - last_click.t < CFG.SHAKE_GAP then return end
    if not ABS_OK and not calibrate(b) then
        say("shake", "could not find AbsolutePosition on the shake button - _G.__fisch.dump() shows what is there")
        return
    end
    local x, y, w, h = rect(b)
    if not on_screen(x, y, w, h) then return end   -- popping in from size 0, or gone

    -- The button pops in, growing from nothing, and jumps somewhere new after every click that
    -- lands. Clicking it mid-growth, or where it was a moment ago, is what missed: so wait for its
    -- size to settle (the same two reads running), and read it again with the cursor on it, just
    -- before the press - following it if it moved.
    local w2, h2 = select(3, rect(b))
    if not (w2 and h2) or math.abs(w2 - w) > 1 or math.abs(h2 - h) > 1 then return end   -- still growing

    -- the button still there, in the same place, a moment after a click: that click missed
    -- (by place, not by object: each lookup may hand back a new wrapper for the same button)
    if last_click.btn and math.abs(last_click.x - x) < 1 and math.abs(last_click.y - y) < 1 and now - last_click.t < 1.0 then
        S.shake_miss = S.shake_miss + 1
        if not S.inset_ok and S.shake_miss % 3 == 0 then
            S.inset_i = S.inset_i % #CFG.INSETS + 1
            log("shake clicks are not landing - trying a y inset of " .. CFG.INSETS[S.inset_i])
        end
    elseif last_click.btn then
        if not S.inset_ok then
            S.inset_ok = true
            log("shake clicks land with a y inset of " .. CFG.INSETS[S.inset_i])
        end
        S.shakes = S.shakes + 1
    end

    hold(false)
    local inset = CFG.INSETS[S.inset_i]
    local cx, cy = x + w * 0.5, y + h * 0.5 + inset
    move(cx, cy)
    task.wait(0.05)
    for _ = 1, 3 do
        -- where it is now, with the cursor already there
        local nx, ny, nw, nh = rect(b)
        if not on_screen(nx, ny, nw, nh) then return end       -- gone: the shake is over
        local tx, ty = nx + nw * 0.5, ny + nh * 0.5 + inset
        if math.abs(tx - cx) <= 3 and math.abs(ty - cy) <= 3 then break end
        cx, cy, x, y = tx, ty, nx, ny
        move(cx, cy)
        task.wait(0.04)
    end
    move(cx + 1, cy + 1)          -- a move event Roblox cannot coalesce away: the hover is seen
    task.wait(0.02)
    mouse1press()
    task.wait(0.05)
    mouse1release()
    last_click.btn, last_click.x, last_click.y, last_click.t = b, x, y, tick()
end

local function bar_parts(ui)
    local bar = child(ui, "bar")
    if not bar then return nil end
    local fish = child(bar, "fish")
    local pb = child(bar, "playerbar")
    if not (fish and pb) then
        for _, c in ipairs(children(bar)) do
            local n = name_of(c):lower()
            if not fish and n:find("fish", 1, true) then fish = c end
            if not pb and n:find("player", 1, true) then pb = c end
        end
    end
    return bar, fish, pb
end

local reel_started, reel_lost_said = 0, false
local function reel(ui, now)
    if S.state ~= "reel" then
        set_state("reel")
        reel_started, reel_lost_said = now, false
        last_click.btn = nil
    end
    if now - reel_started > CFG.REEL_TIMEOUT then
        hold(false)
        if not reel_lost_said then reel_lost_said = true; log("reel open " .. CFG.REEL_TIMEOUT .. " s - letting go") end
        return
    end
    local bar, fish, pb = bar_parts(ui)
    local bx, _, bw = rect(bar)
    local fx, _, fw = rect(fish)
    local px, _, pw = rect(pb)
    if not (fx and px and bx and bw > 0) and bar and fish and pb then
        -- find the offset on the bar itself: a wide, flat strip on screen, with the player's bar
        -- and the fish inside it at the same offset
        for off = 0x60, 0x400, 4 do
            local x, y, w, h = quad(bar, off)
            if on_screen(x, y, w, h) and w > 3 * h then
                local qx, qy, qw, qh = quad(pb, off)
                local fx2, fy2, fw2, fh2 = quad(fish, off)
                if on_screen(qx, qy, qw, qh) and on_screen(fx2, fy2, fw2, fh2) and
                   qx >= x - 2 and qx + qw <= x + w + 2 and fx2 >= x - 2 and fx2 + fw2 <= x + w + 2 then
                    ABS, ABS_OK = off, true
                    pcall(writefile, "fisch_offset.txt", tostring(off))
                    log(string.format("AbsolutePosition is at 0x%x (found on the reel bar: %.0f,%.0f %.0fx%.0f)", off, x, y, w, h))
                    break
                end
            end
        end
        bx, _, bw = rect(bar)
        fx, _, fw = rect(fish)
        px, _, pw = rect(pb)
    end
    if not (fx and px and bx and bw > 0) then
        say("bar", "reel bar parts not readable (bar " .. tostring(bar) .. ", fish " .. tostring(fish) ..
            ", playerbar " .. tostring(pb) .. ")")
        return
    end
    say("bar", "playing the reel bar")
    if not held then local x, y = rest_point(); if x then move(x, y) end end

    -- The player's bar has momentum: holding speeds it up to the right, letting go to the left,
    -- and it keeps going for a while either way - steering by where it is now overshot every
    -- time. So both bars' speeds are measured (smoothed) and the decision is made on where they
    -- will be REEL_LOOKAHEAD seconds from now; near the fish the mouse only brakes.
    local fc, pc = fx + fw * 0.5, px + pw * 0.5
    local Rv = S.reelv
    if not Rv or Rv.started ~= reel_started then
        Rv = { started = reel_started, t = now, fc = fc, pc = pc, vf = 0, vp = 0 }
        S.reelv = Rv
    end
    local dt = now - Rv.t
    if dt > 0.005 then
        local a = math.min(1, dt / 0.08)          -- ~80 ms smoothing
        Rv.vf = Rv.vf + a * ((fc - Rv.fc) / dt - Rv.vf)
        Rv.vp = Rv.vp + a * ((pc - Rv.pc) / dt - Rv.vp)
        Rv.t, Rv.fc, Rv.pc = now, fc, pc
    end
    local la = CFG.REEL_LOOKAHEAD
    local err = (fc + Rv.vf * la) - (pc + Rv.vp * la)    -- > 0: the fish will be right of us
    local zone = pw * CFG.REEL_ZONE
    if err > zone then hold(true)
    elseif err < -zone then hold(false)
    else
        -- close: cancel our own drift rather than chase
        hold(Rv.vp < Rv.vf)
    end
end

-- ---------------------------------------------------------------------------------------------
-- dump and status
-- ---------------------------------------------------------------------------------------------

-- every offset where four floats read as a rectangle on the screen: which one is AbsolutePosition
local function scan_rects(inst)
    local hits = {}
    for off = 0x60, 0x400, 4 do
        local x, y, w, h = quad(inst, off)
        if on_screen(x, y, w, h) then
            hits[#hits + 1] = string.format("0x%x=%.1f,%.1f %.1fx%.1f", off, x, y, w, h)
            if #hits >= 6 then break end
        end
    end
    return table.concat(hits, "  ")
end

local GUI_CLASS = { Frame = true, ImageButton = true, TextButton = true, ImageLabel = true, TextLabel = true, ScrollingFrame = true }
local function tree(o, depth, out, pad)
    if depth < 0 or #out > 300 then return end
    for _, c in ipairs(children(o)) do
        local cls = class_of(c)
        local line = pad .. name_of(c) .. " [" .. cls .. "] " .. string.format("0x%x", c)
        local x, y, w, h = rect(c)
        if x then line = line .. string.format("  rect %.0f,%.0f %.0fx%.0f", x, y, w, h) end
        out[#out + 1] = line
        if GUI_CLASS[cls] then
            local s = scan_rects(c)
            out[#out + 1] = pad .. "    scan: " .. (s ~= "" and s or "nothing")
        end
        tree(c, depth - 1, out, pad .. "  ")
    end
end

local function dump()
    local lines = { string.format("---- fisch dump  (AbsolutePosition 0x%x, %s) ----", ABS or 0, ABS_OK and "found" or "not found") }
    local gui = player_gui()
    for _, n in ipairs({ "shakeui", "reel" }) do
        local ui = gui and child(gui, n)
        lines[#lines + 1] = "-- " .. n .. (ui and "" or " (not open)")
        if ui then tree(ui, 4, lines, "  ") end
    end
    local rod = equipped_rod() or backpack_rod()
    lines[#lines + 1] = "-- rod: " .. (rod and name_of(rod) or "none")
    pcall(writefile, "fisch_dump.txt", table.concat(lines, "\n") .. "\n")
    log("dump written to Workspace\\fisch_dump.txt")
end

local function write_status()
    local up = tick() - T0
    local text = table.concat({
        "fisch_autofish",
        string.format("uptime      %d:%02d", math.floor(up / 60), math.floor(up % 60)),
        "state       " .. S.state .. (S.paused and " (paused)" or "") .. string.format(" for %.0f s", tick() - S.state_t),
        "caught      " .. S.caught .. "  (" .. string.format("%.1f", S.caught / math.max(up / 60, 0.01)) .. " a minute)",
        "casts       " .. S.casts,
        "shakes      " .. S.shakes .. " landed, " .. S.shake_miss .. " missed, inset " .. CFG.INSETS[S.inset_i] .. (S.inset_ok and " (confirmed)" or ""),
        "offset      " .. (ABS and string.format("0x%x", ABS) or "none") .. (ABS_OK and " (found)" or ""),
        "foreground  " .. tostring(foreground()),
        "errors      " .. S.errors .. "  last: " .. S.last_err,
    }, "\n")
    pcall(writefile, "fisch_status.txt", text .. "\n")
end

-- ---------------------------------------------------------------------------------------------
-- panel: three toggles, the numbers, and teleports. Drag it by the title.
-- ---------------------------------------------------------------------------------------------

S.shake_on, S.reel_on = false, false   -- everything starts off; the panel switches it on

local LOCATIONS = {
    { name = "Totems", list = {
        { "avalanche totem", 19711, 468, 6059 },
        { "blizzard totem", 20148, 743, 5804 },
        { "blue moon totem", 2717, 141, 2480 },
        { "clearcast totem", 702.58, 252.38, 305.73 },
        { "dripstone collapse totem", 3149.58, -1100.05, 787.77 },
        { "eclipse totem", 5966.12, 274.11, 838.94 },
        { "meteor totem", -1948.15, 275.36, 230.72 },
        { "poseidon wrath totem", -3955, -555, 855 },
        { "smokescreen totem", 2790, 140, -625 },
        { "sundial totem", -1148.38, 134.5, -1075.72 },
        { "tempest totem", 34.75, 132.5, 1943.82 },
        { "windset totem", 2849.92, 178.21, 2702.83 },
        { "zeus storm totem", -4321.35, -627.72, 2686.35 },
    } },
    { name = "Aurora Totems", list = {
        { "aurora totem 1", -1813, -136.9, -3281 },
        { "aurora totem 2", -1836, -103, -3321 },
        { "aurora totem 3", -1716, -100, -3392 },
        { "aurora totem 4", -950, -232, -2751 },
        { "aurora totem 5", -1155, -329, -4366 },
        { "aurora totem 6", -1161, -345, -4922 },
        { "aurora totem 7", -934, -361, -4771 },
        { "aurora totem 8", -5120, 158, -1629 },
        { "aurora totem 9", -5502, 153, -1962 },
        { "aurora totem 10", -5219, 158, -1511 },
        { "aurora totem 11", -4508, -699, -2027 },
        { "aurora totem 12", 15, 136, 1933 },
        { "aurora totem 13", 4376, -2009, -4728 },
        { "aurora totem 14", 4453, -2710, -4600 },
        { "aurora totem 15", 4376, -2706, -4749 },
        { "aurora totem 16", -4061, -561, 1529 },
        { "aurora totem 17", -3552, -550, 924 },
        { "aurora totem 18", -4231, -627, 2664 },
        { "aurora totem 19", -3952, -673, 2421 },
        { "aurora totem 20", -5018, -589, 1762 },
        { "aurora totem 21", -9068, -2346, 1050 },
        { "aurora totem 22", -8972, -2272, 150 },
        { "aurora totem 23", -8560, -2881, 847 },
        { "aurora totem 24", -8700, -2838, 786 },
        { "aurora totem 25", -9084, -2799, 860 },
        { "aurora totem 26", -8635, -3091, 504 },
        { "aurora totem 27", -8905, -3171, 464 },
        { "aurora totem 28", -7638, -4242, 426 },
        { "aurora totem 29", -8406, -4250, 148 },
        { "aurora totem 30", -8279, -4252, 596 },
        { "aurora totem 31", -8699, -4196, -521 },
        { "aurora totem 32", -8685, -4243, -313 },
        { "aurora totem 33", -8862, -4303, -892 },
        { "aurora totem 34", -8904, -4300, -8784 },
        { "aurora totem 35", -2885, 142, -2258 },
        { "aurora totem 36", -2819, -286, -2431 },
        { "aurora totem 37", -2437, -267, -2557 },
        { "aurora totem 38", -2584, -309, -3109 },
        { "aurora totem 39", -2570, -310, -2928 },
        { "aurora totem 40", -1934, -302, -3349 },
        { "aurora totem 41", -1885, 354, 198 },
        { "aurora totem 42", -3393, -1974, 3887 },
        { "aurora totem 43", -2941, -1954, 4252 },
        { "aurora totem 44", -4418, -11167, 1595 },
        { "aurora totem 45", -106, -566, 1578 },
        { "aurora totem 46", -87, -724, 1154 },
        { "aurora totem 47", 908, -620, 616 },
        { "aurora totem 48", 1007, -596, 1212 },
        { "aurora totem 49", 1357, -614, 2357 },
        { "aurora totem 50", 6026, 258, 589 },
        { "aurora totem 51", 5944, 154, 453 },
        { "aurora totem 52", -3105, -756, 1667 },
        { "aurora totem 53", -3222, -768, 1866 },
        { "aurora totem 54", 3038, -1102, 431 },
        { "aurora totem 55", 4630, -1083, 835 },
        { "aurora totem 56", 4311, -1086, 1045 },
        { "aurora totem 57", 2999, -1126, 2046 },
        { "aurora totem 58", 2383, -1011, 747 },
        { "aurora totem 59", 20260, 273, 5596 },
        { "aurora totem 60", 19862, 424, 5390 },
        { "aurora totem 61", 20016, 900, 5675 },
        { "aurora totem 62", 20067, 1226, 5413 },
        { "aurora totem 63", 21236, 617, 3561 },
        { "aurora totem 64", 21779.2, 132.7, 3909.5 },
        { "aurora totem 65", -711, -864, -9 },
        { "aurora totem 66", -790, -812, -316 },
        { "aurora totem 67", -265, -897, -99 },
        { "aurora totem 68", 1523, -802, -238 },
        { "aurora totem 69", 790, -716, -14 },
        { "aurora totem 70", 567, 281, -2121 },
        { "aurora totem 71", 285, 211, -2233 },
        { "aurora totem 72", -2796, 208, 1542 },
        { "aurora totem 73", 2884, 136, 2705 },
        { "aurora totem 74", 2794, 89, 2498 },
        { "aurora totem 75", 1821, -324, -2440 },
    } },
    { name = "NPCs", list = {
        { "admin relic dealer", -2970.22, -1029.79, 5946.76 },
        { "appraiser", 447.39, 150.55, 207.13 },
        { "apprentice archaelogist", 6082.42, 194.98, 283.13 },
        { "astronomer vega", -1957.62, 227, -463.49 },
        { "black market dealer", -3052.81, -1029.4, 6065.85 },
        { "bubble mermaid", -3550, 130, 568 },
        { "calyra", -3822, -1280, 500 },
        { "companion dealer", -3010.85, -1027.17, 6121.31 },
        { "crazy cat lady", 2014.43, -644.86, 2464.13 },
        { "daily shop", 223.83, 138.9, 22.29 },
        { "dave", 1077.79, 306.4, -1217.73 },
        { "divine hunter", -1522.58, 131.33, 2191.83 },
        { "doug", -1863.29, 224.69, -604.36 },
        { "dr monty", -10271.9, -494.02, 989.27 },
        { "dr. crookspire", -1921.43, 227, -532.82 },
        { "drowned appraiser", 3169.53, -1099.74, 775.32 },
        { "fabulous deity", -4307.02, -11003, 3657.76 },
        { "glorp", -1523.47, 141, 336.26 },
        { "keeper warden", 661.68, -753.54, -463.88 },
        { "lyren", 998.34, -2600.47, 1627.42 },
        { "marc merchant (moosewood)", 463.36, 150.53, 235.97 },
        { "merlin", -960, 222, -988 },
        { "nick", 1266.13, -724.24, 1289.97 },
        { "plagued reaper", -2674.58, -317.17, -2288.41 },
        { "ro red (tryhard rod)", -1920.76, 262.82, 115.06 },
        { "scrip vender", -2921.05, -1029.19, 5957.09 },
        { "shady appraiser", -3029.78, -1029.4, 6057.22 },
        { "shady bait dealer", -2941.66, -1029.71, 6054.81 },
        { "shady merchant", -3052.32, -1029.4, 6042.76 },
        { "shady rare goods dealer", -2976.33, -1023.21, 6043.48 },
        { "shady rod dealer", -2931.75, -1029.04, 6105.41 },
        { "sprout", -2581.32, 156.06, -2077.97 },
        { "treasure appraiser", 8192.86, 230.87, -17174.3 },
        { "weekly shop", 3004.32, 1637.95, 899.38 },
        { "wind master", 19945.9, 1211.92, 5280.43 },
    } },
    { name = "Crates", list = {
        { "aquatic tackle box", -432.49, -2388.51, -12670.6 },
        { "bait crate", 376.13, 137.1, 282.75 },
        { "coral geode", -1643.36, -213.68, -2850.72 },
        { "metal strongbox", 3154.78, -1100, 780.49 },
        { "quality bait crate", -220, 134, 1890 },
        { "tropical bait crate", -1045.48, 202.84, -1099.55 },
        { "volcanic geode", -5081.86, 145.87, -1509.32 },
    } },
    { name = "Event Places", list = {
        { "caustic hollow", -14521.4, 145.56, -9662 },
        { "caustic mansion", -15023.1, 267.68, -9905.15 },
        { "ritual", -15095.6, 146.7, -9624.52 },
        { "scarecrow's maze", -14877.1, 181.01, -9485.93 },
        { "webridden cavern", -14981.5, 147.61, -9831.89 },
    } },
    { name = "Crab Cages", list = {
        { "coral crab cage", 2543.26, -1098.42, 842.7 },
        { "crab cage", 474.58, 150.5, 235.19 },
        { "golden crab cage", 3122.27, -1126.79, 1955.42 },
        { "reinforced crab cage", 21337.8, 251.81, 3879.77 },
        { "relic crab cage", 2919.32, -1102.42, -75.87 },
    } },
    { name = "Event NPCs", list = {
        { "beatrix", -14705.1, 155.46, -9643.93 },
        { "doomsekkar", -14994.4, 146.64, -9660.05 },
        { "frightful appraiser", -14557.3, 146.97, -9607.07 },
        { "frightful merchant", -14575.2, 145.64, -9608.6 },
        { "pumpkin king", -14573.4, 145.75, -9673.96 },
        { "webby winston", -15066.9, 145.49, -9975.1 },
        { "youngster goblin", -14752, 148.54, -9834 },
    } },
}

-- More places, from Shoobie-code/fisch's lists: zones and hubs, points of interest, rods with a fixed spot
table.insert(LOCATIONS, { name = "Hub: Locations", list = {
        { "Above The Clouds", 1489.51, 2601.67, -1718.3 },
        { "Abyssal Zenith", -13541, -11048, 154 },
        { "Ancient Archives", -3162.13, -747.21, 1701.17 },
        { "Ancient Isle", 6069, 224, 262 },
        { "Apollo's Song of Light", -8707.94, -2904.53, 731.84 },
        { "Astral Observatory", 842.98, -2603.62, 1619.96 },
        { "Atlantean Storm", -3866, 154, 445 },
        { "Atlantis", -4343.68, -602.31, 1813.18 },
        { "Bellona's Frenzy of War", -8667.92, -2361.67, 757.59 },
        { "Blue Moon - First Sea", 2685.14, 141.51, 2582.13 },
        { "Boreal Hollow", 848.32, -2603.62, 1610.78 },
        { "Boreal Pines", 21575.6, 141.52, 4137.94 },
        { "Brine Pool", -1795, -142, -3331 },
        { "Calm Zone", -4336, -11174, 3704 },
        { "Carrot Garden", 3732, -1127, -1080 },
        { "Castaway Cliff", 384.89, 207.49, -1818.55 },
        { "Challenger's Deep", -775, -3283, -675 },
        { "Collapsed Ruins", 3136, -1102, 1611 },
        { "Coral Bastion", 2544, -1098, 849 },
        { "Crimson Cavern", -1035, -360, -4800 },
        { "Crowned Ruins", 3126, -1126, 2039 },
        { "Cryogenic Canal", 19956.8, 635.28, 5717.43 },
        { "Crystal Cove", 1364, -612, 2472 },
        { "Cultist Lair", 4476, -1997, -4676 },
        { "Cursed Isle", 1860, 135, 1210 },
        { "Desolate Deep", -1512.57, -234.7, -2862.52 },
        { "Drylands", -6455.02, 204.97, -1539.97 },
        { "Enchanted Crevice", 681.17, -754.03, -472.44 },
        { "Ethereal Abyss", -3792.98, -564.27, 1828.82 },
        { "Everturn Forest", 2426.63, 149.82, -2500.87 },
        { "Forsaken Shores", -2584.73, 167.55, 1608.71 },
        { "Frigid Cavern", 19845.5, 440.16, 5633.05 },
        { "Glacial Grotto (Cave)", 20008, 1035.2, 5699.71 },
        { "Glacial Grotto (Summit)", 19990.9, 1142.24, 5550.1 },
        { "Gloomy Crevice", 134.63, -2512.3, -11836.6 },
        { "Grand Reef", -3577.17, 162.33, 503.51 },
        { "Hades' Underworld of Indefinite", -8649, -4243, 434 },
        { "Keepers Altar", 1296, -805, -296 },
        { "Kraken Lair", -4380.05, -996.26, 2052.43 },
        { "Living Garden", -2401, -316, -2771 },
        { "Lost Jungle", -2707.33, 158.2, -2060.92 },
        { "Lower Deep", 1708.02, -2805.78, -11772.1 },
        { "Luminescent Cavern", -1013, -313, -4038 },
        { "Mineshaft", -684, -864, -74 },
        { "Moosewood", 486.56, 157.84, 268.3 },
        { "Mushgrove", 2697.28, 140.33, -756.55 },
        { "Nectar Den", -2066, -327, -3125 },
        { "Northern Expedition", 19512.7, 132.67, 5303.36 },
        { "Obsidian Pocket", 141.56, -6551, 48.81 },
        { "Olympian Fissure", -8830, -4243, -147 },
        { "Outer Deep", -436.9, -2367.8, -12685.3 },
        { "Overgrowth Caves", 20269.8, 273.2, 5557.13 },
        { "Poseidon's Storm of Floods", -8985.58, -3191.38, 780.49 },
        { "Poseidons Temple", -3950, -550, 968 },
        { "Roslit Bay", -1486.62, 142.08, 704.4 },
        { "Roslit Volcano", -1893, 173, 314 },
        { "Scoria Reach", -5108.09, 145.09, -1456.06 },
        { "Skycrest", 2779.58, 1621.31, 830.14 },
        { "Snowburrow", 2784, 141, 2557 },
        { "Snowcap Island", 2687.71, 160.31, 2385.95 },
        { "Sunken Depths", -4938.35, -595.12, 1840.24 },
        { "Sunken Reliquary", 2950, -1102, 443 },
        { "Sunstone Island", -986.11, 208.64, -1074.15 },
        { "Terrapin", -132.3, 188.15, 1952.43 },
        { "The Deep", 385.44, -2238.58, -11910.6 },
        { "The Depths", 608, -712, 1230 },
        { "Tidefall", 3133.05, -1081.1, 788.25 },
        { "Toxic Grove", -2745, -317, -2272 },
        { "Treasure Island", 8284, 195, -17093 },
        { "Veil of the Forsaken", -2361, -11184, -7073 },
        { "Vertigo", -107, -515, 1143 },
        { "Volcanic Vents", -3390, -2263, 3822 },
        { "Zeus' Sanctuary", -4294, -627, 2655 },
        { "Zeus's Thunder of Chaos", -8878, -3539, 594 },
    } })
table.insert(LOCATIONS, { name = "Hub: Points of interest", list = {
        { "Abaia's Chamber - Skycrest", 3412.14, 1562.36, 950.12 },
        { "Abyssal Zenith - Astral Cavern", -13802.8, -11569.7, 122.17 },
        { "Aether", -146, -654, 966 },
        { "Appraisal (Tidefall)", 3158, -1099, 771 },
        { "Birch Cay", 1747.19, 143, -2449.68 },
        { "Blue crystal", 20125, 211, 5449 },
        { "Boreal Pines - Astral Cavern", 21878.3, -148.6, 4246.41 },
        { "Bubble Mermaid", -3550, 130, 568 },
        { "button1", 400, 135, 265 },
        { "button2", 5506, 147, -315 },
        { "button3", 2930, 281, 2594 },
        { "button4", -1715, 149, 737 },
        { "button5", -2566, 181, 1353 },
        { "Challangers Deep (Pool)", 747, -3353, -1566 },
        { "Claypans - Drylands", -5765.58, 137, -915.12 },
        { "Cryogenic Canal - Astral Cavern", -1859.83, -262.67, 4012.63 },
        { "Detonator's Rest", -1409, -902, -3493 },
        { "Door", 19986, 906, 5453 },
        { "Earmark Island", 1272.97, 140.1, 542.9 },
        { "Everturn Forest - Astral Cavern", 2523.82, -126.48, -2498.27 },
        { "Forgotten Temple", -5286, -1759, -10000 },
        { "Forsaken Shores Pond", -2665.24, 167.5, 1754.01 },
        { "Ghosts Tavern", 268, 800, -6864 },
        { "Green Crystal", 19873, 448, 5556 },
        { "Haddock Rock", -464.45, 160.01, -454.63 },
        { "Hall of Whispers", 4346.09, -2234.82, -4679.79 },
        { "Harvesters Spike", -1254.81, 137.25, 1556.77 },
        { "Hawaii", -1346, 130, -39935 },
        { "Heaven", 1459.48, 8876.25, -1717.73 },
        { "Inner Tidefall Castle", 4317.5, -1100.92, 919.84 },
        { "Merlin", -960, 222, -988 },
        { "Mermaid Cove", -3870, -1286, 505 },
        { "Meteor", 5733, 184, 625 },
        { "Mossjaw Rest", -4928.72, -1792.56, -10168.7 },
        { "Obsidian Trench", -1668.61, -12350.8, 62.88 },
        { "Oscars Locker", 213.22, -394.45, 3534.9 },
        { "Passage of Oaths", 4284.83, -2483.02, -4680.36 },
        { "Rodtp", 19227, 395.9, 6028.3 },
        { "Scoria Mines", -4544.53, -707.31, -2032.08 },
        { "Shady Bazaar", -2941, -1029, 6178 },
        { "Snowcap Island - Astral Cavern", 2637.73, -410.04, 2521.67 },
        { "Statue of Sovereignty", 17.04, 166.1, -1048.24 },
        { "Sunken Reservoir", -6627.04, 158.68, -1247.25 },
        { "Thalassar's Secret", 2897, -579, 1177 },
        { "The Arch", 1005.03, 131.32, -1241.27 },
        { "The Laboratory", -1934, 224, -449 },
        { "The Sanctum", 4373.79, -2710.14, -4673.39 },
        { "Toucan", -2933, 275, -2156 },
        { "Trident Temple", -1480, -225, -2242 },
        { "Underground Music Venue", 2037, -644, 2474 },
        { "Volcanic Depths (Pool)", -3345, -2026, 4084 },
        { "Yellow Crystal", 19488, 335, 5553 },
        { "Zeus's Rod Room", -4294, -627, 2655 },
    } })
table.insert(LOCATIONS, { name = "Hub: Rods", list = {
        { "Abyssal Specter Rod", -3802.18, -566.77, 1862.8 },
        { "Arctic Rod", 19575, 135, 5310 },
        { "Aurora Rod", -144.04, -515.3, 1144.86 },
        { "Avalanche Rod", 19771, 415, 5415 },
        { "Carbon Rod", 463.36, 150.53, 235.97 },
        { "Challenger's Rod", 740, -3350, -1530 },
        { "Champions Rod", -4259.02, -603.21, 1870.9 },
        { "Cinder Block Rod", -1970, 260, -530 },
        { "Crystalized Rod", 20296, 272, 5463 },
        { "Depthseeker Rod", -4459.58, -605.66, 1866.08 },
        { "Destiny Rod", 985.49, 131.32, -1234.51 },
        { "Ethereal Prism Rod", -4360, -11170, 3710 },
        { "Fast Rod", 463.36, 150.53, 235.97 },
        { "Flimsy Rod", 470, 151, 232 },
        { "Fortune Rod", -1499.41, 141.43, 750.98 },
        { "Free Spirit Rod", -314, -864, -81 },
        { "Fungal Rod", 2588.54, 132, -725.91 },
        { "Hades' Soul Scythe", -7682.7, -4260.6, 363 },
        { "Kings Rod", 1383.54, -807.31, -303.38 },
        { "Kraken Rod", -4404.55, -996.26, 2053.8 },
        { "Long Rod", 463.36, 150.53, 235.97 },
        { "Lucky Rod", 463.36, 150.53, 235.97 },
        { "Magma Rod", -1850, 165, 160 },
        { "Magnet Rod", -234.2, 141.85, 1955.3 },
        { "Nocturnal Rod", -144.04, -515.3, 1144.86 },
        { "Phoenix Rod", 5963.22, 269.62, 851.75 },
        { "Plastic Rod", 463.36, 150.53, 235.97 },
        { "Poseidon Rod", -4078.5, -558.23, 895.9 },
        { "Rapid Rod", -1499.41, 141.43, 750.98 },
        { "Reinforced Rod", -990, -245, -2695 },
        { "Rod of the Depths", 1705.52, -902.53, 1441.27 },
        { "Rod of the Exalted One", 2232.82, -804.18, 1032.22 },
        { "Rod of the Zenith", -13629.6, -11035.2, 349.12 },
        { "Scurvy Rod", -2825, 215, 1515 },
        { "Steady Rod", -1499.41, 141.43, 750.98 },
        { "Stone Rod", 5500, 143, -316 },
        { "Summit Rod", 20213.5, 736.7, 5713 },
        { "Sunken Rod", -2494, 133.1, 1551.27 },
        { "Tempest Rod", -4931.56, -595.24, 1852.3 },
        { "Training Rod", 465, 150, 230 },
        { "Trident Rod", -1483, -225, -2207 },
        { "Volcanic Rod", -3175, -2030, 4020 },
        { "Zeus Rod", -4275.86, -627.11, 2659.67 },
    } })

-- The panel is a 256-UI window (menu key P by default). It draws and handles input itself;
-- this section only declares the controls and feeds them the script's numbers.
local UI_URL = "https://raw.githubusercontent.com/ars240/256-UI/refs/heads/main/src.lua"
local Lib = loadstring(game:HttpGet(UI_URL))() or UI256

local TP = { cat = 1, loc = 1, busy = false, msg = "" }
local loc_dd                       -- the place dropdown
local PLACES = {}                  -- dropdown label -> { category, place }

-- Every place in one searchable list: "name  [Category]"
local function place_names()
    PLACES = {}
    local names = {}
    for ci, c in ipairs(LOCATIONS) do
        for li, e in ipairs(c.list) do
            local label = e[1] .. "  [" .. c.name .. "]"
            PLACES[label] = { ci, li }
            names[#names + 1] = label
        end
    end
    return names
end

local function stat_state()
    if S.paused and not (S.shake_on or S.reel_on) then return "paused" end
    if not foreground() then return "Roblox not in front" end
    return S.state
end

-- ---------------------------------------------------------------------------------------------
-- Extras: treasure chests, waypoint markers, instant reel, Discord webhook, coordinates, tuning
-- (ideas from Shoobie-code/fisch, rewritten for this script's helpers and this Calamity)
-- ---------------------------------------------------------------------------------------------

local HttpService = game:GetService("HttpService")

local EX = {
    esp_hz = 30, esp_outline = false,
    wp_on = false, wp_fishing = false, wp_dist = true, wp_size = 7, wp_text = 14, wp_max = 0,
    chest_on = false, chest_dist = true, chest_size = 8, chest_text = 14, chest_max = 0,
    ir_on = false, ir_speed = 50, ir_loss = 0,
    hook_on = false, hook_url = "", hook_start = true, hook_stats = true, hook_every = 300,
}

local function my_pos()
    local ch = character()
    local root = ch and child(ch, "HumanoidRootPart")
    local p = root and prop(root, "Position")
    if p and p.X then return p end
    return nil
end

-- teleport on its own thread: wait for a running one, go, wait for it to land
local function go_to(x, y, z, quiet)
    spawn(function()
        local t0 = tick()
        while isteleporting() and tick() - t0 < 4 do task.wait(0.03) end
        if not teleport(Vector3.new(x, y, z)) then
            if not quiet then log("teleport refused") end
            return
        end
        t0 = tick()
        while isteleporting() and tick() - t0 < 4 do task.wait(0.03) end
        if not quiet then log(string.format("teleported to %.0f, %.0f, %.0f", x, y, z)) end
        set_state("start")
    end)
end

-- ---- markers: a square and a label on every point of a list ----
--
-- One loop projects every marker ~30 times a second (draw.WorldToScreen); the lists are re-read
-- on a timer, not per frame.

local have_w2s = draw and type(draw.WorldToScreen) == "function"
local MARKERS = {}

local function marker_set(color, text_color, opt, collect, every)
    local M = { objs = {}, list = {}, scan_t = -99, on = false, scanning = false, next_draw = 0, color = color }
    -- A marker is a ring with a dot in it and a tag above: a dark pill with a coloured edge. Its
    -- drawing objects are made a few per tick (74 waypoints at once was a visible hitch).
    local function grow(n)
        local made = 0
        while #M.objs < n and made < 4 do
            local ring = Drawing.new("Circle")
            ring.NumSides, ring.Filled, ring.Thickness, ring.Color, ring.Transparency, ring.ZIndex = 24, false, 2, M.color, 1, 6
            local dot = Drawing.new("Circle")
            dot.NumSides, dot.Filled, dot.Color, dot.Transparency, dot.ZIndex = 10, true, M.color, 1, 6
            local bg = Drawing.new("Square")
            bg.Filled, bg.Color, bg.Transparency, bg.ZIndex = true, Color3.fromRGB(14, 16, 22), 0.85, 7
            local bar = Drawing.new("Square")
            bar.Filled, bar.Color, bar.Transparency, bar.ZIndex = true, M.color, 1, 8
            local tx = Drawing.new("Text")
            tx.Color, tx.Center, tx.Outline, tx.ZIndex = text_color, false, EX.esp_outline, 9
            for _, d in ipairs({ ring, dot, bg, bar, tx }) do d.Visible = false end
            M.objs[#M.objs + 1] = { ring = ring, dot = dot, bg = bg, bar = bar, tx = tx, vis = false }
            made = made + 1
        end
    end
    local function show(o, v)
        if o.vis == v then return end
        o.vis = v
        o.ring.Visible, o.dot.Visible, o.bg.Visible, o.bar.Visible, o.tx.Visible = v, v, v, v, v
    end
    local function hide_from(i)
        for k = i, #M.objs do show(M.objs[k], false) end
    end
    function M.set(on)
        M.on = on and true or false
        M.scan_t = -99
        if not M.on then hide_from(1) end
    end
    -- the accent follows the window's theme
    function M.recolor(c)
        if M.color == c then return end
        M.color = c
        for _, o in ipairs(M.objs) do o.ring.Color, o.dot.Color, o.bar.Color = c, c, c end
    end
    function M.set_outline(v)
        for _, o in ipairs(M.objs) do o.tx.Outline = v end
    end
    -- the list is read on its own thread (the collectors yield now and then), never in the draw tick
    local function rescan()
        M.scanning = true
        spawn(function()
            local ok, list = pcall(collect)
            if ok and type(list) == "table" then
                for _, m in ipairs(list) do m.x, m.y, m.z = m.pos.X, m.pos.Y, m.pos.Z end
                M.list = list
            end
            M.scanning = false
        end)
    end
    function M.tick(now, me)
        if not M.on or not have_w2s then return end
        if now < M.next_draw then return end              -- the draw rate is a setting, not the loop's pace
        M.next_draw = now + 1 / math.max(5, EX.esp_hz)
        if not M.scanning and now - M.scan_t >= every() then
            M.scan_t = now
            rescan()
        end
        local list = M.list
        local n = #list
        grow(n)
        local size, tsize, maxd, showd = EX[opt.size], EX[opt.text], EX[opt.max], EX[opt.dist]
        local th = tsize + 9                              -- the pill's height
        local maxd2 = maxd * maxd
        local mx, my, mz
        if me then mx, my, mz = me.X, me.Y, me.Z end
        local w2s = draw.WorldToScreen
        local objs = M.objs
        local top = math.min(n, #objs)
        for i = 1, top do
            local o, m = objs[i], list[i]
            local shown = false
            local d2
            if mx then
                local dx, dy, dz = m.x - mx, m.y - my, m.z - mz
                d2 = dx * dx + dy * dy + dz * dz
            end
            if not (maxd > 0 and d2 and d2 > maxd2) then
                local x, y = w2s(m.x, m.y, m.z)
                if x then
                    local dd = (showd and d2) and math.floor(math.sqrt(d2) / 5) * 5 or nil   -- steps of 5: fewer text changes
                    local changed = false
                    if o.name ~= m.name or o.d ~= dd or o.tsize ~= tsize then
                        local label = dd and string.format("%s  %dm", m.name, dd) or m.name
                        o.tx.Text, o.tx.Size = label, tsize
                        o.tw = #label * tsize * 0.55 + 18
                        o.bg.Size = Vector2.new(o.tw, th)
                        o.bar.Size = Vector2.new(3, th)
                        o.name, o.d, o.tsize = m.name, dd, tsize
                        changed = true
                    end
                    if o.size ~= size then
                        o.ring.Radius, o.dot.Radius = size, math.max(2, size * 0.3)
                        o.size = size
                        changed = true
                    end
                    if changed or o.x ~= x or o.y ~= y then
                        o.x, o.y = x, y
                        local c = Vector2.new(x, y)
                        o.ring.Position, o.dot.Position = c, c
                        local tx_, ty_ = x - o.tw / 2, y - size - th - 5
                        if ty_ < 2 then ty_ = y + size + 5 end          -- no room above: below the ring
                        local p = Vector2.new(tx_, ty_)
                        o.bg.Position, o.bar.Position = p, p
                        o.tx.Position = Vector2.new(tx_ + 10, ty_ + (th - tsize) / 2 - 1)
                    end
                    show(o, true)
                    shown = true
                end
            end
            if not shown then show(o, false) end
        end
        hide_from(top + 1)
    end
    function M.destroy()
        for _, o in ipairs(M.objs) do
            for _, d in ipairs({ o.ring, o.dot, o.bg, o.bar, o.tx }) do pcall(function() d:Remove() end) end
        end
        M.objs = {}
    end
    MARKERS[#MARKERS + 1] = M
    return M
end

-- waypoints: workspace.zones.player (and .fishing) - a part per zone, its name in a "zonename" value
local function collect_zones()
    local out, seen = {}, {}
    local zones = child(workspace, "zones")
    for _, group in ipairs(EX.wp_fishing and { "player", "fishing" } or { "player" }) do
        for zi, z in ipairs(children(child(zones, group))) do
            if zi % 20 == 0 then task.wait() end
            local p = prop(z, "Position")
            if p and p.X then
                local nv = child(z, "zonename")
                local nm = nv and prop(nv, "Value")
                if type(nm) ~= "string" or nm == "" then nm = name_of(z) end
                if not seen[nm] then seen[nm] = true; out[#out + 1] = { name = nm, pos = p } end
            end
        end
    end
    return out
end

-- treasure chests: workspace.world.chests and .ActiveChestsFolder
local function collect_chests()
    local out = {}
    local world = child(workspace, "world")
    for _, folder in ipairs({ child(world, "chests"), child(world, "ActiveChestsFolder") }) do
        for _, c in ipairs(children(folder)) do
            local p = prop(c, "Position")
            if p and p.X then out[#out + 1] = { name = "Chest", pos = p } end
        end
    end
    return out
end

local WP = marker_set(Color3.fromRGB(122, 134, 255), Color3.fromRGB(245, 245, 250),
    { size = "wp_size", text = "wp_text", max = "wp_max", dist = "wp_dist" }, collect_zones, function() return 60 end)
local CH = marker_set(Color3.fromRGB(122, 134, 255), Color3.fromRGB(245, 245, 250),
    { size = "chest_size", text = "chest_text", max = "chest_max", dist = "chest_dist" }, collect_chests, function() return 1.5 end)

-- ---- chest teleports and the collect-all run ----

local RUN = { active = false, visited = 0 }
local chest_cycle = 0

local function chest_tp_nearest()
    local list = collect_chests()
    if #list == 0 then log("no treasure chests up right now"); return end
    local me, best, bd = my_pos(), nil, nil
    for _, c in ipairs(list) do
        local d = me and (c.pos - me).Magnitude or 0
        if not bd or d < bd then best, bd = c, d end
    end
    go_to(best.pos.X, best.pos.Y + 3, best.pos.Z)
end

local function chest_tp_next()
    local list = collect_chests()
    if #list == 0 then log("no treasure chests up right now"); return end
    chest_cycle = chest_cycle % #list + 1
    local c = list[chest_cycle]
    go_to(c.pos.X, c.pos.Y + 3, c.pos.Z)
end

local function chest_run_stop()
    if not RUN.active then return end
    RUN.active = false
    log("chest run stopped (" .. RUN.visited .. " visited)")
end

local function chest_run_start()
    if RUN.active then return end
    local list = collect_chests()
    if #list == 0 then log("chest run: no chests found"); return end
    RUN.active, RUN.visited = true, 0
    hold(false)
    log("chest run: visiting " .. #list .. " chest(s)")
    spawn(function()
        for _, c in ipairs(list) do
            if not RUN.active then break end
            local t0 = tick()
            while isteleporting() and tick() - t0 < 4 do task.wait(0.03) end
            if teleport(c.pos) then
                t0 = tick()
                while isteleporting() and tick() - t0 < 4 do task.wait(0.03) end
                task.wait(0.15)
                tap(0x45, 0.15)             -- E: open it
                RUN.visited = RUN.visited + 1
                task.wait(0.2)
            end
        end
        if RUN.active then log("chest run done: " .. RUN.visited .. " chest(s) visited") end
        RUN.active = false
        set_state("start")
    end)
end

-- ---- instant reel ----
--
-- The reel's speed lives in a table of the game's own Luau scripts (progressefficiency, and a
-- loss multiplier). gc.find locates the tables and gc.set writes the numbers - nothing is fired at
-- the server, but it is a change to the game's data: off by default. It is applied each time a reel
-- opens, because the game may build a fresh table per reel. Nothing is written while Safe Mode is on.

local IR = { on = false, reel = false, busy = false, n = 0, combo = 0, orig = {} }

-- The reel (the game's ReelController, read from Workspace\fisch_src) does not keep its speed in a
-- field you can set: every frame it rebuilds reel.progressefficiency and reel.progressLossMultiplier
-- from reel._active_modifiers[name].add / .force / .force_final, so a write to the field is gone one
-- frame later. The number that sticks is the first entry of the modifier's array:
--   _active_modifiers.progressefficiency.add[1]      -> the speed
--   _active_modifiers.progressLossMultiplier.add[1]  -> the loss
-- Verified live on 2026-11-07 (probe 4): writing 40 there made the reel finish in seconds.
--
-- gc.geti / gc.seti cannot read these arrays on this build (they answer nil / "no such index"),
-- so the number is written raw: Luau Table +8 = sizearray, +0x18, +0x20 or +0x28 = the array, by build (see ir_ptr); its first TValue is
-- 16 bytes, the double at +0 and the type tag at +0xC (3 = number). Anything else there (the game
-- keeps some modifiers as NumberValue Instances) is left alone. The layout is checked against
-- gc.len first, and nothing is written if it does not match.
--
-- gc.find locates the live reel table only with some keys, and only a reel that is open and
-- active: a finished reel lingers for about a second. The searches rotate through keys known to
-- work (a repeated search can hand back last reel's table).
local IR_CANDS = {
    { "reel_progress" }, { "OnBarBounce" }, { "OnFishMove" }, { "OnRenderStep" }, { "PreMinigameEnd" },
    { "OnSlash" }, { "logicTweens" }, { "BuildSnapshot" }, { "OnLogicStep" }, { "barPosition", "barSize" },
}
local IR_KINDS = { "add", "force", "force_final" }

local function ir_rd(ty, a)
    local ok, v = pcall(memory_read, ty, a)
    if ok then return v end
    return nil
end

-- the address of the array's first TValue, when it is a live one-or-more entry array of plain numbers
-- (nil and the reason otherwise)
--
-- Where a Luau Table keeps its array pointer changes with the Roblox build (+0x28 on 5a21b, +0x18 on f0ea5da, +0x20 on 4ea8e854 -
-- read live on the modifier arrays on 2026-11-11: +0x18 held float data, +0x20 the array, +0x28 the shared empty node). Reading
-- the old +0x28 there gave "not a number (tag 0)" and the reel went unpatched. So the candidates are tried: the right one points at
-- TValues whose tag (+0xC) is 3 (number); the others are not a heap pointer, the empty node (tag 0) or something else that is not
-- a number. The one that worked is tried first the next time.
local IR_ARR_OFFSETS = { 0x20, 0x18, 0x28 }
local function ir_ptr(arr)
    -- gc.len is not trusted: probe 6 saw it answer 0 for an array whose raw sizearray was 1 and whose
    -- first entry was a good number (that read as "empty" and the reel went unpatched). gc.len only
    -- says whether the table is still alive; the raw size and the entry's tag decide.
    local ok, len = pcall(gc.len, arr)
    if not ok or type(len) ~= "number" then return nil, "table gone" end
    local size = ir_rd("int", arr + 8)
    if type(size) ~= "number" or size < 1 or size > 64 then return nil, "empty" end
    local why = "no array"
    local order = { IR.aoff }
    for _, off in ipairs(IR_ARR_OFFSETS) do if off ~= IR.aoff then order[#order + 1] = off end end
    if not IR.aoff then order = IR_ARR_OFFSETS end
    for _, off in ipairs(order) do
        local ptr = ir_rd("uint64", arr + off)
        if type(ptr) == "number" and ptr >= 0x10000 and ptr < 0x7FFFFFFFFFFF then
            local tag = ir_rd("int", ptr + 0xC)
            local v = ir_rd("double", ptr)
            if tag == 3 and type(v) == "number" and v == v and math.abs(v) < 1e9 then
                if IR.aoff ~= off then
                    IR.aoff = off
                    log(string.format("instant reel: the array pointer is at Table +0x%X on this build", off))
                end
                return ptr
            end
            why = "not a number (tag " .. tostring(tag) .. " at +0x" .. string.format("%X", off) .. ")"
        end
    end
    return nil, why
end

local function ir_arr_set(arr, want)
    local ptr, why = ir_ptr(arr)
    if not ptr then return false, why end
    local cur = ir_rd("double", ptr)
    if type(cur) ~= "number" then return false, "unreadable" end
    local id = tostring(arr)
    if IR.orig[id] == nil then IR.orig[id] = { arr = arr, v = cur } end
    if cur == want then return true, "ok" end
    if pcall(memory_write, "double", ptr, want + 0.0) then return true, "ok" end
    return false, "write failed"
end

-- one modifier table: how many numbers in it are now what was asked for (nil when it is gone);
-- notes[name.kind] says what happened to each array
local function ir_patch(addr, notes)
    local okr, fields, types = pcall(gc.read, addr)
    if not okr or type(fields) ~= "table" then return nil end
    local n = 0
    for _, spec in ipairs({ { "progressefficiency", EX.ir_speed }, { "progressLossMultiplier", EX.ir_loss } }) do
        local name, want = spec[1], spec[2]
        if types[name] == "table" then
            local okk, kf, kt = pcall(gc.read, fields[name])
            if okk and type(kf) == "table" then
                for _, kind in ipairs(IR_KINDS) do
                    if kt[kind] == "table" then
                        local ok, why = ir_arr_set(kf[kind], want)
                        if ok then n = n + 1 end
                        if notes then notes[#notes + 1] = name .. "." .. kind .. ": " .. tostring(why) end
                    end
                end
            end
        elseif notes then
            notes[#notes + 1] = name .. ": " .. tostring(types[name] or "missing")
        end
    end
    return n
end

-- The open reel's table and its _active_modifiers table. A reel is live when it has a progress
-- between 0 and 100 and its modifier table still has progressefficiency (a finished reel has its
-- modifiers cleared). `active` is NOT required: it only turns true about two seconds into the reel,
-- and waiting for it cost those two seconds.
local function ir_find_reel(keys)
    local ok, addrs = pcall(gc.find, table.unpack(keys))
    if not ok or type(addrs) ~= "table" then return nil, "search failed" end
    local seen, last = 0, "no reel tables"
    for _, a in ipairs(addrs) do
        local okr, f, t = pcall(gc.read, a)
        if okr and type(f) == "table" and t._active_modifiers == "table" then
            seen = seen + 1
            if type(f.progress) == "number" and f.progress > 0 and f.progress < 100 then
                local okm, _, mt = pcall(gc.read, f._active_modifiers)
                if okm and type(mt) == "table" and mt.progressefficiency == "table" then
                    return a, f._active_modifiers
                end
                last = "a reel table with no modifiers (finished)"
            else
                last = "a reel table at progress " .. tostring(f.progress)
            end
        end
    end
    return nil, string.format("%d table(s), %d reel(s); %s", #addrs, seen, last)
end

-- ReelController's class table (the game's `v22`) is permanent and holds `ActiveReel`, the reel
-- that is open right now (set the moment a reel starts, cleared when it is destroyed). Finding it
-- once means every later reel is one gc.get away instead of a 1-second heap search per attempt,
-- which is what made the old code miss the first seconds of a reel. It is recognised by its
-- OnReelCreated signal and its methods.
local IR_CLASS_KEYS = { { "OnReelCreated" }, { "ActiveReel" }, { "ActiveReel", "OnReelCreated" }, { "Aborted" } }
function EX.ir_find_class()
    if IR.class then return IR.class end
    IR.ccombo = (IR.ccombo or 0) % #IR_CLASS_KEYS + 1
    local keys = IR_CLASS_KEYS[IR.ccombo]
    local ok, addrs = pcall(gc.find, table.unpack(keys))
    if not ok or type(addrs) ~= "table" then return nil end
    for _, a in ipairs(addrs) do
        local okr, _, ty = pcall(gc.read, a)
        if okr and type(ty) == "table" and ty.OnReelCreated == "table" and ty.AddModifier ~= nil and ty.new ~= nil then
            IR.class = a
            log("instant reel: reel class table found (via " .. table.concat(keys, "+") .. ")")
            return a
        end
    end
    return nil
end

-- the open reel and its modifier table through the class table (nil when there is none)
local function ir_class_reel()
    local cls = IR.class
    if not cls then return nil end
    local ok, v, ty = pcall(gc.get, cls, "ActiveReel")
    if not ok then return nil end
    if ty == "gone" then IR.class = nil; return nil end
    if ty ~= "table" or type(v) ~= "number" then return nil end
    local okr, f, t = pcall(gc.read, v)
    if not okr or type(f) ~= "table" or t._active_modifiers ~= "table" then return nil end
    if type(f.progress) ~= "number" or f.progress >= 100 then return nil end
    local okm, _, mt = pcall(gc.read, f._active_modifiers)
    if not okm or type(mt) ~= "table" or mt.progressefficiency ~= "table" then return nil end
    return v, f._active_modifiers
end

function EX.ir_session()
    if IR.busy or not IR.on then return end
    if type(gc) ~= "table" or type(gc.find) ~= "function" or type(gc.read) ~= "function" or type(gc.len) ~= "function"
        or type(memory_read) ~= "function" or type(memory_write) ~= "function" then
        say("ir_api", "instant reel: needs gc.find / gc.read / gc.len and memory_read / memory_write")
        return
    end
    IR.busy = true
    spawn(function()
        local reel, mods, tries, diag = nil, nil, 0, ""
        IR.orig = {}
        local t0 = tick()
        -- 1: find this reel (searches with different keys, while it is open)
        local via = "class table"
        while IR.on and IR.reel and S.running and not reel and tries < 60 do
            tries = tries + 1
            reel, mods = ir_class_reel()
            if not reel and not IR.class then
                EX.ir_find_class()                       -- one heap search for the class table
                reel, mods = ir_class_reel()
            end
            if not reel and not IR.class then            -- still no class table: search for the reel itself
                via = "key search"
                IR.combo = IR.combo % #IR_CANDS + 1
                reel, mods = ir_find_reel(IR_CANDS[IR.combo])
                if not reel then diag = tostring(mods) end
            end
            if not reel then task.wait(0.03) end
        end
        if not reel then
            say("ir_nf", "instant reel: the reel's table was not found yet (" .. diag .. ")")
            IR.busy = false
            return
        end
        IR.cur, IR.patched = mods, true
        -- 2: hold the numbers while the reel is open (a boost can add onto the first entry); what
        -- happened to each array is logged whenever the count changes
        local last_n = nil
        while IR.on and IR.reel and S.running do
            local okp, prog = pcall(gc.get, reel, "progress")
            if not okp or type(prog) ~= "number" or prog >= 100 then break end
            local notes = {}
            local n = ir_patch(mods, notes)
            if n == nil then break end
            if n ~= last_n then
                last_n = n
                log(string.format("instant reel: reel found after %.1f s (%s, try %d), %d value(s) set - %s", tick() - t0, via, tries, n, table.concat(notes, "; ")))
            end
            IR.n = n
            task.wait(0.15)
        end
        IR.cur = nil
        IR.orig = {}        -- the reel is over: its arrays are gone and their addresses may be someone else's
        IR.busy = false
    end)
end

function EX.ir_start()
    IR.on = true
    if IR.reel then EX.ir_session() end
    if not IR.class and not IR.finding then
        IR.finding = true
        spawn(function()
            local tries = 0
            while IR.on and S.running and not IR.class and tries < #IR_CLASS_KEYS * 2 do
                tries = tries + 1
                EX.ir_find_class()
                task.wait(0.2)
            end
            if not IR.class then say("ir_class", "instant reel: the reel class table was not found - searching per reel instead") end
            IR.finding = false
        end)
    end
end

local ir_prev, ir_t = false, 0
local function ir_watch(now)
    if not EX.ir_on or now - ir_t < 0.25 then return end
    ir_t = now
    local gui = player_gui()
    local open = (gui and child(gui, "reel")) ~= nil
    IR.reel = open
    if not open then IR.patched = false end
    if open and not IR.busy and not IR.patched then EX.ir_session() end
    ir_prev = open
end

function EX.ir_stop()
    IR.on = false
    -- a reel that is open right now gets its numbers back; a finished one is gone
    local restored = 0
    if IR.cur then
        for id, o in pairs(IR.orig) do
            local ptr = ir_ptr(o.arr)
            if ptr and pcall(memory_write, "double", ptr, o.v + 0.0) then restored = restored + 1 end
        end
    end
    IR.orig, IR.n = {}, 0
    if restored > 0 then log("instant reel: " .. restored .. " value(s) put back") end
end

-- ---- Discord webhook ----

local function hook_valid()
    local u = EX.hook_url
    return type(u) == "string" and (u:find("discord.com/api/webhooks/", 1, true) or u:find("discordapp.com/api/webhooks/", 1, true)) ~= nil
end

local function hook_post(text)
    if not (EX.hook_on and hook_valid()) then return end
    local url = EX.hook_url
    spawn(function()
        pcall(request, {
            Url = url, Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = HttpService:JSONEncode({ content = text }),
        })
    end)
end

local function hook_stats_text()
    local lp = me()
    local rod = equipped_rod()
    return string.format("**Stats**\nUser: %s\nState: %s    Rod: %s\nCaught: %d    Casts: %d    Shakes: %d",
        lp and name_of(lp) or "?", stat_state(), rod and name_of(rod) or "none", S.caught, S.casts, S.shakes)
end

local hook_start_sent, hook_last = false, 0
local function hook_tick(now)
    if not (EX.hook_on and hook_valid()) then return end
    if EX.hook_start and not hook_start_sent then
        hook_start_sent = true
        hook_post("**Started**\nUser: " .. (me() and name_of(me()) or "?"))
    end
    if EX.hook_stats and now - hook_last >= EX.hook_every then
        hook_last = now
        hook_post(hook_stats_text())
    end
end

-- ---- the loop that draws the markers ----
-- The ESP wears the window's two theme colours (Settings > Theme > Color 1 / Color 2): waypoints
-- (both waypoints and chests use Color 1). The library keeps its theme private, but the colour pickers it
-- builds hold the live values, so they are read from the settings tab twice a second.
local function theme_colors()
    local win = EX.ui_win
    local tab = win and win.GetSettingsTab and win:GetSettingsTab()
    if not tab then return nil end
    local a, b
    for _, sec in ipairs(tab.Sections or {}) do
        for _, row in ipairs(sec.Rows or {}) do
            if row.Name == "Color 1" and typeof(row.Value) == "Color3" then a = row.Value
            elseif row.Name == "Color 2" and typeof(row.Value) == "Color3" then b = row.Value end
        end
    end
    return a, b
end

local theme_t = -99
local function markers_step(now)
    if now - theme_t >= 0.5 then
        theme_t = now
        local a, b = theme_colors()
        if a then WP.recolor(a) end
        if a then CH.recolor(a) end
    end
    if not (WP.on or CH.on) then return end
    if now - (EX.me_t or -99) >= 0.2 then EX.me_t, EX.me = now, my_pos() end
    WP.tick(now, EX.me)
    CH.tick(now, EX.me)
end

-- ---- coordinates ----
local COORD = ""
local function parse_coords(s)
    s = tostring(s or ""):gsub("[XxYyZz]%s*:", ""):gsub(",", " ")
    local n = {}
    for v in s:gmatch("%-?%d+%.?%d*") do n[#n + 1] = tonumber(v) end
    if #n >= 3 then return n[1], n[2], n[3] end
end

-- ---- the window's tabs for all of the above ----
local function build_extras(win, fish, travel)
    -- tuning: the numbers the fishing steps use, live
    local tune = fish      -- the tuning sections live on the Fishing tab
    local cast = tune:Section("Casting", "Left")
    cast:Slider("Cast hold (s)", CFG.CAST_HOLD, 0.01, 0.2, 1.6, "s", function(v) CFG.CAST_HOLD = v end)
    cast:Slider("Recast if nothing in (s)", CFG.CAST_TIMEOUT, 1, 10, 90, "s", function(v) CFG.CAST_TIMEOUT = v end)
    cast:Slider("After a catch (s)", CFG.AFTER_CATCH, 0.1, 0, 6, "s", function(v) CFG.AFTER_CATCH = v end)
    cast:Slider("Shake click gap (s)", CFG.SHAKE_GAP, 0.01, 0.02, 0.4, "s", function(v) CFG.SHAKE_GAP = v end)
    local reel = tune:Section("Reel", "Right")
    reel:Slider("Look ahead (s)", CFG.REEL_LOOKAHEAD, 0.01, 0.05, 0.8, "s", function(v) CFG.REEL_LOOKAHEAD = v end)
    reel:Slider("On-target zone", CFG.REEL_ZONE, 0.01, 0.05, 0.5, "", function(v) CFG.REEL_ZONE = v end)
    reel:Slider("Reel timeout (s)", CFG.REEL_TIMEOUT, 1, 15, 180, "s", function(v) CFG.REEL_TIMEOUT = v end)
    reel:Info("Rod fishing only: Spear and Gun minigames are not part of this script.")

    -- the instant reel
    local ir = tune:Section("Instant reel", "Right")
    ir:Toggle("Enable instant reel", false, function(on)
        EX.ir_on = on
        if on then EX.ir_start() else EX.ir_stop() end
        log("instant reel " .. (on and "on" or "off"))
    end, "Changes the game's reel numbers through gc.set. Off by default."):AddKeybind(nil, "Toggle")
    ir:Slider("Reel speed", EX.ir_speed, 1, 1, 500, "", function(v) EX.ir_speed = v end)

    -- ESP
    local esp = win:Tab("ESP", "eye")
    local wp = esp:Section("Waypoints", "Left")
    wp:Toggle("Show waypoints", false, function(on) EX.wp_on = on; WP.set(on) end):AddKeybind(nil, "Toggle")
    wp:Toggle("Include fishing spots", false, function(on) EX.wp_fishing = on; WP.set(EX.wp_on) end)
    wp:Toggle("Show distance", true, function(on) EX.wp_dist = on end)
    wp:Slider("Marker size", EX.wp_size, 1, 2, 24, "px", function(v) EX.wp_size = v end)
    wp:Slider("Text size", EX.wp_text, 1, 8, 28, "", function(v) EX.wp_text = v end)
    wp:Slider("Max distance (0 = all)", EX.wp_max, 50, 0, 5000, "", function(v) EX.wp_max = v end)

    local ch = esp:Section("Treasure chests", "Right")
    ch:Toggle("Show treasure chests", false, function(on) EX.chest_on = on; CH.set(on) end):AddKeybind(nil, "Toggle")
    ch:Toggle("Show distance", true, function(on) EX.chest_dist = on end)
    ch:Slider("Marker size", EX.chest_size, 1, 2, 24, "px", function(v) EX.chest_size = v end)
    ch:Slider("Text size", EX.chest_text, 1, 8, 28, "", function(v) EX.chest_text = v end)
    ch:Slider("Max distance (0 = all)", EX.chest_max, 50, 0, 5000, "", function(v) EX.chest_max = v end)
    ch:Divider("Chest teleports")
    ch:Button("Teleport to nearest chest", chest_tp_nearest)
    ch:Button("Teleport to next chest", chest_tp_next)
    ch:Button("Collect all chests", chest_run_start)
    ch:Button("Stop chest run", chest_run_stop)
    ch:Toggle("Chest run", false, function(on)
        if on then chest_run_start() else chest_run_stop() end
    end, "Starts and stops the collect all chests run, so one key does both"):AddKeybind(nil, "Toggle")
    local perf = esp:Section("Performance", "Left")
    perf:Slider("ESP update rate (Hz)", EX.esp_hz, 5, 10, 120, "Hz", function(v) EX.esp_hz = v end)
    perf:Toggle("Text outline (slower)", EX.esp_outline, function(on)
        EX.esp_outline = on
        WP.set_outline(on); CH.set_outline(on)
    end)

    -- coordinates (the teleport tab's own section)
    local co = travel:Section("Go to a point", "Left")      -- on the Travel tab, under the places
    local box = co:Textbox("x, y, z", "", function(t) COORD = t or "" end)
    co:Button("Fill with my position", function()
        local p = my_pos()
        if not p then log("no character"); return end
        local s = string.format("%.2f, %.2f, %.2f", p.X, p.Y, p.Z)
        COORD = s
        pcall(function() box:Set(s) end)
        pcall(setclipboard, s)
    end)
    co:Button("Teleport to coordinates", function()
        local x, y, z = parse_coords(COORD)
        if not x then log("bad coordinates: " .. tostring(COORD)); return end
        go_to(x, y, z)
    end)

    -- webhook
    local w = win:SettingsSection("Discord webhook", "Right")     -- in the settings tab
    -- the window's text boxes cannot paste (Ctrl+V is not handled by the library), so the URL comes
    -- in through a button that reads the clipboard, or from a file
    local url_box = w:Textbox("Webhook URL", "", function(t) EX.hook_url = t or "" end)
    local function take_url(text, from)
        text = tostring(text or ""):gsub("%s+", "")
        if text == "" then log("webhook: " .. from .. " is empty"); return end
        pcall(function() url_box:Set(text) end)
        EX.hook_url = text
        log("webhook: URL taken from " .. from .. (hook_valid() and "" or " (this does not look like a Discord webhook URL)"))
    end
    w:Button("Paste URL from clipboard", function()
        local ok, text = pcall(getclipboard)
        take_url(ok and text or "", "the clipboard")
    end)
    w:Button("Load URL from webhook_url.txt", function()
        local ok, text = pcall(readfile, "webhook_url.txt")
        take_url(ok and text or "", "webhook_url.txt")
    end)
    w:Toggle("Enable webhook", false, function(on) EX.hook_on = on; hook_start_sent = false end):AddKeybind(nil, "Toggle")
    w:Toggle("Send a startup message", true, function(on) EX.hook_start = on end)
    w:Toggle("Send periodic stats", true, function(on) EX.hook_stats = on end)
    w:Slider("Stats interval (s)", EX.hook_every, 10, 30, 3600, "s", function(v) EX.hook_every = v end)
    w:Button("Send test stats now", function()
        if not hook_valid() then log("webhook: not a Discord webhook URL"); return end
        local was = EX.hook_on
        EX.hook_on = true
        hook_post(hook_stats_text())
        EX.hook_on = was
    end)
end

local function build_panel()
    local win = Lib:CreateWindow({ title = "Fisch", subtitle = "Calamity Hub", size = Vector2.new(640, 440) })
    EX.ui_win = win

    local fish = win:Tab("Fishing", "crosshair")
    local auto = fish:Section("Automation", "Left")
    auto:Toggle("Auto Fish", false, function(on)
        S.paused = not on; hold(false); log(S.paused and "paused" or "resumed")
    end):AddKeybind(nil, "Toggle")
    auto:Toggle("Auto Shake", false, function(on)
        S.shake_on = on; log("auto shake " .. (on and "on" or "off"))
    end):AddKeybind(nil, "Toggle")
    auto:Toggle("Auto Reel", false, function(on)
        S.reel_on = on; hold(false); log("auto reel " .. (on and "on" or "off"))
    end):AddKeybind(nil, "Toggle")

    local stats = fish:Section("Status", "Right")
    stats:Label(function()
        local up = tick() - T0
        return string.format("Caught: %d  (%.1f/min)", S.caught, S.caught / math.max(up / 60, 0.01))
    end)
    stats:Label(function()
        local up = tick() - T0
        return string.format("Uptime: %d:%02d", math.floor(up / 60), math.floor(up % 60))
    end)

    local travel = win:Tab("Travel", "map")
    local tp = travel:Section("Places", "Left")
    local names = place_names()
    loc_dd = tp:Dropdown("Place", { names[1] }, names, false, function(v)
        local hit = v and v[1] and PLACES[v[1]]
        if hit then TP.cat, TP.loc = hit[1], hit[2] end
    end, nil, true)
    tp:Button("Teleport", function() TP.go() end)
    tp:Label(function() return TP.msg end)

    build_extras(win, fish, travel)
    win:AddSettingsTab("cog")
end

-- the found places were rebuilt: the dropdown gets the new list and starts at the first
local function refresh_places()
    local prev = loc_dd and loc_dd.Value and loc_dd.Value[1]
    TP.cat, TP.loc = 1, 1
    if not loc_dd then return end
    local names = place_names()
    loc_dd:Refresh(names)
    if prev and PLACES[prev] then
        loc_dd.Value = { prev }
        TP.cat, TP.loc = PLACES[prev][1], PLACES[prev][2]
    else
        loc_dd.Value = { names[1] }
    end
end


-- ---- teleport ----

function TP.go()
    if TP.busy then return end
    local e = LOCATIONS[TP.cat].list[TP.loc]
    TP.busy = true
    TP.msg = "going..."
    spawn(function()
        hold(false)
        local ok, err = pcall(function()
            local t0 = tick()
            while isteleporting() and tick() - t0 < 4 do task.wait(0.03) end
            -- a few studs up, so the landing is on the spot and not inside it
            if not teleport(Vector3.new(e[2], e[3] + 3, e[4])) then error("teleport refused") end
            t0 = tick()
            while isteleporting() and tick() - t0 < 4 do task.wait(0.03) end
        end)
        if ok then
            log("teleported to " .. e[1] .. string.format(" (%.0f, %.0f, %.0f)", e[2], e[3], e[4]))
            TP.msg = "done"
            set_state("start")        -- recast where we landed
        else
            log("teleport to " .. e[1] .. " failed: " .. tostring(err))
            TP.msg = "failed"
        end
        TP.busy = false
    end)
end

-- ---- places read from the game ----
--
-- The list above is hand-made. Islands, the rods on display and the NPCs are read from the map:
--   islands  workspace.world.spawns.TpSpots   (the game's own teleport spots, one part each)
--   rods     every model or part under workspace.world whose name ends in "Rod"
--   npcs     workspace.world.npcs
-- Fisch streams its map: only what is near you is in memory (the first scan found 3 islands and 1
-- rod, all within a few hundred studs). ServerStorage never reaches a client at all. A one-off
-- tour of the map once found 107 islands, 44 rods and 230 NPCs, but nothing is read from a cache
-- file any more: only what the game has loaded is listed. It is scanned at the start and every
-- 30 s after, so places join the list (for this session) as you travel near them.

local PART = { Part = true, MeshPart = true, UnionOperation = true, WedgePart = true, SpawnLocation = true, Seat = true }
local function vec_ok(p) return p and p.X and p.X == p.X and math.abs(p.X) < 1e6 and math.abs(p.Y) < 1e6 end

-- a place to stand: a part's position, a model's primary part, else the first part found inside
local function pos_of(inst, depth)
    depth = depth or 0
    local cls = class_of(inst)
    if PART[cls] then
        local p = prop(inst, "Position")
        if vec_ok(p) then return p end
        return nil
    end
    if cls == "Model" then
        local pp = prop(inst, "PrimaryPart")
        local p = pp and PART[class_of(pp)] and prop(pp, "Position")
        if vec_ok(p) then return p end
    end
    if depth >= 3 then return nil end
    for _, c in ipairs(children(inst)) do
        local p = pos_of(c, depth + 1)
        if p then return p end
    end
    return nil
end

local function title(s)
    return (s:gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end))
end

-- what has been found: kind -> name -> {x, y, z}
local KINDS = { { key = "isl", name = "Islands" }, { key = "rod", name = "Rods" }, { key = "npc", name = "NPCs (in game)" } }
local FOUND = { isl = {}, rod = {}, npc = {} }

local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end

-- What the map holds that is not a place to go: the full scan of 2026-10-31 listed a rod at
-- (0, -2000, 0) (a template parked under the map), "FakeRod" and a bare "Rod", second copies
-- spelled without the space ("VolcanicRod", "Ethereal PrismRod"), and the npcs folder's own
-- sub-folders ("CultistNpcs", "LabNpcs", "FischfrightGoblins") as if they were NPCs.
local function junk(kind, name, p)
    if math.abs(p[1]) < 1 and math.abs(p[3]) < 1 then return true end
    if kind == "rod" then
        return not name:match("%s[Rr]od%s*$") or name:lower():find("fake", 1, true) ~= nil
    end
    if kind == "npc" then
        local l = name:lower()
        return l:match("npcs$") ~= nil or l:match("goblins$") ~= nil or l == "merchants" or l:match("area$") ~= nil
    end
    return false
end

-- The found places as dropdown categories, first in the list (islands are what is wanted most).
-- Any old copies go first, so a rebuild just replaces them.
local function rebuild_live()
    for i = #LOCATIONS, 1, -1 do
        if LOCATIONS[i].live then table.remove(LOCATIONS, i) end
    end
    local add = {}
    for _, kd in ipairs(KINDS) do
        local list = {}
        for name, p in pairs(FOUND[kd.key]) do
            if not junk(kd.key, name, p) then list[#list + 1] = { name, p[1], p[2], p[3] } end
        end
        table.sort(list, function(a, b) return a[1]:lower() < b[1]:lower() end)
        if #list > 0 then add[#add + 1] = { name = kd.name, list = list, live = true } end
    end
    for i = #add, 1, -1 do table.insert(LOCATIONS, 1, add[i]) end
    TP.cat, TP.loc = 1, 1
    refresh_places()
end

-- What is loaded right now. Returns how many new places it added.
local function scan_here()
    local world = child(workspace, "world")
    if not world then return 0 end
    local added = 0
    local function put(kind, name, p)
        if not FOUND[kind][name] then added = added + 1 end
        FOUND[kind][name] = { p.X, p.Y, p.Z }
    end
    for _, c in ipairs(children(child(child(world, "spawns"), "TpSpots"))) do
        local p = pos_of(c)
        if p then put("isl", title(name_of(c)), p) end
    end
    for _, c in ipairs(children(child(world, "npcs"))) do
        local p = pos_of(c)
        if p then put("npc", name_of(c), p) end
    end
    local seen = 0
    local function walk(o, depth)
        if depth > 6 or seen > 25000 then return end
        for _, c in ipairs(children(o)) do
            seen = seen + 1
            if seen % 300 == 0 then task.wait() end     -- let the fishing loop run meanwhile
            local n, cls = name_of(c), class_of(c)
            if (cls == "Model" or PART[cls]) and n:lower():match("rod%s*$") then
                local p = pos_of(c)
                if p then put("rod", n, p) end
            elseif cls == "Folder" or cls == "Model" then
                walk(c, depth + 1)
            end
        end
    end
    walk(world, 0)
    return added
end

local function write_places()
    local lines = { "---- places read from the game ----" }
    for _, c in ipairs(LOCATIONS) do
        if c.live then
            lines[#lines + 1] = "-- " .. c.name .. " (" .. #c.list .. ")"
            for _, e in ipairs(c.list) do lines[#lines + 1] = string.format("  %s  %.1f, %.1f, %.1f", e[1], e[2], e[3], e[4]) end
        end
    end
    pcall(writefile, "fisch_places.txt", table.concat(lines, "\n") .. "\n")
end

local function summary()
    return count(FOUND.isl) .. " islands, " .. count(FOUND.rod) .. " rods, " .. count(FOUND.npc) .. " npcs"
end

local function live_scan(first)
    local added = scan_here()
    if added > 0 or first then
        rebuild_live()
        write_places()
        log("places: " .. summary() .. (added > 0 and (" (" .. added .. " new)") or ""))
    end
end


-- ---------------------------------------------------------------------------------------------
-- main loop
-- ---------------------------------------------------------------------------------------------

local status_t, was_reel = 0, false

local function step()
    local now = tick()
    if now - status_t >= 5 then status_t = now; write_status() end
    pcall(markers_step, now)
    pcall(ir_watch, now)
    pcall(hook_tick, now)
    -- Auto Fish off: Auto Shake and Auto Reel still work (you cast, they take it from there)
    local auto = not S.paused
    if not auto and not (S.shake_on or S.reel_on) then return end
    if RUN.active then hold(false); return end      -- the chest run is driving

    if not foreground() then
        hold(false)
        say("fg", "Roblox is not the foreground window - waiting (clicks would go elsewhere)")
        return
    end
    say("fg", "Roblox is in front")

    local gui = player_gui()
    local reel_ui = gui and child(gui, "reel")
    local shake_ui = gui and child(gui, "shakeui")
    local shake_btn = shake_ui and shake_button(shake_ui)

    if reel_ui then
        was_reel = true
        if S.reel_on then reel(reel_ui, now) else hold(false); if auto then set_state("reel (yours)") end end
        return
    end
    if was_reel then
        -- the reel closed: a catch (or a lost fish - the game says which, the count is of reels)
        was_reel = false
        hold(false)
        S.caught = S.caught + 1
        log("reel #" .. S.caught .. " done")
        set_state("cooldown")
        return
    end
    if shake_btn then
        if S.shake_on then shake(shake_btn, now) elseif auto then set_state("shake") end
        return
    end
    hold(false)
    if not auto then return end      -- no casting without Auto Fish

    if S.state == "cooldown" and now - S.state_t < CFG.AFTER_CATCH then return end
    if S.state == "shake" then set_state("waiting"); return end   -- shaking done, the reel comes next
    -- waiting for a bite: nothing to do until the shake shows (checked above) or the wait runs out
    if S.state == "waiting" and now - S.state_t < CFG.CAST_TIMEOUT then return end
    if S.state == "waiting" then say("cast", "nothing in " .. CFG.CAST_TIMEOUT .. " s - casting again") end
    if not equip() then set_state("equip"); return end
    cast()
end

local function stop()
    S.running = false
    pcall(hold, false)
    RUN.active = false
    pcall(EX.ir_stop)
    for _, m in ipairs(MARKERS) do pcall(m.destroy) end
    pcall(function() Lib:Destroy() end)
end
_G.__fisch = { stop = stop, state = S, cfg = CFG, dump = dump }

local okp, perr = pcall(build_panel)
if not okp then log("panel failed to build: " .. tostring(perr)) end
spawn(function()
    local ok, err = pcall(live_scan, true)
    if not ok then log("places: the scan failed: " .. tostring(err)) end
    while S.running do                    -- places stream in as you travel
        task.wait(30)
        local ok2, err2 = pcall(live_scan, false)
        if not ok2 then say("places", "places: the rescan failed: " .. tostring(err2)) end
    end
end)
log("loaded - everything is on the panel, and starts off")

spawn(function()
    while S.running do
        local ok, err = pcall(step)
        if not ok then
            S.errors = S.errors + 1
            if tostring(err) ~= S.last_err then
                S.last_err = tostring(err)
                log("step error: " .. S.last_err)
            end
            pcall(hold, false)
            if S.errors % 200 == 0 then
                log("200 more errors - pausing 10 s")
                task.wait(10)
            end
        end
        -- every frame-ish while shaking, reeling or dragging the panel; a calmer pace the rest of the time
        local busy = S.state == "shake" or S.state == "reel" or held
        -- the markers want the loop at their own rate (they throttle themselves); it never runs faster than one frame
        local wait_s = busy and 0.03 or 0.07
        if WP.on or CH.on then wait_s = math.min(wait_s, 1 / math.max(5, EX.esp_hz)) end
        task.wait(wait_s)
    end
    pcall(hold, false)
    log("stopped")
end)
