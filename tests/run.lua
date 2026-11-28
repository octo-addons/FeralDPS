-- Scenario tests for FeralDPS against mock.lua (see DEVELOPMENT.md). Started by run.py, which sets TEST_DIR.
local SIM = TEST_DIR
local out = {}
local function say(s) out[#out + 1] = s end

local function boot(addonPath, setup)
  local M = dofile(SIM .. "mock.lua")
  local env, W = M.env, M.W
  local f = assert(io.open(addonPath)); local src = f:read("a"); f:close()
  local chunk = assert(load(src, "FeralDPS", "t", env))
  chunk()
  env.FeralDPS_Settings = { version = 13, spec = "cat", useRagePot = false, useJuju = false, useTrinkets = false,
    useBerserk = false, reshiftGain = 60, immuneSeed = 1, hudHidden = false }
  W.mana, W.maxMana = 60000, 60000        -- Wisdom on the boss: mana is not the limit in these tests
  if setup then setup(M, env, W) end
  env.FeralDPS_OnLoad()
  M.fire("PLAYER_LOGIN")
  M.fire("PLAYER_ENTERING_WORLD")
  M.F = M.upvalue(env.FeralDPS.State, "F_")
  M.addTarget("boss", "Chromaggus", "0xF130000000000001", true)
  M.addTarget("add", "Death Talon Wyrmguard", "0xF130000000000002", false)
  M.setTarget("boss")
  M.fire("PLAYER_REGEN_DISABLED")
  return M, env, W, M.F
end

local function run(M, seconds, cmd, hook)
  local n = math.floor(seconds / 0.1 + 0.5)
  for i = 1, n do
    M.step(0.1)
    if hook then hook(i) end
    M.press(cmd or "cat")
  end
end

local function scenario(name, fn)
  local ok, err = pcall(fn)
  say((ok and "PASS  " or "FAIL  ") .. name .. (ok and (err and ("  - " .. tostring(err)) or "") or ("\n      " .. tostring(err))))
end
local function check(cond, msg) if not cond then error(msg, 2) end end

return function(addonPath, isNew)
  -- 1. plain 3-minute boss fight
  scenario("boss fight 180s runs without a Lua error", function()
    local M, env, W, F = boot(addonPath)
    run(M, 180)
    local rip, bite, shred, rsh = M.count("Rip"), M.count("Ferocious Bite"), M.count("Shred"), M.count("Reshift")
    check(rip >= 1 and rip <= 4 and bite >= 6 and shred >= 30, "odd cast counts: Rip " .. rip .. " Bite " .. bite .. " Shred " .. shred)
    check(#W.errors < 12, "too many client errors: " .. #W.errors .. " first: " .. tostring(W.errors[1] and W.errors[1].msg))
    return string.format("Rip %d, Bite %d, Shred %d, Rake %d, TF %d, Reshift %d, client errors %d, Carnage counted %d",
      rip, bite, shred, M.count("Rake"), M.count("Tiger's Fury"), rsh, #W.errors, env.FeralDPS.State().carnage)
  end)

  scenario("Carnage counter counts refreshes", function()
    local M, env, W, F = boot(addonPath)
    run(M, 120)
    local c = env.FeralDPS.State().carnage
    check(c >= 3, "Carnage refreshes counted: " .. c .. " with " .. M.count("Ferocious Bite") .. " Bites")
    return c .. " counted for " .. M.count("Ferocious Bite") .. " Bites"
  end)

  scenario("a dodged Bite does not reset the Rip timer", function()
    local M, env, W, F = boot(addonPath)
    run(M, 30)
    local got
    W.biteDodges = true
    local n0 = M.count("Ferocious Bite")
    for i = 1, 600 do
      M.step(0.1); M.press("cat")
      if M.count("Ferocious Bite") > n0 then got = true; break end
    end
    M.step(0.1); M.step(0.1); M.step(0.1)
    check(got, "no Bite in the window")
    -- the server did not refresh: the real Rip
    local real
    for _, d in ipairs(W.targets.boss.deb) do if d.name == "Rip" and d.mine then real = d.untilT - W.t end end
    local addon = env.FeralDPS.State().rip
    check(math.abs((real or 0) - addon) < 2.6, string.format("addon thinks Rip has %.1fs, the server %.1fs", addon, real or 0))
    return string.format("addon %.1fs vs server %.1fs left", addon, real or 0)
  end)

  scenario("Clearcasting at 5 CP with Rip up goes to Shred", function()
    local M, env, W, F = boot(addonPath)
    run(M, 25)
    local picked
    for i = 1, 1500 do
      M.step(0.1)
      if W.cp >= 5 and env.FeralDPS.State().rip > 3.5 and (W.gcdStart + W.gcdDur) <= W.t then
        M.addBuff("Clearcasting", "Interface\\Icons\\Spell_Shadow_ManaBurn", 15)
        local n = #W.casts
        M.press("cat")
        for k = n + 1, #W.casts do if W.casts[k].spell ~= "Tiger's Fury" then picked = W.casts[k].spell end end
        break
      end
      M.press("cat")
    end
    check(picked == "Shred", "picked " .. tostring(picked))
    return "picked " .. picked
  end)

  scenario("farm mode on a raid boss casts Rip", function()
    local M, env, W, F = boot(addonPath)
    run(M, 40, "farm")
    check(M.count("Rip") >= 1, "no Rip in 40s of /fdps farm on a boss (Faerie Fire " .. M.count("Faerie Fire (Feral)") .. ")")
    check(F.spec == "farm", "saved spec changed to " .. tostring(F.spec))
    return "Rip " .. M.count("Rip") .. ", Faerie Fire " .. M.count("Faerie Fire (Feral)")
  end)

  scenario("farm mode on trash still plays farm (no Rip)", function()
    local M, env, W, F = boot(addonPath)
    W.zone, W.raid = "Scholomance", 0
    M.setTarget("add")
    run(M, 40, "farm")
    check(M.count("Rip") == 0, "Rip cast " .. M.count("Rip") .. " times in farm on trash")
  end)

  scenario("Lucifron's Curse: no refused presses, no Reshift", function()
    local M, env, W, F = boot(addonPath)
    run(M, 10)
    W.curse = true
    table.insert(W.debuffs, { name = "Lucifron's Curse", tex = "Interface\\Icons\\Spell_Shadow_BlackPlague" })
    local e0, r0 = #W.errors, M.count("Reshift")
    run(M, 30)
    local refused = #W.errors - e0
    check(refused <= 2, refused .. " refused presses under the curse in 30s")
    check(M.count("Reshift") == r0, "Reshift used under the curse")
    W.curse = false; W.debuffs = {}
    run(M, 20)
    check(F.costs["Shred"] == 48, "Shred cost after the curse: " .. tostring(F.costs["Shred"]))
    return refused .. " refused presses in 30s"
  end)

  scenario("a refused potion is not pressed every second", function()
    local M, env, W, F = boot(addonPath, function(M, env, W)
      env.FeralDPS_Settings.useRagePot = true
      W.items[1] = { id = 13442, name = "Mighty Rage Potion", cd = 120 }
    end)
    W.refuseItems = true
    local dec = 0
    env.FeralDPS.OnDecision = function(spell) if spell == "Mighty Rage Potion" then dec = dec + 1 end end
    run(M, 45)
    local presses = M.count("ITEM Mighty Rage Potion")
    check(presses >= 1, "the potion was never pressed, the test proves nothing")
    check(presses <= 4, presses .. " potion presses in 45s while the game refuses it")
    check(dec == 0, dec .. " refused presses reported as used")
    return presses .. " presses in 45s, 0 reported as used"
  end)

  scenario("an accepted potion is reported once", function()
    local M, env, W, F = boot(addonPath, function(M, env, W)
      env.FeralDPS_Settings.useRagePot = true
      W.items[1] = { id = 13442, name = "Mighty Rage Potion", cd = 120 }
    end)
    local dec = 0
    env.FeralDPS.OnDecision = function(spell) if spell == "Mighty Rage Potion" then dec = dec + 1 end end
    run(M, 45)
    check(M.count("ITEM Mighty Rage Potion") == 1 and dec == 1, "presses " .. M.count("ITEM Mighty Rage Potion") .. ", reported " .. dec)
  end)

  scenario("'Already looted' after a Reshift does not hold Reshift", function()
    local M, env, W, F = boot(addonPath)
    local done
    run(M, 60, "cat", function()
      if not done and M.count("Reshift") >= 1 and (W.t - F.lastReshiftTime) < 0.25 then
        done = true
        M.uierr("Already looted")
      end
    end)
    check(done, "no Reshift happened")
    check(F.reshiftHoldUntil == 0, "Reshift was put on hold until " .. tostring(F.reshiftHoldUntil))
  end)

  scenario("another cat's Rip on a new target is not taken for ours", function()
    local M, env, W, F = boot(addonPath)
    run(M, 25)
    check(env.FeralDPS.State().rip > 0, "no Rip on the boss after 25s")
    table.insert(W.targets.add.deb, { name = "Rip", tex = "Interface\\Icons\\Ability_GhoulFrenzy", id = 9896, untilT = W.t + 60 })
    M.setTarget("add")
    M.step(0.1)
    local onAdd = env.FeralDPS.State().rip
    M.setTarget("boss")
    M.step(0.1)
    local back = env.FeralDPS.State().rip
    check(onAdd == 0, string.format("on the add the addon shows our Rip with %.1fs", onAdd))
    check(back > 0, "back on the boss our Rip reads 0")
    return string.format("add: %.1f, back on the boss: %.1fs", onAdd, back)
  end)

  scenario("full debuff bar: our hidden Rip survives a target swap", function()
    local M, env, W, F = boot(addonPath)
    W.targets.boss.filler = 16
    run(M, 25)
    check(env.FeralDPS.State().rip > 0, "no Rip tracked on a full bar")
    M.setTarget("add"); M.step(0.1); M.setTarget("boss"); M.step(0.1)
    local back = env.FeralDPS.State().rip
    check(back > 0, "back on the boss our hidden Rip reads 0")
    run(M, 30)
    check(M.count("Rip") <= 2, "Rip recast " .. M.count("Rip") .. " times")
    return string.format("%.1fs after the swap, Rip casts in 55s: %d", back, M.count("Rip"))
  end)

  if isNew then
    scenario("/fdps step: one short step, then stop", function()
      local M, env, W, F = boot(addonPath)
      M.press("step")
      check(F.useStep == true, "step did not turn on")
      run(M, 10)
      M.fire("CHAT_MSG_COMBAT_SELF_HITS", "You hit Chromaggus for 300.")
      check(F.meleeDist == 3, "melee distance not recorded: " .. tostring(F.meleeDist))
      W.dist = 5.5; W.energy = 100
      run(M, 1.0)
      check(W.moved == 1, "steps taken in 1s: " .. W.moved)
      check(W.moving == false, "still walking after the step")
      W.dist = 12
      run(M, 4)
      check(W.moved <= 2, "kept stepping at 12 yd: " .. W.moved)
      W.dist = 3; W.behind = false
      return "1 step at 2.5 yd beyond reach, none at 9 yd beyond"
    end)
    scenario("/fdps step off: never moves", function()
      local M, env, W, F = boot(addonPath)
      run(M, 5); W.dist = 6.5; run(M, 5)
      check(W.moved == 0, "moved with step off")
    end)
  end
  return table.concat(out, "\n")
end
