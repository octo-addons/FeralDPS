-- Smoke test: every spec and slash command, with and without Nampower/UnitXP. Started by run.py.
return function(ADDON)
local SIM = TEST_DIR
local res = {}
local function boot(strip)
  local M = dofile(SIM .. "mock.lua")
  local env, W = M.env, M.W
  if strip then
    env.GetNampowerVersion, env.UnitXP, env.GetUnitField, env.GetSpellIdForName = nil, nil, nil, nil
    local ue = env.UnitExists
    env.UnitExists = function(u) local ok = ue(u); return ok end      -- no SuperWoW: no GUID
  end
  local f = assert(io.open(ADDON)); local src = f:read("a"); f:close()
  assert(load(src, "FeralDPS", "t", env))()
  env.FeralDPS_Settings = { version = 13, spec = "cat", reshiftGain = 60, immuneSeed = 1, useStep = true, trimBuffs = true, idolSwap = true }
  W.mana, W.maxMana = 60000, 60000
  env.FeralDPS_OnLoad(); M.fire("PLAYER_LOGIN"); M.fire("PLAYER_ENTERING_WORLD")
  M.addTarget("boss", "Chromaggus", "0xF130000000000001", true)
  M.addTarget("add", "Death Talon Wyrmguard", "0xF130000000000002", false)
  M.setTarget("boss"); M.fire("PLAYER_REGEN_DISABLED")
  return M, env, W
end
local function try(name, fn) local ok, err = pcall(fn); res[#res+1] = (ok and "PASS  " or "FAIL  ") .. name .. (ok and "" or ("\n      " .. tostring(err))) end
for _, strip in ipairs({ false, true }) do
  local tag = strip and " (no Nampower, no UnitXP)" or ""
  try("cat 60s with target swaps, dodges, range errors" .. tag, function()
    local M, env, W = boot(strip)
    for i = 1, 600 do
      M.step(0.1)
      if i == 150 then M.setTarget("add") end
      if i == 220 then M.setTarget("boss") end
      if i == 300 then W.biteDodges = true end
      if i == 400 then W.dist = 5.5 end
      if i == 430 then W.dist = 3; M.fire("CHAT_MSG_COMBAT_SELF_HITS", "You hit Chromaggus for 300.") end
      if i == 450 then W.target = nil; M.fire("PLAYER_TARGET_CHANGED") end
      if i == 460 then M.setTarget("boss") end
      if i == 500 then M.uierr("You are too far away!"); M.uierr("Already looted") end
      M.press("cat")
    end
  end)
  try("bear, aoe and farm 20s each" .. tag, function()
    local M, env, W = boot(strip)
    for _, sp in ipairs({ "bear", "aoe", "farm", "cat" }) do
      W.form = (sp == "bear" or sp == "aoe") and 1 or 2
      for i = 1, 200 do M.step(0.1); M.press(sp) end
    end
  end)
  try("every slash command" .. tag, function()
    local M, env, W = boot(strip)
    for i = 1, 100 do M.step(0.1); M.press("cat") end
    for _, c in ipairs({ "debug", "help", "buffs", "trim", "trim", "trim add Test", "trim remove Test", "trim reset", "step", "step", "immune",
      "immune add target", "immune clear Chromaggus", "immune known", "idol", "idol", "talents", "reshift", "reshift", "reshift energy 15",
      "trace", "trace show 5", "trace", "bosshp", "trinket", "pot", "juju", "claw", "claw", "hide", "show", "hudreset", "rip", "rip", "reload", "" }) do
      M.press(c)
    end
    for i = 1, 100 do M.step(0.1); M.press("cat") end
  end)
end
return table.concat(res, "\n")
end
