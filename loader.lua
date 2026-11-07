-- Calamity Script Hub loader
-- Picks the game file matching the current game and runs it.
-- Source: local workspace folder by default, or set BASE_URL to a raw host.

local BASE_URL = "https://raw.githubusercontent.com/ahakillme/calamity-hub/main/"
local LOCAL_DIR = "calamity script hub/" -- folder inside Calamity's workspace

-- [PlaceId or GameId] = file in games/
local GAMES = {
    [16732694052] = "fisch.lua",
    [5750914919] = "fisch.lua",     -- Fisch GameId: matches every place inside the game
    [96469185605358] = "tycoon_farm.lua",
}

local function fetch(path)
    if BASE_URL then
        return game:HttpGet(BASE_URL .. path)
    end
    return readfile(LOCAL_DIR .. path)
end

local file = GAMES[game.PlaceId] or GAMES[game.GameId]
if not file then
    warn(("[hub] no script for PlaceId %d / GameId %d"):format(game.PlaceId, game.GameId))
    return
end

local ok, src = pcall(fetch, "games/" .. file)
if not ok then
    warn("[hub] could not load games/" .. file .. ": " .. tostring(src))
    return
end

local fn, err = loadstring(src, "=" .. file)
if not fn then
    warn("[hub] compile error in " .. file .. ": " .. tostring(err))
    return
end

print("[hub] loading " .. file)
fn()
