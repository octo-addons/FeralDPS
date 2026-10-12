-- FeralTrack.lua
-- Companion to FeralDPS: measures how the rotation actually performed.
-- ShaguDPS tells you the damage; this tells you where it leaked.
--
-- A "run" is one stretch of combat (auto), a whole dungeon or raid (started
-- and stopped by the zone: walk in and it starts, walk out and it reports),
-- or a manual /ftrack start … stop.
-- For every run it records:
--   uptime   Rip / Rake / Tiger's Fury / Faerie Fire, as % of cat time
--   leaks    TF gaps, Rip gaps, seconds capped at 100 energy, idle GCDs, fronting
--   damage   total damage and DPS from the combat log
--   casts    per ability, and how often the rotation wanted something it could not afford
--   misses   miss / dodge / parry / resist per ability and for auto attacks
--   procs    Omen of Clarity procs and how many were spent, Berserk timings,
--            Carnage refreshes FeralDPS detected
--
-- Commands:
--   /ftrack                 - report on the last run
--   /ftrack report <label>  - report on a named run
--   /ftrack start <label>   - start a MANUAL run: spans every fight until /ftrack stop
--                             (a whole dungeon as one run; only combat time counts)
--   /ftrack stop            - end the current run
--   /ftrack fights [label]  - every fight of a run: who, how long, DPS, what leaked
--   /ftrack instance        - toggle the automatic run per dungeon/raid (default on)
--   /ftrack label <label>   - label the NEXT automatic run
--   /ftrack list            - last runs
--   /ftrack compare A B     - two runs side by side
--   /ftrack auto            - toggle automatic runs per combat (default on)
--   /ftrack warn            - toggle live warnings (default on)
--   /ftrack rate            - toggle the live "presses/s" line (default on)
--   /ftrack min <sec>       - only report automatic runs longer than this (default 20)
--   /ftrack clear           - forget saved runs

FeralTrack = {}

local T_ = {
  run      = nil,       -- the run being recorded
  runs     = {},        -- finished runs, newest last
  auto     = true,
  warn     = true,
  instAuto = true,      -- one run per dungeon / raid, driven by the zone
  warnPos  = nil,       -- where the warning box was dragged { left=, bottom= }
  paused   = nil,       -- { run=, zone=, pausedAt= } after leaving an instance
  zoneCheckAt = nil,    -- the zone is read a moment after the zone event
  minRun   = 20,
  nextLabel = nil,
  autoCount = 0,

  lastSample = 0,
  lastCast   = 0,
  prevCC     = false,
  ccSpent    = false,
  ripSeen    = false,
  tfGapStart  = nil,
  ripGapStart = nil,

  lastPress = nil,      -- time of the last rotation-key press (combat only)
  pressLog  = {},       -- presses in the last 5 s, for the live rate
  showRate  = true,     -- /ftrack rate toggles the live presses/s line

  hud = {},
}

local MAX_RUNS = 40

-- ============================================================
-- helpers
-- ============================================================
-- All output follows FeralDPS's chat-tab setting (/fdps chat <tab>)
local function out(text)
  if FeralDPS and FeralDPS.Out then FeralDPS.Out(text) else DEFAULT_CHAT_FRAME:AddMessage(text) end
end

local function msg(text)
  out("|cFF7FD4FFFeralTrack|r " .. text)
end

local function fmtN(n)
  n = math.floor(n + 0.5)
  local s = tostring(n)
  local out = ""
  local len = string.len(s)
  local i = len
  while i > 0 do
    local j = i - 2
    if j < 1 then j = 1 end
    out = string.sub(s, j, i) .. (out ~= "" and ("." .. out) or "")
    i = j - 1
  end
  return out
end

local function fmtT(sec)
  sec = math.floor(sec + 0.5)
  local m = math.floor(sec / 60)
  local s = sec - m * 60
  if s < 10 then return m .. ":0" .. s end
  return m .. ":" .. s
end

local function pct(part, whole)
  if not whole or whole <= 0 then return "--" end
  return math.floor(part / whole * 100 + 0.5) .. "%"
end

local function state()
  if FeralDPS and FeralDPS.State then return FeralDPS.State() end
  return nil
end

-- ============================================================
-- run lifecycle
-- ============================================================
local function newRun(label)
  local st = state()
  return {
    label   = label,
    start   = GetTime(),
    stop    = nil,
    spec    = st and st.spec or "?",
    manual  = false,
    combatTime = 0,
    fights  = 0,
    longest = 0,
    fightStart = nil,
    catTime = 0,
    ripUp = 0, rakeUp = 0, tfUp = 0, ffUp = 0,
    capped = 0, idle = 0, fronting = 0,
    tfGapN = 0, tfGapS = 0, ripGapN = 0, ripGapS = 0,
    damage = 0,
    casts   = {},
    blocked = {},
    -- presses the client refused (UI error right after the press), by spell and
    -- by reason: "not ready" (own cooldown), "behind", "range", "stunned"...
    failed  = {},
    failWhy = {},
    miss    = {},   -- miss[ability] = { miss=, dodge=, parry=, resist= }
    berserk = {},
    carnage0 = st and st.carnage or 0,
    carnage  = 0,
    ccProcs = 0, ccUsed = 0,
    -- button presses while in combat: how hard the rotation key is worked
    presses = 0, pressGapN = 0, pressGapS = 0, pressMaxGap = 0,
    -- bear: seconds without rage for a Maul, and seconds at 90+ rage (waste)
    bearTime = 0, starved = 0, rageCapped = 0,
  }
end

local function closeGaps(run, now)
  if T_.tfGapStart then
    local g = now - T_.tfGapStart
    if g > 2 then run.tfGapN = run.tfGapN + 1; run.tfGapS = run.tfGapS + g end
    T_.tfGapStart = nil
  end
  if T_.ripGapStart then
    local g = now - T_.ripGapStart
    if g > 2 then run.ripGapN = run.ripGapN + 1; run.ripGapS = run.ripGapS + g end
    T_.ripGapStart = nil
  end
end

-- Carnage refreshes come from a FeralDPS session counter that restarts on
-- every reload, so the run banks the difference whenever it is saved.
local function syncCarnage(run)
  local st = state()
  if not st or not run then return end
  run.carnage  = run.carnage + (st.carnage - run.carnage0)
  run.carnage0 = st.carnage
end

local function saveRuns()
  FeralTrack_Settings = FeralTrack_Settings or {}
  FeralTrack_Settings.auto   = T_.auto
  FeralTrack_Settings.warn   = T_.warn
  FeralTrack_Settings.instance = T_.instAuto
  FeralTrack_Settings.warnPos  = T_.warnPos
  FeralTrack_Settings.showRate = T_.showRate
  FeralTrack_Settings.minRun = T_.minRun
  FeralTrack_Settings.runs   = T_.runs
  -- The run in progress is stashed too, so a logout or crash mid-dungeon does
  -- not lose it: it is resumed at next login until /ftrack stop closes it.
  if T_.run then syncCarnage(T_.run) end
  FeralTrack_Settings.current = T_.run
end

local printReport   -- forward declaration

-- ---- per-fight log --------------------------------------------------------
-- A dungeon run is many fights, and "sometimes great DPS, sometimes none" is
-- a question about the fights, not the total. So every fight inside a run is
-- logged with its own numbers, as the difference between the run's counters
-- at the start and at the end of the fight.
local function sumTable(t)
  local n = 0
  for _, v in pairs(t or {}) do n = n + v end
  return n
end

local function copyTable(t)
  local c = {}
  for k, v in pairs(t or {}) do c[k] = v end
  return c
end

local function fightOpen(run)
  run.fs = {
    damage = run.damage, capped = run.capped, fronting = run.fronting, idle = run.idle,
    combatTime = run.combatTime, bearTime = run.bearTime or 0,
    refused = sumTable(run.failed), why = copyTable(run.failWhy), presses = run.presses or 0,
    ff = (run.casts["Faerie Fire (Feral)"] or 0),
    casts = copyTable(run.casts), ripUp = run.ripUp,
    target = (UnitExists("target") and UnitCanAttack("player", "target")) and UnitName("target") or nil,
    tag = run.tag,
  }
end

local CAST_SHORT = { ["Shred"] = "Shr", ["Claw"] = "Clw", ["Rip"] = "Rip", ["Ferocious Bite"] = "FB",
                     ["Rake"] = "Rk", ["Tiger's Fury"] = "TF", ["Faerie Fire (Feral)"] = "FF",
                     ["Berserk"] = "Bsk", ["Maul"] = "Maul", ["Swipe"] = "Swp", ["Savage Bite"] = "SB",
                     ["Demoralizing Roar"] = "Demo", ["Enrage"] = "Enr", ["Ravage"] = "Rav", ["Pounce"] = "Pnc",
                     ["Mighty Rage Potion"] = "Pot", ["Juju Flurry"] = "Juju", ["Reshift"] = "Rsh" }
local CAST_ORDER = { "Shred", "Claw", "Rip", "Ferocious Bite", "Rake", "Tiger's Fury", "Faerie Fire (Feral)",
                     "Berserk", "Maul", "Swipe", "Savage Bite", "Demoralizing Roar", "Enrage", "Ravage", "Pounce",
                     "Mighty Rage Potion", "Juju Flurry", "Reshift" }

local function fightClose(run)
  local fs = run.fs
  if not fs then return end
  run.fs = nil
  local dur = run.combatTime - fs.combatTime
  if dur < 3 then return end
  -- refusal reasons of this fight alone, as "range 5 not ready 2"
  local why = ""
  for w, n in pairs(run.failWhy or {}) do
    local d = n - (fs.why[w] or 0)
    if d > 0 then why = why .. w .. " " .. d .. " " end
  end
  -- casts of this fight alone, as "Shr 7 Rip 1 FB 2"
  local casts = ""
  for i = 1, table.getn(CAST_ORDER) do
    local sp = CAST_ORDER[i]
    local d = (run.casts[sp] or 0) - ((fs.casts or {})[sp] or 0)
    if d > 0 then casts = casts .. (CAST_SHORT[sp] or sp) .. " " .. d .. " " end
  end
  run.fightLog = run.fightLog or {}
  table.insert(run.fightLog, {
    t = GetTime() - run.start, target = fs.target or "?", dur = dur,
    bear = (run.bearTime or 0) - fs.bearTime,
    dmg = run.damage - fs.damage, capped = run.capped - fs.capped,
    front = run.fronting - fs.fronting, idle = run.idle - fs.idle,
    refused = sumTable(run.failed) - fs.refused, why = why,
    presses = (run.presses or 0) - fs.presses,
    ff = (run.casts["Faerie Fire (Feral)"] or 0) - fs.ff,
    casts = casts, ripUp = run.ripUp - (fs.ripUp or run.ripUp),
    tag = fs.tag,
  })
  while table.getn(run.fightLog) > 80 do table.remove(run.fightLog, 1) end
end

-- The saved list is capped. When it is full, the oldest plain automatic run
-- (#12, #13 ... one per fight) goes first; a run with a name - a dungeon,
-- a raid, or one started by hand - is only dropped when no automatic run is
-- left to drop. An MC evening once got pushed out by 38 single-fight runs.
local function trimRuns()
  while table.getn(T_.runs) > MAX_RUNS do
    local victim = 1
    for i = 1, table.getn(T_.runs) do
      local r = T_.runs[i]
      if not r.manual and not r.zone then victim = i; break end
    end
    table.remove(T_.runs, victim)
  end
end

local function addRun(run)
  table.insert(T_.runs, run)
  trimRuns()
end

local function startRun(label, manual)
  if T_.run then
    -- end the current one quietly
    T_.run.stop = GetTime()
    closeGaps(T_.run, T_.run.stop)
    fightClose(T_.run)
    addRun(T_.run)
  end
  if not label then
    T_.autoCount = T_.autoCount + 1
    label = T_.nextLabel or ("#" .. T_.autoCount)
    T_.nextLabel = nil
  end
  T_.run = newRun(label)
  T_.run.manual = manual and true or false
  if UnitAffectingCombat("player") then
    T_.run.fightStart = GetTime()
    T_.run.fights = 1
    fightOpen(T_.run)
  end
  T_.lastSample = GetTime()
  T_.lastCast   = GetTime()
  T_.ripSeen    = false
  T_.tfGapStart, T_.ripGapStart = nil, nil
  local st = state()
  T_.prevCC = st and st.clearcast or false
end

local function stopRun(announce)
  local run = T_.run
  if not run then return end
  local now = GetTime()
  run.stop = now
  if run.fightStart then
    local f = now - run.fightStart
    if f > run.longest then run.longest = f end
    run.fightStart = nil
  end
  closeGaps(run, now)
  fightClose(run)
  syncCarnage(run)
  T_.run = nil

  local dur = run.combatTime
  addRun(run)
  saveRuns()

  if announce and dur >= T_.minRun then
    printReport(run)
  elseif announce then
    msg(string.format("run %s ended (%s) — under %ds, not reported. /ftrack report %s to see it anyway.",
      run.label, fmtT(dur), T_.minRun, run.label))
  end
end

-- ============================================================
-- instances - a run per dungeon / raid, started and stopped by the zone
-- ============================================================
-- Walking into an instance starts a run labelled after it (BRS-30/09-21:14),
-- walking out closes it and prints the report. A wipe is not the end of the
-- run: release, run back, and if you are inside again within 30 minutes the
-- same run continues. A run started by hand (/ftrack start) is never touched.
local INSTANCE_SHORT = {
  ["Blackrock Spire"] = "BRS", ["Blackrock Depths"] = "BRD", ["Molten Core"] = "MC",
  ["Onyxia's Lair"] = "Ony", ["Blackwing Lair"] = "BWL", ["Zul'Gurub"] = "ZG",
  ["Ruins of Ahn'Qiraj"] = "AQ20", ["Ahn'Qiraj"] = "AQ40", ["Naxxramas"] = "Naxx",
  ["Stratholme"] = "Strat", ["Scholomance"] = "Scholo", ["Dire Maul"] = "DM",
  ["Temple of Atal'Hakkar"] = "ST", ["Maraudon"] = "Mara", ["Zul'Farrak"] = "ZF",
  ["Uldaman"] = "Ulda", ["Razorfen Downs"] = "RFD", ["Razorfen Kraul"] = "RFK",
  ["Scarlet Monastery"] = "SM", ["The Deadmines"] = "VC", ["Wailing Caverns"] = "WC",
  ["Shadowfang Keep"] = "SFK", ["Blackfathom Deeps"] = "BFD", ["The Stockade"] = "Stocks",
  ["Gnomeregan"] = "Gnomer", ["Ragefire Chasm"] = "RFC",
  -- Turtle WoW
  ["Lower Karazhan Halls"] = "Kara10", ["Upper Karazhan Halls"] = "Kara40",
  ["Karazhan Crypt"] = "Crypt", ["Emerald Sanctum"] = "ES", ["Hateforge Quarry"] = "HFQ",
  ["Gilneas City"] = "Gilneas", ["Stormwind Vault"] = "Vault", ["The Black Morass"] = "BM",
  ["Black Morass"] = "BM", ["Crescent Grove"] = "CG", ["Stormwrought Ruins"] = "SWR",
  ["Dragonmaw Retreat"] = "DR", ["The Crescent Grove"] = "CG",
  -- battlegrounds count as instances too
  ["Warsong Gulch"] = "WSG", ["Arathi Basin"] = "AB", ["Alterac Valley"] = "AV",
}
local RESUME_WINDOW = 30 * 60

-- Is the player inside an instance right now, and which one?
-- IsInInstance() is asked first; without it, the zone name has to be on the
-- list above.
local function inInstanceNow()
  local zone = GetRealZoneText() or ""
  if zone == "" then return nil, zone end          -- not known yet (loading)
  if type(IsInInstance) == "function" then
    local ok, inst = pcall(IsInInstance)
    if ok then
      if inst and inst ~= 0 then return true, zone end
      return false, zone
    end
  end
  if INSTANCE_SHORT[zone] then return true, zone end
  return false, zone
end

local function instanceLabel(zone)
  local short = INSTANCE_SHORT[zone] or zone
  local stamp = (type(date) == "function") and date("%d/%m-%H:%M") or ""
  local label = short .. "-" .. stamp
  -- a second run for the same instance within the same minute (/ftrack stop
  -- inside it) gets a suffix so /ftrack report finds the right one
  local n = 1
  local function taken(l)
    for i = 1, table.getn(T_.runs) do if T_.runs[i].label == l then return true end end
    return false
  end
  local unique = label
  while taken(unique) do n = n + 1; unique = label .. "-" .. n end
  return unique
end

-- The paused run is still in the saved list (it was closed with a report);
-- to continue it, it is taken out again and reopened.
local function resumeRun(run)
  if T_.run then
    T_.run.stop = GetTime()
    closeGaps(T_.run, T_.run.stop)
    fightClose(T_.run)
    addRun(T_.run)
  end
  for i = table.getn(T_.runs), 1, -1 do
    if T_.runs[i] == run then table.remove(T_.runs, i); break end
  end
  run.stop = nil
  run.fightStart = nil
  run.fs = nil
  T_.run = run
  T_.lastSample = GetTime()
  T_.lastCast   = GetTime()
  T_.ripSeen    = false
  T_.tfGapStart, T_.ripGapStart = nil, nil
  if UnitAffectingCombat("player") then
    run.fightStart = GetTime()
    run.fights = run.fights + 1
    fightOpen(run)
  end
  saveRuns()
end

local function checkZone()
  if not T_.instAuto then return end
  local inside, zone = inInstanceNow()
  if inside == nil then return end
  local run = T_.run
  if inside then
    if run and run.zone == zone then return end                -- already on it
    if run and run.manual and not run.zone then return end     -- a hand-started run is left alone
    local p = T_.paused
    if p and p.zone == zone and (GetTime() - p.pausedAt) < RESUME_WINDOW then
      T_.paused = nil
      resumeRun(p.run)
      msg("back in " .. zone .. " — run |cFFFFFFFF" .. p.run.label .. "|r continues ("
        .. fmtT(p.run.combatTime) .. " in combat so far).")
      return
    end
    T_.paused = nil
    if run and run.zone then stopRun(true) end                 -- straight from one instance into another
    startRun(instanceLabel(zone), true)
    T_.run.zone = zone
    saveRuns()
    msg("run |cFFFFFFFF" .. T_.run.label .. "|r started — every fight in " .. zone
      .. " counts until you leave. |cFFFFFFFF/ftrack|r shows it live.")
  else
    if run and run.zone then
      local r = run
      stopRun(true)
      T_.paused = { run = r, zone = r.zone, pausedAt = GetTime() }
      msg("left " .. r.zone .. " — run |cFFFFFFFF" .. r.label .. "|r closed. Back inside within 30 min and it continues.")
    end
  end
end

-- ============================================================
-- sampling (0.1s) - uptime, leaks, live warnings
-- ============================================================
local function sample()
  local now = GetTime()
  if T_.zoneCheckAt and now >= T_.zoneCheckAt then
    T_.zoneCheckAt = nil
    checkZone()
  end
  local dt  = now - T_.lastSample
  T_.lastSample = now
  if dt <= 0 or dt > 2 then return end        -- first tick / loading screen

  local st = state()
  if not st then return end
  local run = T_.run

  -- Clearcasting procs are counted whether or not a run is open, but stored on the run
  local cc = st.clearcast
  if cc and not T_.prevCC then
    if run then run.ccProcs = run.ccProcs + 1 end
    T_.ccSpent = false
  end
  T_.prevCC = cc

  local isCat = (st.spec == "cat" or st.spec == "farm")
  -- the run's spec label follows the spec actually in use in combat (it used
  -- to be whatever was set when the run began - "farm" from an afternoon of
  -- farming stuck on a whole ZG evening played with the Cat button)
  if run and st.inCombat and st.spec then run.spec = st.spec end

  -- Out of combat nothing is measured: a manual run that spans a whole dungeon
  -- must not count the walk between pulls as "Tiger's Fury down" or idle time.
  if not st.inCombat then
    T_.tfGapStart, T_.ripGapStart = nil, nil
    T_.ripSeen = false
    T_.lastPress = nil          -- the walk between pulls is not a "pause"
    if T_.hud.frame then T_.hud.frame:Hide() end
    return
  end

  if run then run.combatTime = run.combatTime + dt end

  if run and not isCat then
    run.bearTime   = (run.bearTime or 0) + dt
    local maulCost = (st.costs and st.costs["Maul"]) or 10
    if st.power < maulCost then run.starved = (run.starved or 0) + dt end
    if st.power >= 90 then run.rageCapped = (run.rageCapped or 0) + dt end
  end

  if run and isCat then
    run.catTime = run.catTime + dt
    if st.rip  > 0 then run.ripUp  = run.ripUp  + dt; T_.ripSeen = true end
    if st.rake > 0 then run.rakeUp = run.rakeUp + dt end
    if st.tf   > 0 then run.tfUp   = run.tfUp   + dt end
    if st.ff   > 0 then run.ffUp   = run.ffUp   + dt end
    if st.power >= 100 then run.capped = run.capped + dt end
    if UnitXP and not st.behind and UnitExists("target") then run.fronting = run.fronting + dt end

    -- "Idle" = energy for the builder the rotation actually wants, and no
    -- cast for 1.5s. Behind the target that builder is Shred (48), not Claw
    -- (37): counting from Claw's cost flagged the normal wait from 37 to 48
    -- energy as idle time (32s on a 4-minute dummy run).
    local builderCost
    if st.behind then
      builderCost = (st.costs and st.costs["Shred"]) or 48
    else
      builderCost = (st.costs and st.costs["Claw"]) or 40
    end
    if (now - T_.lastCast) > 1.5 and st.power >= builderCost then
      run.idle = run.idle + dt
    end

    -- gap tracking
    if st.useTF then
      if st.tf <= 0 then
        if not T_.tfGapStart then T_.tfGapStart = now end
      elseif T_.tfGapStart then
        local g = now - T_.tfGapStart
        if g > 2 then run.tfGapN = run.tfGapN + 1; run.tfGapS = run.tfGapS + g end
        T_.tfGapStart = nil
      end
    end
    if T_.ripSeen then
      if st.rip <= 0 then
        if not T_.ripGapStart then T_.ripGapStart = now end
      elseif T_.ripGapStart then
        local g = now - T_.ripGapStart
        if g > 2 then run.ripGapN = run.ripGapN + 1; run.ripGapS = run.ripGapS + g end
        T_.ripGapStart = nil
      end
    end
  end

  -- live warnings
  local h = T_.hud
  if h.frame then
    local lines = {}
    if T_.warn and isCat and st.inCombat then
      if st.useTF and T_.tfGapStart and (now - T_.tfGapStart) > 3 then
        table.insert(lines, string.format("|cFFFF6A00TIGER'S FURY DOWN %.0fs|r", now - T_.tfGapStart))
      end
      if st.power >= 100 then
        table.insert(lines, "|cFFFFD700ENERGY CAPPED|r")
      end
      if T_.ripSeen and st.rip <= 0 and st.cp >= 5 then
        table.insert(lines, "|cFFFF3333RIP DOWN - 5 CP|r")
      end
    end
    -- live press rate: presses in the last 5 seconds
    if T_.showRate and st.inCombat then
      local cnt = 0
      for i = 1, table.getn(T_.pressLog) do
        if now - T_.pressLog[i] <= 5 then cnt = cnt + 1 end
      end
      table.insert(lines, string.format("|cFFAAAAAA%.1f presses/s|r", cnt / 5))
    end
    local n = table.getn(lines)
    for i = 1, 4 do
      h.line[i]:SetText(lines[i] or "")
    end
    h.frame:SetHeight(10 + n * 16)
    if n > 0 then h.frame:Show() else h.frame:Hide() end
  end
end

-- ============================================================
-- press hook from FeralDPS - every press of the rotation key
-- ============================================================
local function onPress()
  local now = GetTime()
  -- rolling log for the live rate (kept to the last 5 seconds)
  table.insert(T_.pressLog, now)
  while table.getn(T_.pressLog) > 0 and (now - T_.pressLog[1]) > 5 do
    table.remove(T_.pressLog, 1)
  end

  local run = T_.run
  if not run or not UnitAffectingCombat("player") then
    T_.lastPress = now
    return
  end
  run.presses = (run.presses or 0) + 1
  if T_.lastPress then
    local g = now - T_.lastPress
    if g > 1.0 then
      run.pressGapN = (run.pressGapN or 0) + 1
      run.pressGapS = (run.pressGapS or 0) + g
      if g > (run.pressMaxGap or 0) then run.pressMaxGap = g end
    end
  end
  T_.lastPress = now
end

-- ============================================================
-- decision hook from FeralDPS
-- ============================================================
local function onDecision(spell, power, cp, affordable, cc)
  local run = T_.run
  if not run then return end
  if affordable then
    run.casts[spell] = (run.casts[spell] or 0) + 1
    T_.lastCast = GetTime()
    if cc and not T_.ccSpent then
      run.ccUsed = run.ccUsed + 1
      T_.ccSpent = true          -- one proc, one spend
    end
    if spell == "Berserk" then
      table.insert(run.berserk, { t = GetTime() - run.start, power = power })
    end
  else
    run.blocked[spell] = (run.blocked[spell] or 0) + 1
  end
end

-- FeralDPS reports a press the client refused ("Spell is not ready yet.",
-- "You must be behind your target.", "Out of range." ...). The decision was
-- already counted as a cast above, so it is moved from casts to failed here -
-- 117 "Faerie Fire casts" in a 9-minute UBRS run turned out to be mostly
-- presses into its own 6s cooldown, and the report should say so.
local function onCastFailed(spell, msg)
  local run = T_.run
  if not run or not spell then return end
  run.failed  = run.failed  or {}
  run.failWhy = run.failWhy or {}
  run.failed[spell] = (run.failed[spell] or 0) + 1
  if (run.casts[spell] or 0) > 0 then run.casts[spell] = run.casts[spell] - 1 end
  local m = string.lower(tostring(msg or ""))
  local why = "other"
  if     string.find(m, "not ready")  then why = "not ready"
  elseif string.find(m, "behind")     then why = "behind"
  elseif string.find(m, "range") or string.find(m, "too far") then why = "range"
  elseif string.find(m, "line of sight") then why = "los"
  elseif string.find(m, "stunned") or string.find(m, "feared") or string.find(m, "can't do that while") then why = "stunned/feared"
  elseif string.find(m, "facing")     then why = "facing"
  elseif string.find(m, "not enough") then why = "no energy"
  elseif string.find(m, "moving")     then why = "moving"
  elseif string.find(m, "combo point") then why = "no cp"
  elseif string.find(m, "debuff bar full") then why = "debuff cap"
  elseif string.find(m, "interrupted") then why = "interrupted"
  elseif string.find(m, "target")     then why = "no target"
  end
  run.failWhy[why] = (run.failWhy[why] or 0) + 1
  if why == "other" then
    -- keep the wording of messages this list does not know, so it can learn them
    run.failOther = run.failOther or {}
    local key = string.sub(tostring(msg), 1, 40)
    if run.failOther[key] or sumTable(run.failOther) < 12 then
      run.failOther[key] = (run.failOther[key] or 0) + 1
    end
  end
end

-- ============================================================
-- combat log - damage and misses
-- ============================================================
local function missRec(run, ability)
  local m = run.miss[ability]
  if not m then
    m = { miss = 0, dodge = 0, parry = 0, resist = 0, block = 0, immune = 0 }
    run.miss[ability] = m
  end
  return m
end

local function onCombatLog(ev, text)
  local run = T_.run
  if not run or not text then return end

  if ev == "CHAT_MSG_COMBAT_SELF_HITS" then
    local _, _, dmg = string.find(text, "^You %a+ .- for (%d+)")
    if dmg then run.damage = run.damage + tonumber(dmg) end

  elseif ev == "CHAT_MSG_COMBAT_SELF_MISSES" then
    local m = missRec(run, "Auto attack")
    if string.find(text, "^You miss") then m.miss = m.miss + 1
    elseif string.find(text, "dodges%.$") then m.dodge = m.dodge + 1
    elseif string.find(text, "parries%.$") then m.parry = m.parry + 1
    elseif string.find(text, "blocks%.$") then m.block = m.block + 1
    end

  elseif ev == "CHAT_MSG_SPELL_SELF_DAMAGE" then
    local _, _, ab, dmg = string.find(text, "^Your (.-) hits .- for (%d+)")
    if not ab then _, _, ab, dmg = string.find(text, "^Your (.-) crits .- for (%d+)") end
    if ab then
      run.damage = run.damage + tonumber(dmg)
      return
    end
    local _, _, abI = string.find(text, "^Your (.-) failed%. .- is immune%.$")
    if abI then
      local mm = missRec(run, abI)
      mm.immune = (mm.immune or 0) + 1
      return
    end
    local _, _, ab2 = string.find(text, "^Your (.-) missed ")
    if ab2 then missRec(run, ab2).miss = missRec(run, ab2).miss + 1; return end
    _, _, ab2 = string.find(text, "^Your (.-) was dodged")
    if ab2 then missRec(run, ab2).dodge = missRec(run, ab2).dodge + 1; return end
    _, _, ab2 = string.find(text, "^Your (.-) was parried")
    if ab2 then missRec(run, ab2).parry = missRec(run, ab2).parry + 1; return end
    _, _, ab2 = string.find(text, "^Your (.-) was resisted")
    if ab2 then missRec(run, ab2).resist = missRec(run, ab2).resist + 1; return end
    _, _, ab2 = string.find(text, "^Your (.-) was blocked")
    if ab2 then missRec(run, ab2).block = missRec(run, ab2).block + 1; return end

  else
    -- periodic: "X suffers N damage from your Rip."
    local _, _, dmg = string.find(text, "suffers (%d+) .-damage from your ")
    if dmg then run.damage = run.damage + tonumber(dmg) end
  end
end

-- ============================================================
-- reports
-- ============================================================
local function findRun(label)
  if not label or label == "" then return T_.runs[table.getn(T_.runs)] end
  -- the run in progress counts too: /ftrack fights ZG-07/10-20:10 while
  -- still inside ZG used to answer "no run named ... yet"
  if T_.run and string.lower(T_.run.label) == string.lower(label) then return T_.run end
  for i = table.getn(T_.runs), 1, -1 do
    if string.lower(T_.runs[i].label) == string.lower(label) then return T_.runs[i] end
  end
  return nil
end

local function castLine(run)
  local order = { "Shred", "Claw", "Rip", "Ferocious Bite", "Rake", "Tiger's Fury",
                  "Faerie Fire (Feral)", "Berserk", "Maul", "Swipe", "Savage Bite",
                  "Demoralizing Roar", "Enrage", "Ravage", "Pounce", "Mighty Rage Potion", "Juju Flurry", "Reshift" }
  local short = { ["Ferocious Bite"] = "FB", ["Tiger's Fury"] = "TF",
                  ["Faerie Fire (Feral)"] = "FF", ["Demoralizing Roar"] = "Demo",
                  ["Savage Bite"] = "SBite", ["Mighty Rage Potion"] = "Pot", ["Juju Flurry"] = "Juju" }
  local out = ""
  for i = 1, table.getn(order) do
    local sp = order[i]
    local n = run.casts[sp]
    if n and n > 0 then
      out = out .. (short[sp] or sp) .. " " .. n .. "  "
    end
  end
  return out
end

local function missLines(run)
  local lines = {}
  for ab, m in pairs(run.miss) do
    local parts = {}
    if m.miss   > 0 then table.insert(parts, m.miss   .. " miss")   end
    if m.dodge  > 0 then table.insert(parts, m.dodge  .. " dodge")  end
    if m.parry  > 0 then table.insert(parts, m.parry  .. " parry")  end
    if m.resist > 0 then table.insert(parts, m.resist .. " resist") end
    if m.block  > 0 then table.insert(parts, m.block  .. " block")  end
    if (m.immune or 0) > 0 then table.insert(parts, m.immune .. " immune") end
    if table.getn(parts) > 0 then
      table.insert(lines, ab .. ": " .. table.concat(parts, ", "))
    end
  end
  return lines
end

printReport = function(run)
  local wall = (run.stop or GetTime()) - run.start
  local ct   = run.combatTime
  local dps  = ct > 0 and (run.damage / ct) or 0
  if run.fights > 1 then
    out(string.format(
      "|cFF7FD4FFFeralTrack|r — run |cFFFFFFFF%s|r  (%d fights, %s in combat of %s, longest %s, %s)",
      run.label, run.fights, fmtT(ct), fmtT(wall), fmtT(run.longest), run.spec))
  else
    out(string.format(
      "|cFF7FD4FFFeralTrack|r — run |cFFFFFFFF%s|r  (%s, %s)", run.label, fmtT(ct), run.spec))
  end
  -- "active" leaves out the idle seconds (energy there, nothing pressed for
  -- 1.5s - typing in chat, tabbing out): what the rotation does while it
  -- is actually being pressed, and the number to compare runs by.
  local active = ct - (run.idle or 0)
  local activeStr = ""
  if (run.idle or 0) > 3 and active > 0 then
    activeStr = string.format("   |cFFAAAAAA%.0f DPS without the %.0fs idle|r", run.damage / active, run.idle)
  end
  out(string.format(
    "  Damage  %s  ->  |cFFFFFFFF%.1f DPS|r (combat time only)%s", fmtN(run.damage), dps, activeStr))

  if run.catTime > 0 then
    local c = run.catTime
    out(string.format(
      "  Uptime  Rip %s   Rake %s   TF %s   FF %s",
      pct(run.ripUp, c), pct(run.rakeUp, c), pct(run.tfUp, c), pct(run.ffUp, c)))
    out(string.format(
      "  Leaks   TF gaps %d (%.1fs)   Rip gaps %d (%.1fs)   capped %.1fs   idle %.1fs   fronting %s",
      run.tfGapN, run.tfGapS, run.ripGapN, run.ripGapS, run.capped, run.idle, pct(run.fronting, c)))
  end

  if (run.bearTime or 0) > 0 then
    local b = run.bearTime
    out(string.format(
      "  Bear    rage-starved %s (%.1fs)   rage capped %s (%.1fs)   of %s in form",
      pct(run.starved or 0, b), run.starved or 0,
      pct(run.rageCapped or 0, b), run.rageCapped or 0, fmtT(b)))
  end

  local bz = ""
  for i = 1, table.getn(run.berserk) do
    local b = run.berserk[i]
    bz = bz .. string.format("%s (%d energy)  ", fmtT(b.t), b.power)
  end
  if bz == "" then bz = "not used" end
  out("  Berserk " .. bz)
  out(string.format(
    "  Procs   OoC %d procs, %d spent   Carnage refreshes %d", run.ccProcs, run.ccUsed, run.carnage))
  local pr = run.presses or 0
  if pr > 0 then
    out(string.format(
      "  Presses %d  ->  |cFFFFFFFF%.1f/s|r   pauses >1s: %d (%.1fs total, longest %.1fs)",
      pr, ct > 0 and pr / ct or 0, run.pressGapN or 0, run.pressGapS or 0, run.pressMaxGap or 0))
  end
  out("  Casts   " .. castLine(run))

  local blocked = ""
  for sp, n in pairs(run.blocked) do blocked = blocked .. sp .. " " .. n .. "  " end
  if blocked ~= "" then
    out("  Wanted but could not afford: " .. blocked)
  end

  local failed, nf = "", 0
  for sp, n in pairs(run.failed or {}) do failed = failed .. sp .. " " .. n .. "  "; nf = nf + n end
  if nf > 0 then
    local why = ""
    for w, n in pairs(run.failWhy or {}) do why = why .. w .. " " .. n .. "  " end
    out(string.format("  |cFFFF6060Refused|r %d presses the client rejected: %s->  %s", nf, failed, why))
    local other = ""
    for m, n in pairs(run.failOther or {}) do other = other .. "\"" .. m .. "\" " .. n .. "  " end
    if other ~= "" then out("          other: " .. other) end
  end

  local ml = missLines(run)
  if table.getn(ml) > 0 then
    out("  Misses  " .. table.concat(ml, " | "))
  end

  -- best and worst fights of the run (8s or longer), so a "sometimes great,
  -- sometimes nothing" dungeon can be pinned to the fights it happened in
  local fl = run.fightLog or {}
  local sorted = {}
  local nCat, dCat, tCat, nBear, dBear, tBear = 0, 0, 0, 0, 0, 0
  for i = 1, table.getn(fl) do
    local f = fl[i]
    local bearish = f.bear and (f.bear / f.dur) >= 0.5
    if bearish then nBear = nBear + 1; dBear = dBear + f.dmg; tBear = tBear + f.dur
    else nCat = nCat + 1; dCat = dCat + f.dmg; tCat = tCat + f.dur end
    -- best/worst is a cat question: bear fights are not low DPS, they are tanking
    if f.dur >= 8 and not bearish then table.insert(sorted, f) end
  end
  if nBear > 0 and nCat > 0 then
    out(string.format("  Fights  %d in cat (%.0f DPS)   %d in bear (%.0f DPS)",
      nCat, tCat > 0 and dCat / tCat or 0, nBear, tBear > 0 and dBear / tBear or 0))
  end
  if table.getn(sorted) >= 3 then
    table.sort(sorted, function(a, b) return (a.dmg / a.dur) > (b.dmg / b.dur) end)
    local n = table.getn(sorted)
    local function one(f)
      local s = string.format("%s %.0fs |cFFFFFFFF%.0f DPS|r", f.target, f.dur, f.dmg / f.dur)
      local why = {}
      if f.capped / f.dur > 0.2 then table.insert(why, string.format("capped %s", pct(f.capped, f.dur))) end
      if f.front  / f.dur > 0.3 then table.insert(why, string.format("front %s",  pct(f.front,  f.dur))) end
      if f.refused >= 3 then table.insert(why, f.refused .. " refused") end
      if table.getn(why) > 0 then s = s .. " (" .. table.concat(why, ", ") .. ")" end
      return s
    end
    out("  Best    " .. one(sorted[1]) .. "  |  " .. one(sorted[2]))
    out("  Worst   " .. one(sorted[n]) .. "  |  " .. one(sorted[n - 1]))
    out("  |cFFAAAAAA/ftrack fights " .. run.label .. " lists all " .. table.getn(fl) .. " fights|r")
  end
end

local function printFights(run)
  local fl = run.fightLog or {}
  local n = table.getn(fl)
  if n == 0 then msg("run " .. run.label .. " has no fights logged."); return end
  msg("fights in |cFFFFFFFF" .. run.label .. "|r (time into run, target, form, length, DPS, capped, fronting, refused presses):")
  local avg = run.combatTime > 0 and (run.damage / run.combatTime) or 0
  for i = 1, n do
    local f = fl[i]
    local dps = f.dmg / f.dur
    local col = "|cFFFFFFFF"
    if avg > 0 and dps < 0.7 * avg then col = "|cFFFF6060" elseif avg > 0 and dps > 1.2 * avg then col = "|cFF60FF60" end
    local form = "cat"
    if f.bear then
      if f.bear / f.dur > 0.8 then form = "bear" elseif f.bear / f.dur > 0.2 then form = "mix" end
    end
    local why = (f.refused or 0) > 0 and (" (" .. (f.why or "") .. ")") or ""
    local name = f.target or "?"
    if f.tag then name = "[" .. f.tag .. "] " .. name end
    out(string.format("  %2d %6s %-22s %-4s %5.0fs %s%5.0f DPS|r  cap %4s  front %4s  refused %2d%s",
      i, fmtT(f.t), string.sub(name, 1, 22), form, f.dur, col, dps,
      pct(f.capped, f.dur), pct(f.front, f.dur), f.refused or 0, why))
    if f.casts and f.casts ~= "" then
      out(string.format("        |cFFAAAAAA%s|r  Rip up %s", f.casts, pct(f.ripUp or 0, f.dur)))
    end
  end
end

-- /ftrack fights garr when no run is called garr: the fights tagged garr
-- (/ftrack start garr inside a raid) from every saved run, newest run first.
local function printTaggedFights(tag)
  local want = string.lower(tag)
  local found = 0
  local list = {}
  for i = 1, table.getn(T_.runs) do table.insert(list, T_.runs[i]) end
  if T_.run then table.insert(list, T_.run) end
  for i = table.getn(list), 1, -1 do
    local run = list[i]
    local sub = { label = run.label, combatTime = 0, damage = 0, fightLog = {} }
    for _, f in ipairs(run.fightLog or {}) do
      if f.tag and string.lower(f.tag) == want then
        table.insert(sub.fightLog, f)
        sub.combatTime = sub.combatTime + f.dur
        sub.damage = sub.damage + f.dmg
      end
    end
    if table.getn(sub.fightLog) > 0 then
      found = found + table.getn(sub.fightLog)
      printFights(sub)
    end
  end
  return found > 0
end

local function compareRuns(a, b)
  local function row(name, va, vb)
    out(string.format("  %-10s %18s   %18s", name, va, vb))
  end
  local da = a.combatTime
  local db = b.combatTime
  out(string.format(
    "|cFF7FD4FFFeralTrack|r compare  |cFFFFFFFF%s|r  vs  |cFFFFFFFF%s|r", a.label, b.label))
  row("Length",  fmtT(da), fmtT(db))
  row("DPS",     string.format("%.1f", da > 0 and a.damage / da or 0),
                 string.format("%.1f", db > 0 and b.damage / db or 0))
  row("Rip up",  pct(a.ripUp, a.catTime),  pct(b.ripUp, b.catTime))
  row("TF up",   pct(a.tfUp, a.catTime),   pct(b.tfUp, b.catTime))
  row("Rake up", pct(a.rakeUp, a.catTime), pct(b.rakeUp, b.catTime))
  row("TF gaps", string.format("%d (%.1fs)", a.tfGapN, a.tfGapS),
                 string.format("%d (%.1fs)", b.tfGapN, b.tfGapS))
  row("Capped",  string.format("%.1fs", a.capped), string.format("%.1fs", b.capped))
  row("Idle",    string.format("%.1fs", a.idle),   string.format("%.1fs", b.idle))
  row("Presses", string.format("%.1f/s", da > 0 and (a.presses or 0) / da or 0),
                 string.format("%.1f/s", db > 0 and (b.presses or 0) / db or 0))
  row("Pauses",  string.format("%d (%.1fs)", a.pressGapN or 0, a.pressGapS or 0),
                 string.format("%d (%.1fs)", b.pressGapN or 0, b.pressGapS or 0))
  row("Berserk", table.getn(a.berserk) .. " uses", table.getn(b.berserk) .. " uses")
  row("Carnage", a.carnage .. "", b.carnage .. "")
  row("OoC",     a.ccProcs .. "/" .. a.ccUsed, b.ccProcs .. "/" .. b.ccUsed)
end

-- ============================================================
-- live warning frame
-- ============================================================
-- The warning box follows the FeralDPS HUD until it is dragged somewhere
-- else; from then on it stays where it was put. /ftrack hudreset re-attaches it.
local function hudApplyPosition(f)
  f:ClearAllPoints()
  local p = T_.warnPos
  if p and p.left and p.bottom then
    f:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", p.left, p.bottom)
  elseif FeralDPSFrame then
    f:SetPoint("TOP", FeralDPSFrame, "BOTTOM", 0, -4)
  else
    f:SetPoint("CENTER", UIParent, "CENTER", 350, -270)
  end
end

local function createHUD()
  local f = CreateFrame("Frame", "FeralTrackWarn", UIParent)
  f:SetWidth(205)
  f:SetHeight(58)
  hudApplyPosition(f)
  f:SetBackdrop({
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
  })
  f:SetBackdropColor(0.25, 0, 0, 0.85)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function() this:StartMoving() end)
  f:SetScript("OnDragStop",  function()
    this:StopMovingOrSizing()
    T_.warnPos = { left = this:GetLeft(), bottom = this:GetBottom() }
    saveRuns()
  end)

  T_.hud.line = {}
  for i = 1, 4 do
    local fs = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("TOP", f, "TOP", 0, -6 - (i - 1) * 16)
    fs:SetText("")
    T_.hud.line[i] = fs
  end
  T_.hud.frame = f
  f:Hide()
end

-- ============================================================
-- setup
-- ============================================================
local function init()
  if FeralTrack_Settings then
    if FeralTrack_Settings.auto   ~= nil then T_.auto   = FeralTrack_Settings.auto   end
    if FeralTrack_Settings.warn   ~= nil then T_.warn   = FeralTrack_Settings.warn   end
    if FeralTrack_Settings.instance ~= nil then T_.instAuto = FeralTrack_Settings.instance end
    if type(FeralTrack_Settings.warnPos) == "table" then T_.warnPos = FeralTrack_Settings.warnPos end
    if FeralTrack_Settings.showRate ~= nil then T_.showRate = FeralTrack_Settings.showRate end
    if FeralTrack_Settings.minRun        then T_.minRun = FeralTrack_Settings.minRun end
    if FeralTrack_Settings.runs          then T_.runs   = FeralTrack_Settings.runs   end
    local cur = FeralTrack_Settings.current
    if cur and cur.manual then
      -- GetTime() restarts with the client, so only the durations carry over
      cur.start = GetTime()
      cur.stop  = nil
      cur.fightStart = nil
      local st = state()
      cur.carnage0 = st and st.carnage or 0
      T_.run = cur
      T_.lastSample = GetTime()
      T_.lastCast   = GetTime()
      msg("resumed unfinished run |cFFFFFFFF" .. cur.label .. "|r ("
        .. fmtT(cur.combatTime) .. " in combat so far). |cFFFFFFFF/ftrack stop|r closes it.")
    end
    FeralTrack_Settings.current = nil
  end
  if FeralDPS then
    FeralDPS.OnDecision   = onDecision
    FeralDPS.OnPress      = onPress
    FeralDPS.OnCastFailed = onCastFailed
    msg("loaded — hooked into FeralDPS. Auto runs " .. (T_.auto and "on" or "off")
      .. ", per instance " .. (T_.instAuto and "on" or "off")
      .. ", warnings " .. (T_.warn and "on" or "off") .. ". /ftrack help")
  else
    msg("|cFFFF8800FeralDPS not found|r — only damage and misses will be tracked.")
  end
end

local function cmdHelp()
  out("|cFF7FD4FFFeralTrack|r commands:")
  out("  |cFFFFFFFF/ftrack|r                — report on the last run")
  out("  |cFFFFFFFF/ftrack report <label>|r — report on a named run")
  out("  |cFFFFFFFF/ftrack start <label>|r  — start a labelled run now (inside a raid: tag the coming fights instead)")
  out("  |cFFFFFFFF/ftrack stop|r           — end the current run (inside a raid: end the tag first)")
  out("  |cFFFFFFFF/ftrack fights [label]|r — every fight of a run, or every fight tagged <label>: target, length, DPS, leaks")
  out("  |cFFFFFFFF/ftrack instance|r       — toggle the automatic run per dungeon/raid (on)")
  out("  |cFFFFFFFF/ftrack hudreset|r       — put the warning box back under the HUD (it remembers where you drag it)")
  out("  |cFFFFFFFF/ftrack label <label>|r  — label the next automatic run")
  out("  |cFFFFFFFF/ftrack list|r           — last runs")
  out("  |cFFFFFFFF/ftrack compare A B|r    — two runs side by side")
  out("  |cFFFFFFFF/ftrack auto|r / |cFFFFFFFFwarn|r / |cFFFFFFFFrate|r — toggle auto runs / live warnings / presses/s")
  out("  |cFFFFFFFF/ftrack min <sec>|r      — minimum length for auto reports")
  out("  |cFFFFFFFF/ftrack clear|r          — forget saved runs")
end

function FeralTrack_OnLoad()
  SLASH_FTRACK1 = "/ftrack"
  SLASH_FTRACK2 = "/feraltrack"

  SlashCmdList["FTRACK"] = function(input)
    input = input or ""
    local _, _, cmd, rest = string.find(input, "^%s*(%S*)%s*(.-)%s*$")
    cmd = string.lower(cmd or "")

    if cmd == "" or cmd == "report" then
      if T_.run and cmd == "" then
        msg("recording run " .. T_.run.label .. " — live view:")
        printReport(T_.run)
        return
      end
      local run = findRun(rest)
      if run then printReport(run) else msg("no run" .. (rest ~= "" and (" named " .. rest) or "") .. " yet.") end

    elseif cmd == "start" then
      if T_.run and T_.run.zone then
        -- inside a dungeon/raid the instance run keeps going; the name given
        -- here tags the fights from now on (the open one too) instead, so
        -- /ftrack fights garr finds the boss later. /ftrack stop clears the tag.
        local tag = rest ~= "" and rest or nil
        T_.run.tag = tag
        if T_.run.fs then T_.run.fs.tag = tag end
        if tag then
          msg("run |cFFFFFFFF" .. T_.run.label .. "|r is recording all of " .. T_.run.zone
            .. " — the fights from now on are tagged |cFFFFFFFF" .. tag .. "|r instead of starting a new run. "
            .. "|cFFFFFFFF/ftrack fights " .. tag .. "|r shows them, |cFFFFFFFF/ftrack stop|r ends the tag.")
        else
          msg("run |cFFFFFFFF" .. T_.run.label .. "|r is already recording all of " .. T_.run.zone
            .. ". Give a name (/ftrack start garr) to tag the coming fights.")
        end
      else
        startRun(rest ~= "" and rest or nil, true)
        msg("manual run |cFFFFFFFF" .. T_.run.label .. "|r started — spans every fight until /ftrack stop.")
      end

    elseif cmd == "stop" then
      if T_.run and T_.run.zone and T_.run.tag then
        local tag = T_.run.tag
        T_.run.tag = nil
        if T_.run.fs then T_.run.fs.tag = nil end
        msg("tag |cFFFFFFFF" .. tag .. "|r ended — run |cFFFFFFFF" .. T_.run.label
          .. "|r goes on until you leave " .. T_.run.zone .. ". /ftrack stop again to close the run itself.")
      elseif T_.run and T_.run.zone then
        local zone = T_.run.zone
        T_.paused = nil
        stopRun(true)
        -- still inside: the next pull starts a fresh run for the instance,
        -- so it does not fall apart into one automatic run per fight
        T_.zoneCheckAt = GetTime()
        msg("still in " .. zone .. " — a new run starts for the rest of it. /ftrack instance turns the instance runs off.")
      elseif T_.run then
        T_.paused = nil; stopRun(true)
      else
        msg("no run in progress.")
      end

    elseif cmd == "fights" then
      local run = (rest == "" and T_.run) or findRun(rest)
      if run then
        printFights(run)
      elseif rest ~= "" and printTaggedFights(rest) then
        -- printed the tagged fights
      else
        msg("no run" .. (rest ~= "" and (" named " .. rest) or "") .. " yet.")
      end

    elseif cmd == "hudreset" then
      T_.warnPos = nil
      if T_.hud.frame then hudApplyPosition(T_.hud.frame) end
      saveRuns()
      msg("warning box back under the FeralDPS HUD.")

    elseif cmd == "instance" then
      T_.instAuto = not T_.instAuto; saveRuns()
      msg("automatic run per dungeon/raid " .. (T_.instAuto and "|cFF00FF00on|r" or "|cFFFF4444off|r"))
      if T_.instAuto then T_.zoneCheckAt = GetTime() end

    elseif cmd == "label" then
      T_.nextLabel = rest ~= "" and rest or nil
      msg("next automatic run will be labelled |cFFFFFFFF" .. tostring(T_.nextLabel) .. "|r.")

    elseif cmd == "list" then
      local n = table.getn(T_.runs)
      if n == 0 then msg("no runs saved."); return end
      msg("runs (newest last):")
      for i = 1, n do
        local r = T_.runs[i]
        local d = r.combatTime
        out(string.format("  %-12s %6s  %2d fights  %8.1f DPS  Rip %s  TF %s",
          r.label, fmtT(d), r.fights, d > 0 and r.damage / d or 0, pct(r.ripUp, r.catTime), pct(r.tfUp, r.catTime)))
      end

    elseif cmd == "compare" then
      local _, _, la, lb = string.find(rest, "^(%S+)%s+(%S+)")
      local a, b = findRun(la), findRun(lb)
      if a and b then compareRuns(a, b) else msg("usage: /ftrack compare A B (both must exist — see /ftrack list)") end

    elseif cmd == "auto" then
      T_.auto = not T_.auto; saveRuns()
      msg("automatic runs " .. (T_.auto and "|cFF00FF00on|r" or "|cFFFF4444off|r"))

    elseif cmd == "warn" then
      T_.warn = not T_.warn; saveRuns()
      msg("live warnings " .. (T_.warn and "|cFF00FF00on|r" or "|cFFFF4444off|r"))

    elseif cmd == "rate" then
      T_.showRate = not T_.showRate; saveRuns()
      msg("live presses/s " .. (T_.showRate and "|cFF00FF00on|r" or "|cFFFF4444off|r"))

    elseif cmd == "min" then
      local n = tonumber(rest)
      if n then T_.minRun = n; saveRuns(); msg("auto reports for runs over " .. n .. "s") else msg("usage: /ftrack min 20") end

    elseif cmd == "clear" then
      T_.runs = {}; saveRuns(); msg("saved runs cleared.")

    else
      cmdHelp()
    end
  end

  -- combat state -> automatic runs
  local combat = CreateFrame("Frame", "FeralTrackCombat")
  combat:RegisterEvent("PLAYER_REGEN_DISABLED")
  combat:RegisterEvent("PLAYER_REGEN_ENABLED")
  combat:RegisterEvent("PLAYER_LOGIN")
  combat:RegisterEvent("PLAYER_LOGOUT")
  combat:RegisterEvent("PLAYER_ENTERING_WORLD")
  combat:RegisterEvent("ZONE_CHANGED_NEW_AREA")
  combat:SetScript("OnEvent", function()
    if event == "PLAYER_LOGIN" then
      init()
      createHUD()
    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
      -- the zone name is not always final at the event itself
      T_.zoneCheckAt = GetTime() + 1
    elseif event == "PLAYER_REGEN_DISABLED" then
      if not T_.run and T_.auto then
        startRun(nil, false)          -- startRun already counts this fight
      elseif T_.run then
        T_.run.fights = T_.run.fights + 1
        T_.run.fightStart = GetTime()
        fightOpen(T_.run)
      end
    elseif event == "PLAYER_REGEN_ENABLED" then
      local run = T_.run
      if run then
        if run.fightStart then
          local f = GetTime() - run.fightStart
          if f > run.longest then run.longest = f end
          run.fightStart = nil
        end
        if not run.manual then stopRun(true) else fightClose(run); saveRuns() end
      end
    elseif event == "PLAYER_LOGOUT" then
      if T_.run then
        if T_.run.fightStart then
          local f = GetTime() - T_.run.fightStart
          if f > T_.run.longest then T_.run.longest = f end
          T_.run.fightStart = nil
        end
        fightClose(T_.run)
        saveRuns()
      end
    end
  end)

  -- combat log
  local log = CreateFrame("Frame", "FeralTrackLog")
  log:RegisterEvent("CHAT_MSG_COMBAT_SELF_HITS")
  log:RegisterEvent("CHAT_MSG_COMBAT_SELF_MISSES")
  log:RegisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE")
  log:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE")
  log:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_DAMAGE")
  log:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_DAMAGE")
  log:SetScript("OnEvent", function() onCombatLog(event, arg1) end)

  -- a new target has no Rip yet: Rip gaps only start counting after the first Rip on it
  local tgt = CreateFrame("Frame", "FeralTrackTarget")
  tgt:RegisterEvent("PLAYER_TARGET_CHANGED")
  tgt:SetScript("OnEvent", function()
    T_.ripSeen = false; T_.ripGapStart = nil
    -- the fight is named after its first hostile target
    local run = T_.run
    if run and run.fs and not run.fs.target and UnitExists("target") and UnitCanAttack("player", "target") then
      run.fs.target = UnitName("target")
    end
  end)

  -- sampler
  local ticker = CreateFrame("Frame", "FeralTrackTicker")
  ticker:SetScript("OnUpdate", function()
    if (this.tick or 0) > GetTime() then return end
    this.tick = GetTime() + 0.1
    sample()
  end)
end

FeralTrack_OnLoad()
