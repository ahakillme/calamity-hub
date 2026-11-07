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
    SCREEN        = { 2560, 1440 },   -- used when the camera's viewport cannot be read
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
    return CFG.SCREEN[1], CFG.SCREEN[2]
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
    if not held then local x, y = rest_point(); move(x, y) end

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
    if S.paused then return "paused" end
    if not foreground() then return "Roblox not in front" end
    return S.state
end

local function build_panel()
    local win = Lib:CreateWindow({ title = "Fisch", subtitle = "Calamity Hub", size = Vector2.new(640, 440) })

    local fish = win:Tab("Fishing", "crosshair")
    local auto = fish:Section("Automation", "Left")
    auto:Toggle("Auto Fish", false, function(on)
        S.paused = not on; hold(false); log(S.paused and "paused" or "resumed")
    end)
    auto:Toggle("Auto Shake", false, function(on)
        S.shake_on = on; log("auto shake " .. (on and "on" or "off"))
    end)
    auto:Toggle("Auto Reel", false, function(on)
        S.reel_on = on; hold(false); log("auto reel " .. (on and "on" or "off"))
    end)

    local stats = fish:Section("Status", "Right")
    stats:Label(function() return "State: " .. stat_state() end)
    stats:Label(function()
        local up = tick() - T0
        return string.format("Caught: %d  (%.1f/min)", S.caught, S.caught / math.max(up / 60, 0.01))
    end)
    stats:Label(function() return "Casts: " .. S.casts end)
    stats:Label(function() return "Shakes: " .. S.shakes end)
    stats:Label(function()
        local up = tick() - T0
        return string.format("Uptime: %d:%02d", math.floor(up / 60), math.floor(up % 60))
    end)

    local move_tab = win:Tab("Movement", "eye")
    local mv = move_tab:Section("Water", "Left")
    mv:Toggle("Water Walk", false, function(on)
        S.jesus_on = on; log("water walk " .. (on and "on" or "off"))
    end)

    local tp_tab = win:Tab("Teleport", "map")
    local tp = tp_tab:Section("Places", "Left")
    local names = place_names()
    loc_dd = tp:Dropdown("Place", { names[1] }, names, false, function(v)
        local hit = v and v[1] and PLACES[v[1]]
        if hit then TP.cat, TP.loc = hit[1], hit[2] end
    end, nil, true)
    tp:Button("Teleport", function() TP.go() end)
    tp:Label(function() return TP.msg end)

    win:AddSettingsTab("cog")
end

-- the found places were rebuilt: the dropdown gets the new list and starts at the first
local function refresh_places()
    TP.cat, TP.loc = 1, 1
    if not loc_dd then return end
    local names = place_names()
    loc_dd:Refresh(names)
    loc_dd.Value = { names[1] }
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
-- tour of the map (2026-10-31: 48 stops, 107 islands, 44 rods, 230 NPCs) filled
-- Workspace\fisch_places_cache.txt, which is read at the start; what is loaded near you at the
-- start is added to it, so a place the game adds later joins the list once you have been near it.

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
local CACHE = "fisch_places_cache.txt"

local function load_cache()
    local ok, text = pcall(readfile, CACHE)
    if not ok or type(text) ~= "string" then return 0 end
    local n = 0
    for line in text:gmatch("[^\n]+") do
        local k, name, x, y, z = line:match("^(%a+)|(.-)|([%-%d%.e]+)|([%-%d%.e]+)|([%-%d%.e]+)")
        if k and FOUND[k] and tonumber(x) then
            FOUND[k][name] = { tonumber(x), tonumber(y), tonumber(z) }
            n = n + 1
        end
    end
    return n
end

local function save_cache()
    local lines = {}
    for _, kd in ipairs(KINDS) do
        for name, p in pairs(FOUND[kd.key]) do
            lines[#lines + 1] = string.format("%s|%s|%.2f|%.2f|%.2f", kd.key, name, p[1], p[2], p[3])
        end
    end
    table.sort(lines)
    pcall(writefile, CACHE, table.concat(lines, "\n") .. "\n")
end

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

local function live_scan()
    local cached = load_cache()
    scan_here()
    save_cache()
    rebuild_live()
    write_places()
    log("places: " .. summary() .. (cached > 0 and " (" .. cached .. " from the cache)" or " (no cache - only what is loaded near you)"))
end


-- ---------------------------------------------------------------------------------------------
-- Water Walk: an invisible floor at the water's surface, under you
--
-- Fisch only lets you cast while standing on something, so walking on water has to be a real
-- floor, not a hover: one collidable, invisible Part made with Instance.new and kept
-- under you at the water's height. Instance.new makes it with its position, size and collision;
-- it cannot be anchored from outside the engine, so every tick it is set back at its spot with
-- zero speed. It follows only once you are a few studs from its middle.
--
-- The water's height starts at Fisch's sea level and is learned from you whenever you swim (the
-- root sits at the surface; waves are averaged in, a jump of 3+ studs is a new body of water).
-- Falling in lifts you onto the floor. On land the floor sits under the island, out of the way.
-- Off, or the script stopped: the part is destroyed.
-- ---------------------------------------------------------------------------------------------

S.jesus_on = false

local function off(name, fallback)
    local ok, v = pcall(getoffset, name)
    return (ok and type(v) == "number" and v > 0) and v or fallback
end
local OFFS = {
    prim      = off("BasePart::Primitive", 0x188),
    pos       = off("Primitive::Position", 0xec),
    vel       = off("Primitive::AssemblyLinearVelocity", 0xf8),
    state     = off("Humanoid::HumanoidState", 0x8c0),
    state_id  = off("Humanoid::HumanoidStateID", 0x20),
    hip       = off("Humanoid::HipHeight", 0x194),
}
local ST_SWIMMING = 4                    -- Enum.HumanoidStateType.Swimming
local FLOOR = { size = 36, follow = 10, thick = 2 }   -- studs: its width, how far you go before it follows, its height

local W = { water_y = 126.0, learned = false, look_t = -99, root = nil, hum = nil,
            part = nil, px = nil, pz = nil, py = nil, busy = false, failed_t = -99 }
local function mr(t, a) local ok, v = pcall(memory_read, t, a); if ok then return v end end
local function mw(t, a, v) pcall(memory_write, t, a, v) end

local function floor_gone()
    if not W.part then return true end
    local ok, cls = pcall(function() return W.part.ClassName end)
    return not ok or cls ~= "Part"
end

local function destroy_floor()
    if W.part then pcall(function() W.part:Destroy() end) end
    W.part, W.px, W.pz, W.py = nil, nil, nil, nil
end

-- the floor's top at the water's surface, centred under (x, z); made the first time
local function place_floor(x, z)
    local top = W.water_y
    local pos = Vector3.new(x, top - FLOOR.thick / 2, z)
    if floor_gone() then
        -- Instance.new sets the position, size, transparency and collision as it makes the part.
        -- Anchored cannot be set from outside the engine, so the part is held by pin_floor instead.
        local ok, p = pcall(Instance.new, "Part", workspace, {
            Position = pos, Size = Vector3.new(FLOOR.size, FLOOR.thick, FLOOR.size),
            Transparency = 1, CanCollide = true })
        if not ok or not p then return false, "Instance.new failed: " .. tostring(p) end
        W.part = p
        pcall(function() p.Name = "wwfloor" end)
    else
        local ok, why = pcall(function() W.part.Position = pos end)
        if not ok then return false, tostring(why) end
    end
    W.px, W.pz, W.py = x, z, top
    return true
end

-- The part is not anchored, so gravity pulls on it: every tick it is put back at its spot with no
-- speed, which is a few hundredths of a stud of sag at most.
local function pin_floor()
    if not (W.part and W.px) or W.busy or floor_gone() then return end
    pcall(function()
        W.part.Position = Vector3.new(W.px, W.py - FLOOR.thick / 2, W.pz)
        W.part.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
    end)
end

local function jesus_tick(now)
    -- the character's parts, looked up again every second (a respawn makes new ones)
    if now - W.look_t > 1 or not W.root then
        W.look_t = now
        local ch = character()
        W.root = ch and child(ch, "HumanoidRootPart")
        W.hum = ch and child(ch, "Humanoid")
    end
    local root, hum = W.root, W.hum
    if not (root and hum) then return end
    local prim = mr("uint64", root + OFFS.prim)
    if not prim or prim < 0x10000 then W.root = nil; return end
    local sp = mr("uint64", hum + OFFS.state)
    local state = sp and sp > 0x10000 and mr("int", sp + OFFS.state_id)
    local hip = mr("float", hum + OFFS.hip) or 2
    local x = mr("float", prim + OFFS.pos)
    local y = mr("float", prim + OFFS.pos + 4)
    local z = mr("float", prim + OFFS.pos + 8)
    if not (x and y and z) then return end
    local swimming = state == ST_SWIMMING

    if swimming then
        if not W.learned or math.abs(W.water_y - y) > 3 then
            W.water_y, W.learned = y, true
            log(string.format("water walk: the water's surface is at y %.1f", y))
        else
            W.water_y = W.water_y * 0.9 + y * 0.1
        end
    end

    -- the floor follows you (on its own thread: each move waits for a Heartbeat)
    local far = not W.px or (x - W.px) ^ 2 + (z - W.pz) ^ 2 > FLOOR.follow ^ 2 or math.abs((W.py or 0) - W.water_y) > 0.5
    if (far or floor_gone()) and not W.busy and now - W.failed_t > 3 then
        W.busy = true
        spawn(function()
            local ok, why = place_floor(x, z)
            if not ok then
                W.failed_t = tick()
                say("ww", "water walk: the floor could not be placed - " .. tostring(why))
            else
                say("ww", "water walk: floor under you at y " .. string.format("%.1f", W.water_y))
            end
            W.busy = false
        end)
    end

    pin_floor()

    -- fallen in: up onto the floor, the fall stopped
    if swimming and W.px then
        mw("float", prim + OFFS.pos + 4, W.water_y + hip + 1.3)
        mw("float", prim + OFFS.vel + 4, 0)
    end
end

-- ---------------------------------------------------------------------------------------------
-- main loop
-- ---------------------------------------------------------------------------------------------

local status_t, was_reel = 0, false

local function step()
    local now = tick()
    if now - status_t >= 5 then status_t = now; write_status() end
    if S.jesus_on then pcall(jesus_tick, now) elseif W.part and not W.busy then pcall(destroy_floor) end   -- off: the floor goes
    if S.paused then return end

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
        if S.reel_on then reel(reel_ui, now) else hold(false); set_state("reel (yours)") end
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
        if S.shake_on then shake(shake_btn, now) else set_state("shake") end
        return
    end
    hold(false)

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
    pcall(destroy_floor)
    pcall(function() Lib:Destroy() end)
end
_G.__fisch = { stop = stop, state = S, cfg = CFG, dump = dump }

local okp, perr = pcall(build_panel)
if not okp then log("panel failed to build: " .. tostring(perr)) end
spawn(function()
    local ok, err = pcall(live_scan)
    if not ok then log("places: the scan failed: " .. tostring(err)) end
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
        local busy = S.state == "shake" or S.state == "reel" or held or S.jesus_on
        task.wait(busy and 0.03 or 0.07)
    end
    pcall(hold, false)
    log("stopped")
end)
