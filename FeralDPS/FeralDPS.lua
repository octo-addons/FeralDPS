-- FeralDPS.lua
-- Feral druid rotation optimizer for TurtleWoW
-- Built on the same skeleton as RogueDPS, adapted to cat/bear.
--
-- Specs:
--   Cat   - single target cat DPS. Shred behind / Claw in front, Rip + Ferocious Bite.
--   Bear  - single target tanking. Faerie Fire (Feral), Demoralizing Roar,
--           Savage Bite on cooldown, Maul as filler.
--   AoE   - bear multi-target. Swipe priority, Demoralizing Roar, Maul filler.
--
-- Optional integrations:
--   UnitXP (SuperWoW) - behind-target detection for Shred vs Claw
--   Nampower          - debuffs by spell id, bleed ticks, mana while shifted (Reshift)
--
-- Commands:
--   /fdps          - execute current spec rotation
--   /fdps cat      - switch to Cat and execute
--   /fdps bear     - switch to Bear and execute
--   /fdps aoe      - switch to AoE (bear) and execute
--   /fdps rip      - toggle Rip upkeep at 5 CP        (default on)
--   /fdps rake     - toggle Rake upkeep (default on; always on when fronting)
--   /fdps claw     - Claw instead of Shred while both bleeds are up (default on)
--   /fdps ff       - toggle Faerie Fire (Feral)       (default on)
--   /fdps tf       - toggle Tiger's Fury              (default on)
--   /fdps berserk  - auto-Berserk when the window is right (default on)
--   /fdps pull     - allow acting on unpulled mobs while in combat (default off)
--   /fdps btrash   - Berserk on cooldown, no Rip requirement (default off)
--   /fdps farm     - cat, short fights: no FF/Rip, early Bites, Rake for Claw
--   /fdps enrage   - bear: Enrage when rage-starved on trash (default on)
--   /fdps enrageboss - bear: Enrage on bosses too (default off)
--   /fdps chat <tab> - route all addon output to a chat tab (FeralTrack follows)
--   /fdps reshift  - Reshift (OctoWoW powershift) when energy runs dry (default on)
--   /fdps reshift energy <n> / reserve <mana> / cost <mana>
--   /fdps show / hide / debug / reload / help

FeralDPS = {}

-- ============================================================
-- Internal state
-- ============================================================
local F_ = {
  spec = "cat",

  -- Toggles
  useRip        = true,
  useRake       = true,   -- on since 1.15: the top feral logs keep Rake at 60-70%
                          -- (its ticks return energy, and Claw gets +30% per bleed)
  useFaerieFire = true,
  clawBleeds    = true,   -- Open Wounds: Claw while Rake AND Rip are up (Shred on Clearcasting)
  useTigersFury = true,
  useBerserk    = true,
  allowPull     = false,  -- act on out-of-combat targets while already fighting
  berserkTrash  = false,  -- Berserk without waiting for Rip (use it on cooldown)
  chatWindow    = nil,    -- name of the chat tab for addon output (nil = general)
  powershift    = false,  -- old DruidBar powershift (superseded by Reshift)
  -- Reshift: OctoWoW's one-press powershift (level 60 skill). Furor hands 40
  -- energy per use (plus the head enchant, if any), for 348 mana. The top
  -- feral logs use it 11-13 times per boss. Never without the mana for it.
  useReshift    = true,
  reshiftEnergy = 15,     -- only when energy is at or below this. A Reshift does not ADD
                          -- energy: it empties the bar and sets it to what the shift pays
                          -- (40 Furor + 20 head enchant = 60 for René). Whatever was in the
                          -- bar is lost, so it is pressed when the bar is nearly empty.
  reshiftEnergyManual = false,
  reshiftGain   = nil,    -- the energy a Reshift sets the bar to, measured (Nampower energize events)
  reshiftMinNet = 20,     -- a Reshift must be worth at least this much energy (gain - bar - TF recast)
  bossHp        = 25000,  -- an elite with this much max health counts as a boss (dungeon bosses)
  reshiftReserve = 700,   -- mana kept back: a Cat Form (55% base mana) after a shift out, and some
  reshiftCost   = 348,    -- mana per Reshift as the spellbook shows it (Natural Shapeshifter included)
  reshiftCount  = 0, lastReshiftTime = 0, reshiftHoldUntil = 0, reshiftWatch = nil,
  -- Energy regen comes in server ticks: +20 every 2s (+40 under Berserk).
  -- The last tick seen says when the next one lands, so a Reshift is not
  -- pressed 0.3s before a tick that would push the total past 100.
  energyTickAt = 0, energyTickSize = 20, lastEnergySeen = nil,
  useEnrage     = true,   -- bear: Enrage for rage when starved (trash only)
  useRagePot    = false,  -- /fdps pot: Mighty Rage Potion on bosses, timed for the Rip snapshot
  useJuju       = false,  -- /fdps juju: Juju Flurry on bosses whenever it is ready
  lastConsumableTry = 0, lastPotUse = 0, potWarned = false, jujuWarned = false,
  enrageBoss    = false,  -- bear: allow Enrage on bosses too (armor debuff!)
  lastEnrageTime = 0,

  -- Talent ranks (read at login / on /fdps reload)
  ferocityRank   = 0,   -- reduces Claw / Rake / Maul cost
  impShredRank   = 0,   -- reduces Shred cost by 6 per rank
  natShifterRank = 0,   -- reduces shapeshift mana cost (powershift estimate)
  furorRank      = 0,   -- 5/5 = 40 energy on shifting into cat (what Reshift pays out)
  bloodFrenzyRank = 0,  -- extends Tiger's Fury by 6s per rank
  carnageRank    = 0,   -- 20% per CP per rank: at 2/2 a 5-CP Bite ALWAYS refreshes Rip+Rake

  -- Idol of Ferocity in the ranged slot: -3 energy on Claw / Rake
  idolReduction = 0,

  -- Resolved costs (recomputed in feralInit)
  costs = {},

  -- Debuff / buff durations in seconds
  ripDur   = 18,    -- resolved per cast from ripBase[cp] * relicFactor
  ripBase  = { 10, 12, 14, 16, 18 },   -- Turtle 1.18: Rip duration by combo points
  ripTick  = 2,     -- seconds between Rip ticks (x relicFactor)
  relicFactor = 1,  -- Idol of Savagery: 0.9 on both duration and tick interval
  ripRefresh = 3,   -- refresh Rip at 5 CP when fewer than this many seconds remain
  rakeDur  = 9,
  ffDur    = 40,
  demoDur  = 30,
  tfDur    = 6,     -- Tiger's Fury base; Blood Frenzy adds 6s per rank

  -- Texture fragments used for buff / debuff detection
  texRip    = "ability_ghoulfrenzy",
  texRake   = "ability_druid_disembowel",
  texFF     = "spell_nature_faeriefire",
  texDemo   = "ability_druid_demoralizingroar",
  texClear  = "spell_shadow_manaburn",       -- Omen of Clarity proc
  texProwl  = "ability_ambush",
  texTF     = "ability_mount_jungletiger",   -- Tiger's Fury

  -- Cast time tracking
  lastRipTime  = 0,
  lastRipCP    = 0,
  lastRakeTime = 0,
  lastFFTime   = 0,
  lastDemoTime = 0,
  lastTFTime   = 0,
  lastAttackTry = 0,
  lastMaulTime = 0,
  lastBiteTime = 0,

  -- Combat-log tick counters. Rip has 6 periodic ticks, Rake 3; a 7th Rip
  -- tick can only mean Carnage refreshed it. Counting ticks also snaps the
  -- timers to the server's cadence instead of our cast timestamp.
  ripTicks  = 0,
  rakeTicks = 0,
  lastRipTickTime  = 0,   -- last "suffers ... from your Rip" seen (raid debuff cap)
  lastRakeTickTime = 0,
  ripTickCount  = 9,
  carnageRefreshes = 0,   -- Rip tick-count wraps seen this session
  rakeTickCount = 3,
  lastCastTime = 0,
  hudPos = nil,           -- saved HUD screen position { left=, bottom= }

  -- Form indices, resolved each rotation pass
  catIndex  = nil,
  bearIndex = nil,

  -- Time-to-die estimate for the current target from its health trend.
  -- Farm mobs die in 8-10s: an 18s Rip on one of those is 30 energy and 5 combo
  -- points thrown away, so bleeds are skipped when the target will not outlive them.
  ttd = { name = nil, samples = {}, value = nil },
  ttdMinRip  = 0.6,   -- Rip needs at least this fraction of its duration left on the target
  ttdMinFF   = 8,     -- Faerie Fire is skipped when the target dies sooner than this
  ttdMinRake = 4,     -- Rake needs this long: its hit, a tick or two, and the Claw bonus
  recentFights = {},  -- durations of the last few fights: the prior for a fresh target
  fightStart = nil,

  -- immune[targetName][spell] = true, learned from "failed. X is immune." lines
  -- and from repeated casts that never produce the debuff. Session-wide: a
  -- bleed-immune boss stays bleed-immune.
  immune = {},
  ripAttempts = 0, ripAttemptTarget = nil, ripAttemptTime = 0, ripAttemptVoid = false,

  -- "X is immune" for abilities that are NOT learnable (Shred, Claw, Bite...)
  -- means the target cannot be hit right now at all: banished, shielded, in a
  -- phase. Two of those inside 3s put the target on a short hold.
  immuneHits = 0, immuneHitTime = 0, immuneHoldUntil = 0, immuneHoldTarget = nil,

  -- client errors: "You must be behind your target." on Shred means UnitXP's
  -- verdict and the server's hitbox disagree (big bosses: Onyxia, Garr) -
  -- for a few seconds the rotation then plays "in front" (Claw / Rake).
  lastError = nil, lastErrorTime = 0, lastAttempt = nil,
  lastAttemptTime = 0,    -- when the last ability (GCD or not) was pressed
  lastAttemptGcd = false, -- was it a GCD ability (then a refusal frees the guard)
  lastSpec = "cat",       -- the spec the last press ran with
  frontUntil = 0,
  -- "Out of range." on a bear ability: in AoE the target is swapped for the
  -- nearest mob that is fighting (a caster standing back cannot be Swiped);
  -- in single-target bear Swipe is simply held for a moment.
  swipeHoldUntil = 0,
  retargetAt = 0,         -- cat: no more than one far-target swap every 2s

  -- /fdps trace: every press, decision, cast and client event with a timestamp
  trace = false, traceLog = {}, traceStart = 0,

  book = {},
  hud = {},
}

-- ============================================================
-- OUTPUT - which chat window the addon talks to
-- All addon text goes through out(). By default that is the general chat
-- frame; /fdps chat <name> redirects it to a chat tab of that name (created
-- if it does not exist), so combat-time messages stop burying party chat.
-- FeralTrack uses the same window through FeralDPS.Out.
-- ============================================================
local function chatFrameByName(name)
  if not name or name == "" then return DEFAULT_CHAT_FRAME end
  for i = 1, 7 do
    local wname = GetChatWindowInfo(i)
    if wname and string.lower(wname) == string.lower(name) then
      return getglobal("ChatFrame" .. i)
    end
  end
  return nil
end

local function out(text)
  local f = chatFrameByName(F_.chatWindow) or DEFAULT_CHAT_FRAME
  f:AddMessage(text)
end

function FeralDPS.Out(text) out(text) end

-- Settings changes are also echoed to the general chat frame when the addon
-- talks to its own tab: /fdps berserk in a raid should be visible on the tab
-- that is actually in front, not only on "Feral".
local function announce(text)
  out(text)
  local f = chatFrameByName(F_.chatWindow)
  if f and f ~= DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage(text) end
end

local TRACE_MAX = 1500
local function trace(kind, text)
  if not F_.trace then return end
  text = text or ""
  local log = F_.traceLog
  local n = table.getn(log)
  if kind == "press" and string.find(text, "^wait:") and F_.traceLastWait == text and n > 0 then
    F_.traceWaitCount = (F_.traceWaitCount or 1) + 1
    log[n] = string.format("%7.2f  %-8s %s  (x%d, until %.2f)", F_.traceWaitStart, kind, text,
      F_.traceWaitCount, GetTime() - F_.traceStart)
    return
  end
  F_.traceLastWait = (kind == "press" and string.find(text, "^wait:")) and text or nil
  F_.traceWaitCount = 1
  F_.traceWaitStart = GetTime() - F_.traceStart
  table.insert(log, string.format("%7.2f  %-8s %s", GetTime() - F_.traceStart, kind, text))
  while table.getn(log) > TRACE_MAX do table.remove(log, 1) end
end

-- ============================================================
-- BUFF / DEBUFF DETECTION (by partial texture path)
-- ============================================================
local function isPlayerBuff(texturePart)
  local part = string.lower(texturePart)
  local i = 0
  while not (GetPlayerBuff(i) == -1) do
    local tex = GetPlayerBuffTexture(GetPlayerBuff(i))
    if tex and string.find(string.lower(tex), part) then
      return true
    end
    i = i + 1
  end
  return false
end

local function isTargetDebuff(texturePart)
  if not UnitExists("target") then return false end
  local part = string.lower(texturePart)
  for i = 1, 40 do
    local tex = UnitDebuff("target", i)
    if not tex then break end
    if string.find(string.lower(tex), part) then return true end
  end
  return false
end

-- A banished, sheeped, sapped or shackled target cannot be hit: every ability
-- fails with "immune" and the energy just sits at 100. Garr's Firesworn are
-- the classic case - warlocks banish them, and TargetNearestEnemy happily
-- hands one of those to the rotation.
local CC_TEX = { "spell_shadow_cripple",        -- Banish
                 "spell_nature_polymorph",      -- Polymorph
                 "ability_sap",                 -- Sap
                 "spell_nature_sleep",          -- Hibernate
                 "spell_frost_chainsofice",     -- Freezing Trap
                 "spell_nature_slow",           -- Shackle Undead
                 "spell_shadow_shadowworddominate" }  -- Mind Control
local function targetCrowdControlled()
  for i = 1, table.getn(CC_TEX) do
    if isTargetDebuff(CC_TEX[i]) then return true end
  end
  return false
end

-- In a 40-man raid a boss carries more debuffs than the 1.12 client will show
-- (16). Once the bar is full, "not visible" no longer means "not there": Rip
-- can be ticking away in slot 20. This is what made the raid rotation recast
-- Faerie Fire 200 times and count Rip as up for 4% of the night.
local function debuffBarFull()
  if not UnitExists("target") then return false end
  local n = 0
  for i = 1, 40 do
    if not UnitDebuff("target", i) then break end
    n = n + 1
  end
  return n >= 16
end

-- ============================================================
-- NAMPOWER WITNESSES
-- With Nampower loaded the guessing stops. It hands the addon what the 1.12
-- API hides: every aura on the target by spell ID (GetUnitField "aura", all 16
-- debuff slots), an event when our cast lands on the target - with a flag
-- that says whether the target's debuff bar was already full at that moment
-- (AURA_CAST_ON_OTHER) - an event when the debuff really appears or
-- disappears (DEBUFF_ADDED/REMOVED_OTHER) and the bleed ticks themselves
-- (SPELL_DAMAGE_EVENT_SELF), none of it through the chat log.
--
-- How the debuff limit works on OctoWoW (vmangos, DebuffLimit = 40 since the
-- 30 Apr 2026 deployment - it was "effectively 1" before): the client has 16
-- visible debuff slots. The 17th to 40th debuff is applied all the same - it
-- works and it ticks - but it gets no visible slot, so the client never sees
-- it: not in UnitDebuff, not in the aura field, no DEBUFF_ADDED event. Only
-- above 40 is something removed, and then the least important aura goes
-- first (Rip and Rake sit in the middle of that ranking).
--
-- So "the 16 visible slots are full" (Nampower's cap flag on our cast) means
-- the debuff is most likely on the target OUT OF SIGHT, not missing. The
-- witness that settles it is the bleed's own ticks, which Nampower reports
-- from the server's periodic log whatever slot the aura has. A Rip that went
-- off into a full bar and neither appeared nor ticked within a tick interval
-- is really not there (bumped above 40, or immune): it is held back on that
-- target for RIP_BLOCK_HOLD seconds and the points go into Ferocious Bite.
--
-- Nampower's own Lua functions must not be called through pcall (its source
-- says the Lua state pointer gets corrupted that way), so every call is
-- guarded by a type check instead.
-- ============================================================
local NP_IDS = {
  ["Rip"]                 = { 1079, 9492, 9493, 9752, 9894, 9896 },
  ["Rake"]                = { 1822, 1823, 1824, 9904 },
  ["Faerie Fire (Feral)"] = { 16857, 17390, 17391, 17392 },
  ["Demoralizing Roar"]   = { 99, 1735, 9490, 9747, 9898 },
}
local NP_NAME = {}            -- spell id -> name, filled at init
local NP_TIMER = {
  ["Rip"] = "lastRipTime", ["Rake"] = "lastRakeTime",
  ["Faerie Fire (Feral)"] = "lastFFTime", ["Demoralizing Roar"] = "lastDemoTime",
}
local RIP_BLOCK_HOLD = 30
F_.np = { live = false, version = "", ticks = 0, landed = 0, capped = 0, blocked = 0, hidden = 0,
          cast = {},          -- name -> { t, guid, capped, landed } for our casts in flight
          tickT = {},         -- "Rip@guid" -> time of the last tick seen on that unit
          block = {} }        -- name -> { guid, untilT } held back on that target

local function npLive() return F_.np.live end

local function normGuid(g)
  if type(g) ~= "string" then return nil end
  g = string.upper(g)
  g = string.gsub(g, "^0X", "")
  g = string.gsub(g, "^0+", "")
  return g
end

-- The target's GUID: SuperWoW returns it as UnitExists' second value.
local function targetGuid()
  local ok, g = UnitExists("target")
  if not ok then return nil end
  return normGuid(g)
end

local function npAuraOnTarget(name)
  if not F_.np.live or type(GetUnitField) ~= "function" then return nil end
  if not UnitExists("target") then return false end
  local ids = NP_IDS[name]
  if not ids then return nil end
  local auras = GetUnitField("target", "aura")
  if type(auras) ~= "table" then return nil end
  for i = 1, 48 do
    local id = auras[i]
    if id and id ~= 0 then
      for j = 1, table.getn(ids) do
        if ids[j] == id then return true end
      end
    end
  end
  return false
end

-- Debuff slots in use on the target (of 16), by the raw aura fields.
local function npDebuffSlotsUsed()
  if not F_.np.live or type(GetUnitField) ~= "function" or not UnitExists("target") then return nil end
  local auras = GetUnitField("target", "aura")
  if type(auras) ~= "table" then return nil end
  local n = 0
  for i = 33, 48 do if auras[i] and auras[i] ~= 0 then n = n + 1 end end
  return n
end

-- Is this debuff on the target? Spell IDs when Nampower is there, the icon
-- texture otherwise.
local function debuffSeen(name, texturePart)
  local np = npAuraOnTarget(name)
  if np ~= nil then return np end
  return isTargetDebuff(texturePart)
end

-- At login: the spell IDs of the ranks actually in the book (custom ranks
-- included) and our own GUID, both unavailable while the addon loads.
local function npInitPlayer()
  if not F_.np.live then return end
  if type(GetSpellIdForName) == "function" then
    for name, ids in pairs(NP_IDS) do
      local id = GetSpellIdForName(name)
      if type(id) == "number" and id > 0 and not NP_NAME[id] then
        table.insert(ids, id); NP_NAME[id] = name
      end
    end
  end
  if not F_.np.playerGuid then
    local _, pg = UnitExists("player")
    F_.np.playerGuid = normGuid(pg)
  end
end

local function npBlocked(name)
  local b = F_.np.block[name]
  if not b then return false end
  if GetTime() > b.untilT then F_.np.block[name] = nil; return false end
  local g = targetGuid()
  if g and b.guid and g ~= b.guid then return false end
  return true
end

-- Faerie Fire "immunity" is retried after this long: a boss shield phase
-- (Epochronos, Chronar) reads as immune, and the debuff is worth 1 GCD to
-- test again once the phase is likely over.
local FF_RETRY = 90

local function isImmune(spell)
  local name = UnitName("target")
  if not name then return false end
  local t = F_.immune[name]
  if not t or not t[spell] then return false end
  if type(t[spell]) == "number" then           -- timed (Faerie Fire)
    if GetTime() - t[spell] > FF_RETRY then
      t[spell] = nil
      return false
    end
  end
  return true
end

-- Which "X is immune" lines are worth remembering. Bleed immunity is a
-- property of the mob and is kept across logins. Faerie Fire immunity is
-- kept for the session only (a boss shield phase can fake it). Everything
-- else - Maul, Savage Bite, Demoralizing Roar, Shred... - is ALWAYS a
-- temporary phase and is never learned; remembering it once muted the whole
-- bear rotation on Time-Lord Epochronos.
LEARNABLE_IMMUNE = { ["Rip"] = true, ["Rake"] = true, ["Faerie Fire (Feral)"] = true }
local PERSIST_IMMUNE = { ["Rip"] = true, ["Rake"] = true }

local function persistImmune()
  if not FeralDPS_Settings then return end
  local copy = {}
  for mob, t in pairs(F_.immune) do
    for sp, _ in pairs(t) do
      if PERSIST_IMMUNE[sp] then
        copy[mob] = copy[mob] or {}
        copy[mob][sp] = true
      end
    end
  end
  FeralDPS_Settings.immune = copy
end

local function markImmune(name, spell)
  if not name or not spell then return end
  if not LEARNABLE_IMMUNE[spell] then return end
  F_.immune[name] = F_.immune[name] or {}
  if not F_.immune[name][spell] then
    if PERSIST_IMMUNE[spell] then
      F_.immune[name][spell] = true
      out("|cFFFFD700FeralDPS|r: |cFFFFFFFF" .. name
        .. "|r is immune to |cFFFFFFFF" .. spell .. "|r — skipping it on this target.")
    else
      F_.immune[name][spell] = GetTime()     -- retried after FF_RETRY seconds
      out("|cFFFFD700FeralDPS|r: |cFFFFFFFF" .. name
        .. "|r is immune to |cFFFFFFFF" .. spell .. "|r — skipping it for "
        .. FF_RETRY .. "s (shield phase?).")
    end
  end
  -- Bleed immunity is a property of the mob, not of the ability: a target
  -- that shrugs off Rip (Drifting Avatar of Sand, elementals, mechanicals)
  -- shrugs off Rake too, so both are marked at once and no Rake is wasted.
  if spell == "Rip" and not F_.immune[name]["Rake"] then
    F_.immune[name]["Rake"] = true
  elseif spell == "Rake" and not F_.immune[name]["Rip"] then
    F_.immune[name]["Rip"] = true
  end
  persistImmune()
end

local function isClearcasting()
  return isPlayerBuff(F_.texClear)
end

-- ============================================================
-- TIMER HELPERS
-- A cast-time timer is kept per debuff; the timer is cleared as soon as
-- the debuff is gone from the target, so a re-targeted mob reads 0.
-- ============================================================
-- Takes the FIELD NAME, not the value, so an expired timer can be zeroed here.
-- That matters: the watcher below only re-arms a timer that reads 0, so a timer
-- left sitting at "expired" would never pick the debuff up again.
local function isBossUnit()
  return UnitClassification("target") == "worldboss" or UnitLevel("target") == -1
end

local function remaining(key, dur, texturePart, spellName)
  local startTime = F_[key]
  if startTime == 0 then return 0 end
  local age  = GetTime() - startTime
  local left = dur - age
  if left <= 0 then F_[key] = 0 return 0 end
  -- After a 1.5s grace period (server latency on the debuff appearing) the
  -- debuff itself decides: gone from the target means the timer is dead.
  -- Unless the debuff bar is full (raids) - then it cannot be seen either way,
  -- and the timer runs on its own. Bleeds have a second witness there: their
  -- ticks in the combat log. No tick for two intervals means it is not on.
  if age > 1.5 and texturePart and not debuffSeen(spellName, texturePart) then
    -- Gone from the visible list. With a visible slot free that is the whole
    -- story: the debuff is not on the target.
    if not debuffBarFull() then
      F_[key] = 0
      return 0
    end
    -- All 16 visible slots are taken. On OctoWoW the server allows 40, and
    -- the 17th and up are applied without a visible slot (see NAMPOWER
    -- WITNESSES): an unseen bleed lives as long as its ticks keep coming, an
    -- unseen Faerie Fire or Roar simply runs its duration.
    local tick, lastTick
    if key == "lastRipTime" then
      tick, lastTick = F_.ripTick * F_.relicFactor, F_.lastRipTickTime
    elseif key == "lastRakeTime" then
      tick, lastTick = F_.rakeDur / F_.rakeTickCount, F_.lastRakeTickTime
    end
    if tick then
      local sinceTick = GetTime() - math.max(lastTick or 0, startTime)
      -- Nampower delivers every tick from the server's periodic log, so one
      -- interval plus latency is enough. The chat log missed them on raid
      -- bosses (MC/Onyxia: Rip recast at every 5 CP), so without Nampower
      -- ticks a boss gets the duration on trust (1.13).
      local limit   = F_.np.ticksLive and (tick + 1.0) or (2 * tick + 1)
      local witness = F_.np.ticksLive or not isBossUnit()
      if witness and sinceTick > limit then
        F_[key] = 0
        return 0
      end
    end
  end
  return left
end

-- Rip lasts 10/12/14/16/18s by combo points on this server (1.18), scaled by the
-- relic. Called on every Rip cast so the timer and the tick count match the
-- Rip that is actually on the target.
local function setRipDuration(cp)
  if not cp or cp < 1 then cp = 5 end
  if cp > 5 then cp = 5 end
  F_.ripDur = F_.ripBase[cp] * F_.relicFactor
  F_.ripTickCount = math.floor(F_.ripBase[cp] / F_.ripTick + 0.5)
end

local function getRipRemaining()  return remaining("lastRipTime",  F_.ripDur,  F_.texRip,  "Rip")  end
local function getRakeRemaining() return remaining("lastRakeTime", F_.rakeDur, F_.texRake, "Rake") end
local function getFFRemaining()   return remaining("lastFFTime",   F_.ffDur,   F_.texFF,   "Faerie Fire (Feral)") end
local function getDemoRemaining() return remaining("lastDemoTime", F_.demoDur, F_.texDemo, "Demoralizing Roar")   end

-- Tiger's Fury is a buff on the PLAYER, and for those 1.12 does expose the
-- real time left (GetPlayerBuffTimeLeft) - so this one is exact, no estimate.
-- The Scholo run showed why that matters: the estimate assumed 18s and
-- reported the buff as "down" whenever the real duration differed.
local function getTFRemaining()
  local part = F_.texTF
  local i = 0
  while not (GetPlayerBuff(i) == -1) do
    local id  = GetPlayerBuff(i)
    local tex = GetPlayerBuffTexture(id)
    if tex and string.find(string.lower(tex), part) then
      local left = GetPlayerBuffTimeLeft(id)
      if left and left > 0 then return left end
      return 0.5   -- buff present but no time reported: treat as up
    end
    i = i + 1
  end
  return 0
end

-- ============================================================
-- FORM / POSITION / RESOURCE HELPERS
-- ============================================================

-- Fills F_.catIndex / F_.bearIndex and returns the index of the active form (0 = caster)
local function resolveForms()
  local current = 0
  F_.catIndex, F_.bearIndex = nil, nil
  for i = 1, GetNumShapeshiftForms() do
    local _, name, active = GetShapeshiftFormInfo(i)
    if name == "Cat Form"  then F_.catIndex  = i end
    if name == "Bear Form" or name == "Dire Bear Form" then F_.bearIndex = i end
    if active then current = i end
  end
  return current
end

-- Behind the target? Requires UnitXP / SuperWoW; assume "in front" when unavailable.
-- Behind check needs SuperWoW's UnitXP. Without it there is no way to know,
-- and the safe assumption is BEHIND: a cat that is actually behind but gets
-- told "front" loses Shred for Claw all fight long, which is far worse than a
-- fronting cat getting the odd Shred failure. The HUD says when it is guessing.
local function hasSuperWoW()
  return type(UnitXP) == "function"
end

local function isBehindTarget()
  -- the server said "must be behind" a moment ago: it wins over UnitXP
  if F_.frontUntil > GetTime() then return false end
  if not hasSuperWoW() then return true end
  local ok, v = pcall(UnitXP, "behind", "player", "target")
  if not ok then return true end
  return v == true
end

-- Start melee swings if they are not already running.
-- Preferred path is the Attack action on a bar: UseAction on that exact slot
-- starts the swing without any risk of toggling an active attack back off.
-- AttackTarget() is the fallback for a bar with no Attack button, throttled
-- because in that case there is no way to read whether we are already swinging.
local function ensureAttacking()
  local slot
  for i = 1, 120 do
    if IsAttackAction(i) == 1 then
      if IsCurrentAction(i) == 1 then return end
      slot = slot or i
    end
  end
  if slot then
    UseAction(slot)
  elseif (GetTime() - F_.lastAttackTry) > 2 then
    F_.lastAttackTry = GetTime()
    AttackTarget()
  end
end

-- Mana available / shift cost while shifted (DruidBar only)
local function getShiftMana()
  if DruidBarKey and DruidBarKey.keepthemana and DruidBarKey.subtractmana then
    return DruidBarKey.keepthemana, DruidBarKey.subtractmana
  end
  return nil, nil
end

local function canAfford(spell, power)
  return power >= (F_.costs[spell] or 0)
end

-- Spellbook lookup: name -> book index (highest rank, since later entries win).
-- This exists because CastSpellByName mis-parses names that end in brackets:
-- "Faerie Fire (Feral)" is read as spell "Faerie Fire", rank "Feral", and the
-- cast silently fails. Casting by book index sidesteps the parser entirely.
local function buildSpellbook()
  F_.book = {}
  local i = 1
  while true do
    local name = GetSpellName(i, BOOKTYPE_SPELL)
    if not name then break end
    F_.book[name] = i
    i = i + 1
  end
end

local function castSpell(name)
  local idx = F_.book and F_.book[name]
  if idx then
    CastSpell(idx, BOOKTYPE_SPELL)
  else
    CastSpellByName(name)
  end
end

-- Is the spell off cooldown? Looked up by book index, so it works for abilities
-- whose name the cast parser cannot handle either.
local function spellReady(name)
  local idx = F_.book and F_.book[name]
  if not idx then return false end
  local start, duration = GetSpellCooldown(idx, BOOKTYPE_SPELL)
  if not start or start == 0 then return true end
  -- The global cooldown shows up here as a 1.0-1.5s cooldown on EVERY spell.
  -- That is not the ability's own cooldown, so it must not count as "not ready"
  -- or Savage Bite / Berserk would be skipped whenever the GCD is still ticking.
  if duration and duration <= 1.5 then return true end
  return (start + duration - GetTime()) <= 0
end

-- The global cooldown, read from the client instead of guessed. Cat abilities
-- run a 1.0s GCD, bear abilities 1.5s - and the old flat 1-second guard let a
-- bear press through at 1.0-1.5s, into "Spell is not ready yet.", 60 times in
-- one UBRS run. Claw and Swipe have no cooldown of their own, so any cooldown
-- the client shows on them (1.5s or shorter) is the GCD.
local function gcdRemaining(isCat)
  local ref = isCat and "Claw" or "Swipe"
  local idx = F_.book and F_.book[ref]
  if not idx then return 0 end
  local start, duration = GetSpellCooldown(idx, BOOKTYPE_SPELL)
  if not start or start == 0 or not duration or duration > 1.6 then return 0 end
  local left = start + duration - GetTime()
  if left < 0 then left = 0 end
  return left
end

-- Faerie Fire (Feral) has its own 6s cooldown. Switching target right after
-- casting it (UBRS packs: mob A dies, mob B is next) used to pick "Faerie Fire"
-- for the new target and then press it into "Spell is not ready yet" every
-- 0.4s until the cooldown ran out - up to 6s of standing still per switch.
-- Now a Faerie Fire on cooldown is simply skipped and the rotation carries on
-- with Tiger's Fury / Rake / Shred; the debuff goes up on the first press after
-- the cooldown ends, since it sits at the top of the priority list.
local function ffReady()
  local idx = F_.book and F_.book["Faerie Fire (Feral)"]
  if not idx then return true end          -- no book index: nothing to check against
  return spellReady("Faerie Fire (Feral)")
end

-- Is an on-next-swing ability (Maul) already queued? Vanilla has no API for
-- that except IsCurrentAction on the ability's OWN action button, found here
-- by icon. Pressing Maul while it is queued cancels it, so this check is what
-- stops a spammed macro from toggling Maul on and off every second.
local function isQueuedOnBar(texturePart)
  local part = string.lower(texturePart)
  for i = 1, 120 do
    local tex = GetActionTexture(i)
    if tex and string.find(string.lower(tex), part) then
      if IsCurrentAction(i) == 1 then return true end
      return false
    end
  end
  return nil   -- not on any bar: caller falls back to a time guard
end

-- Cast and record the timer. SPELL_GO_SELF refines it when Nampower is present.
local function castAndTrack(spell, cp)
  local now = GetTime()
  if spell == "Rip" then
    -- Fallback immunity detection: Rips on the same target that keep going
    -- out without a debuff ever showing up mean it is not going to.
    -- (Not when the debuff bar is full: then Rip is simply not visible, and
    -- the combat log's "is immune" line is the only trustworthy verdict.)
    -- Only a Rip that really went out counts: one the client refused ("Out of
    -- range." - Onyxia in the air with 5 CP banked gave three of those in a
    -- few seconds) or one the target dodged never had a debuff to show, and
    -- is voided below. Onyxia and Broodcommander Axelus were marked
    -- bleed-immune that way; version 4 forgets them again.
    local name = UnitName("target")
    if name == F_.ripAttemptTarget and (now - F_.ripAttemptTime) < 10
       and not F_.ripAttemptVoid
       and not isTargetDebuff(F_.texRip) and not debuffBarFull() then
      F_.ripAttempts = F_.ripAttempts + 1
    else
      F_.ripAttempts = 0
    end
    F_.ripAttemptTarget, F_.ripAttemptTime, F_.ripAttemptVoid = name, now, false
    if F_.ripAttempts >= 3 then markImmune(name, "Rip") end

    F_.lastRipTime, F_.lastRipCP = now, cp
    setRipDuration(cp)
    F_.ripTicks = 0
  elseif spell == "Ferocious Bite" then
    -- Carnage: 20% per combo point per rank to refresh Rake and Rip. When that
    -- reaches 100% the refresh is a certainty and the timers can be reset here
    -- instead of waiting for the combat log to notice an extra tick.
    if (F_.carnageRank * 0.1 * cp) >= 0.999 then
      if F_.lastRipTime  > 0 then F_.lastRipTime  = now; F_.ripTicks  = 0 end
      if F_.lastRakeTime > 0 then F_.lastRakeTime = now; F_.rakeTicks = 0 end
    end
  elseif spell == "Rake" then
    F_.lastRakeTime = now
    F_.rakeTicks = 0
  elseif spell == "Faerie Fire (Feral)" then
    F_.lastFFTime = now
  elseif spell == "Tiger's Fury" then
    F_.lastTFTime = now
  elseif spell == "Maul" then
    F_.lastMaulTime = now
  elseif spell == "Demoralizing Roar" then
    F_.lastDemoTime = now
  end
  if spell == "Rip" or spell == "Rake" or spell == "Faerie Fire (Feral)" or spell == "Demoralizing Roar" then
    F_.debuffTarget = UnitName("target")
  end
  castSpell(spell)
end

-- ============================================================
-- ROTATION LOGIC
-- ============================================================

-- ---- time to die ------------------------------------------------------
-- Sampled from the HUD tick (10x/s). Rate over the last 4 seconds of samples.
local function sampleTTD()
  local t = F_.ttd
  local name = UnitExists("target") and UnitName("target") or nil
  if name ~= t.name then
    t.name, t.samples, t.value = name, {}, nil
    if not name then return end
  end
  local now = GetTime()
  local hp  = UnitHealth("target")
  if not hp then return end
  table.insert(t.samples, { now, hp })
  -- drop samples older than 4s
  while table.getn(t.samples) > 0 and (now - t.samples[1][1]) > 4 do
    table.remove(t.samples, 1)
  end
  local n = table.getn(t.samples)
  if n < 5 then t.value = nil return end          -- under ~0.5s of data: unknown
  local t0, hp0 = t.samples[1][1], t.samples[1][2]
  local dt = now - t0
  if dt < 1.5 then t.value = nil return end
  local rate = (hp0 - hp) / dt                    -- health per second, same scale as hp
  if rate <= 0 then t.value = 999 return end      -- not losing health: treat as long-lived
  t.value = hp / rate
end

-- Seconds until the target dies at the current rate. Before the first 1.5s of
-- samples exist, the recent fights stand in: if the last few mobs died in 7s,
-- the next one probably will too, so Rip stays in the pocket from the start.
local function getTTD()
  local cur = (UnitExists("target") and UnitName("target") or nil)
  if F_.ttd.name == cur and F_.ttd.value then return F_.ttd.value end
  local n = table.getn(F_.recentFights)
  if n >= 3 then
    local sorted = {}
    for i = 1, n do sorted[i] = F_.recentFights[i] end
    table.sort(sorted)
    local median = sorted[math.floor((n + 1) / 2)]
    if median < 15 then return median end
  end
  return nil
end

-- Bosses are exempt from every time-to-die shortcut: a raid boss at 25% is
-- still a long fight, and its health trend is dominated by phases.
-- 1.15.19: a dungeon boss counts too. Emperor Dagran Thaurissan is a level
-- 59 elite, not a "??", and so was trash to this check: no Berserk on him,
-- and Reshift held back by the "save the mana for the boss" rule (so 1-5
-- Reshifts in a whole BRD run). An elite with bossHp (25000) or more max
-- health is a boss here; BRD/Scholo/Strat trash sits well under 15000.
-- 1.15.20: ...but only outside raids. Raid trash (Molten Giants, Core
-- Hounds, Onyxian Warders) has far more than 25000 health, and raid bosses
-- are "??" anyway - so in a raid zone, or in a raid group, the old rule
-- stands and the health rule is off.
local RAID_ZONES = {
  ["Molten Core"] = true, ["Onyxia's Lair"] = true, ["Zul'Gurub"] = true,
  ["Blackwing Lair"] = true, ["Tower of Karazhan"] = true,
  ["Lower Tower of Karazhan"] = true, ["Upper Tower of Karazhan"] = true,
  ["Lower Karazhan Halls"] = true, ["Upper Karazhan Halls"] = true,
  ["Emerald Sanctum"] = true, ["Ruins of Ahn'Qiraj"] = true,
  ["Temple of Ahn'Qiraj"] = true, ["Naxxramas"] = true, ["Blackrock Spire"] = true,
}
local function inRaid()
  if (GetNumRaidMembers() or 0) > 0 then return true end
  return RAID_ZONES[GetRealZoneText() or ""] == true
end

local function isBoss()
  if UnitClassification("target") == "worldboss" or UnitLevel("target") == -1 then return true end
  if inRaid() then return false end
  local c = UnitClassification("target")
  if c == "elite" or c == "rareelite" then
    local max = UnitHealthMax("target")
    if max and max >= (F_.bossHp or 25000) then return true end
  end
  return false
end

-- ============================================================
-- BOSS CONSUMABLES (/fdps pot, /fdps juju) - used off the GCD from the same
-- key press as everything else, only on bosses, only in combat.
--
-- Mighty Rage Potion: +60 Strength for 20s (and rage, which cat ignores).
-- Rip and Rake lock their damage in at the moment they are applied, and
-- Carnage then keeps that Rip alive with Bites. So the FIRST use goes right
-- before the first Rip: at 4+ combo points with no Rip on the boss, Tiger's
-- Fury up - the potion is drunk, the next finisher is a Rip that carries the
-- extra AP for the rest of the fight. Later uses (the potion is back every 2
-- minutes, shared with healing potions) go into a burst of Shreds: Tiger's
-- Fury up and 60+ energy to spend. On bleed-immune bosses only the burst
-- rule applies. In bear the potion is a pull tool: used when rage is short.
--
-- Juju Flurry: +3% attack speed for 20s, own 1-minute cooldown, not shared
-- with potions. Used whenever it is ready and Tiger's Fury is up.
-- ============================================================
local MIGHTY_RAGE_ID = 13442
local JUJU_FLURRY_ID = 12450

local function findItem(id)
  local key = "item:" .. id .. ":"
  for bag = 0, 4 do
    local n = GetContainerNumSlots(bag) or 0
    for slot = 1, n do
      local link = GetContainerItemLink(bag, slot)
      if link and string.find(link, key, 1, true) then
        return bag, slot
      end
    end
  end
  return nil
end

local function itemReady(bag, slot)
  local start, duration = GetContainerItemCooldown(bag, slot)
  if not start or start == 0 or not duration or duration == 0 then return true end
  return (start + duration - GetTime()) <= 0
end

-- true when the item was used; selfTarget handles items that ask for a
-- target (Juju Flurry) by pointing them at the player
local function useItem(id, selfTarget)
  local bag, slot = findItem(id)
  if not bag then return false, "not in bags" end
  if not itemReady(bag, slot) then return false, "on cooldown" end
  UseContainerItem(bag, slot)
  if selfTarget and SpellIsTargeting() then SpellTargetUnit("player") end
  return true
end

local function tryBossConsumables(inCat, power, pts)
  if not (F_.useRagePot or F_.useJuju) then return end
  if not UnitAffectingCombat("player") or not isBoss() then return end
  local now = GetTime()
  if now - F_.lastConsumableTry < 1.0 then return end     -- bag scans are not free
  F_.lastConsumableTry = now

  local tfUp = (not F_.useTigersFury) or getTFRemaining() > 0
  if F_.useRagePot then
    local want = false
    if inCat then
      local ripLeft = getRipRemaining()
      local ripPossible = F_.useRip and not isImmune("Rip") and not npBlocked("Rip")
      if ripPossible and ripLeft <= 0 and pts >= 4 and tfUp then
        want = "before Rip"                      -- the snapshot that lasts all fight
      elseif (not ripPossible or ripLeft > 8) and tfUp and power >= 60 then
        want = "Shred burst"                     -- Rip is covered: spend it on Shreds
      end
    else
      if power < 30 then want = "rage" end       -- bear: the pull
    end
    if want then
      local ok, why = useItem(MIGHTY_RAGE_ID, false)
      if ok then
        F_.lastPotUse = now
        out("|cFFFFD700FeralDPS|r: |cFFFF8800Mighty Rage Potion|r (" .. want .. ")")
        trace("item", "Mighty Rage Potion: " .. want)
        if FeralDPS.OnDecision then FeralDPS.OnDecision("Mighty Rage Potion", power, pts, true, false) end
      elseif why == "not in bags" and not F_.potWarned then
        F_.potWarned = true
        out("|cFFFFD700FeralDPS|r: /fdps pot is on, but there is no Mighty Rage Potion in the bags.")
      end
    end
  end

  if F_.useJuju and inCat and tfUp then
    local ok, why = useItem(JUJU_FLURRY_ID, true)
    if ok then
      trace("item", "Juju Flurry")
      if FeralDPS.OnDecision then FeralDPS.OnDecision("Juju Flurry", power, pts, true, false) end
    elseif why == "not in bags" and not F_.jujuWarned then
      F_.jujuWarned = true
      out("|cFFFFD700FeralDPS|r: /fdps juju is on, but there is no Juju Flurry in the bags.")
    end
  end
end

-- Will a fresh Rip get to run its full duration on this target?
local function targetWorthRipping(cp)
  if isBoss() then return true end
  local hp, max = UnitHealth("target"), UnitHealthMax("target")
  if hp and max and max > 0 and (hp / max) < 0.25 then return false end
  -- Time-to-die: the Rip that WOULD be cast (by CP) must get most of its ticks
  local ttd = getTTD()
  if ttd then
    local c = cp or 5
    if c < 1 then c = 1 elseif c > 5 then c = 5 end
    local dur = F_.ripBase[c] * F_.relicFactor
    if ttd < dur * F_.ttdMinRip then return false end
  end
  return true
end

-- Tiger's Fury: buff missing, energy for it, and (in the raid rotation) no
-- 5-CP Rip waiting for the same 30 energy. The recast guard is a safety net:
-- if the buff texture ever stopped matching, without it the rotation would
-- loop on Tiger's Fury forever. It only has to cover the latency between the
-- cast leaving and the buff appearing (it used to be 15s, which locked TF out
-- for a quarter of a minute after one failed cast).
-- 1.15.17: Tiger's Fury has no global cooldown (Beefyboi's logs: TF 0.4s after
-- a Reshift, Shred 0.8s after TF), so executeRotation fires it from here
-- BEFORE the GCD guard, like Maul and Savage Bite - the Kara10 log showed it
-- waiting out the Reshift's 1.5s GCD every time. The two rotations still ask
-- the same question as a fallback.
local function wantTigersFury(power, pts, ripFirst)
  if not F_.useTigersFury then return false end
  if power < (F_.costs["Tiger's Fury"] or 30) then return false end
  if getTFRemaining() > 0 then return false end
  if (GetTime() - F_.lastTFTime) <= 2 then return false end
  if ripFirst and pts >= 5 and getRipRemaining() < F_.ripRefresh then return false end
  return true
end

-- Cat priority (first match fires):
--   1. Prowl                     -> Ravage (behind) / Pounce (front)
--   2. Faerie Fire (Feral)       -> debuff missing
--   3. Tiger's Fury              -> buff missing (unless Rip needs refreshing now)
--   4. Berserk                   -> energy < 30, in combat, Rip up, TF up, off cooldown
--   5. Rip                       -> 5 CP, Rip under 3s left (skipped on dying trash)
--   6. Ferocious Bite            -> 5 CP
--   7. Rake                      -> toggle on, or whenever fronting
--   8. Shred (behind) / Claw (front)
local function nextSpell_Cat(opts)
  if isPlayerBuff(F_.texProwl) then
    return isBehindTarget() and "Ravage" or "Pounce"
  end

  local ttd = getTTD()
  if F_.useFaerieFire and getFFRemaining() <= 0 and not isTargetDebuff(F_.texFF)
     and not isImmune("Faerie Fire (Feral)") and not npBlocked("Faerie Fire (Feral)") and ffReady()
     and (isBoss() or not ttd or ttd >= F_.ttdMinFF) then
    return "Faerie Fire (Feral)"
  end

  -- Tiger's Fury sits ABOVE the finishers: with Blood Frenzy it runs 18s and
  -- carries +20% attack speed, and auto attacks are a quarter of total damage,
  -- so a gap here costs more than a combo point spent one GCD later. The
  -- exception is a Rip about to fall off - that still goes first. The recast
  -- guard is a safety net: if the buff texture ever stopped matching, without
  -- it the rotation would loop on Tiger's Fury forever.
  -- The recast guard only has to cover the latency between the cast leaving
  -- and the buff appearing on the bar. It used to be 15s, which meant one
  -- failed cast (energy dipped under 30 between the check and the cast) locked
  -- Tiger's Fury out for a quarter of a minute - the likely cause of the gaps
  -- seen in the 6-minute runs.
  if wantTigersFury(opts.power, opts.pts, true) then
    return "Tiger's Fury"
  end

  -- Combo points die with the target. On a mob that will not live to 5 CP, a
  -- builder makes a point that is thrown away, while a 2-4 CP Bite is damage
  -- that lands now - and Bite turns every spare energy point into more damage.
  -- Estimated time to 5 CP: ~1.5s per missing point plus one GCD.
  if opts.pts >= 2 and not isBoss() then
    local hp, max = UnitHealth("target"), UnitHealthMax("target")
    local lowHp = hp and max and max > 0 and (hp / max) < 0.15
    local needed = (5 - opts.pts) * 1.5 + 1
    if lowHp or (ttd and ttd < needed) then
      return "Ferocious Bite"
    end
  end

  -- Berserk: 20s of doubled energy regen. Fired into an empty energy pool with
  -- the bleeds already ticking and Tiger's Fury up, so the whole window goes
  -- into Shreds instead of setup. Never out of combat. Sits ABOVE the finishers
  -- on purpose: under 30 energy neither Rip (30) nor Bite (35) is castable, so
  -- 5 CP in the bank is no reason to hold it - it is the moment for it.
  -- 1.15.16: bosses only, like the potion and the Juju. The old gate ("any
  -- target with Rip on it") fired it on long-lived raid trash - three times in
  -- Kara10 on 8/10, and the one on a Grellkin pack left Grizikil without a
  -- Berserk because the 6-minute cooldown was still running. On a boss it
  -- still waits for Rip (or a bleed-immune boss), so the 20s go into Shreds
  -- with the bleeds already ticking. /fdps btrash opens it up for trash too:
  -- on cooldown, whenever the energy dips.
  if F_.useBerserk and opts.power < 30
     and UnitAffectingCombat("player")
     and (F_.berserkTrash
          or (isBoss() and (getRipRemaining() > 0 or isImmune("Rip") or npBlocked("Rip"))))
     and (not F_.useTigersFury or isPlayerBuff(F_.texTF))
     and spellReady("Berserk") then
    return "Berserk"
  end

  -- At 5 CP: refresh Rip BEFORE it drops rather than after. Waiting for it to
  -- expire means spending the 5 CP on a Bite and then rebuilding 5 CP (~4 GCDs)
  -- with no Rip on the target - a gap in both damage and, with Ancient
  -- Brutality, energy return. Refreshing inside the last few seconds costs only
  -- the sliver of duration that gets overwritten.
  -- On ordinary mobs under 25% health Rip will not live long enough to pay for
  -- itself, so the points go into a Bite instead. Bosses are exempt: at 25% a
  -- raid boss still has a long way to go.
  if opts.pts >= 5 then
    local ripLeft = getRipRemaining()
    -- With Carnage 2/2 a 5-CP Bite refreshes Rip for certain, so a Rip that is
    -- still ticking is never recast: the Bite does the same job and adds its own
    -- damage plus a combo point. Rip is only cast when there is none.
    local carnageSure = (F_.carnageRank * 0.1 * opts.pts) >= 0.999
    local needRip
    if carnageSure then needRip = (ripLeft <= 0) else needRip = (ripLeft < F_.ripRefresh) end
    -- A bleed-immune boss never gets the debuff, so without this check the
    -- rotation would try Rip at every 5 CP forever and never Bite.
    -- A Rip that Nampower saw go off into a full debuff bar without a debuff
    -- following is held back the same way: 30s of Bites, then one more try.
    if F_.useRip and needRip and targetWorthRipping(opts.pts) and not isImmune("Rip") and not npBlocked("Rip") then
      return "Rip"
    end
    -- Ferocious Bite eats EVERY point of energy in the bar, for +0.5% damage
    -- a point (the OctoWoW tooltip). That is about 5 damage per point; a
    -- Claw turns the same point into 16-17. So a Bite with a full bar is a
    -- Claw and a half thrown away: when there is energy for a builder AND
    -- the Bite, the builder goes first and the Bite follows on a lean bar.
    -- Not when Rip is about to drop (the Bite is what refreshes it), not on
    -- a Clearcasting proc (that builder is free anyway, so it is cast first
    -- below without this), and not on a target about to die.
    local spendDown = opts.power >= (F_.costs["Ferocious Bite"] + F_.costs["Claw"] + 5)
      and ripLeft > 5
      and (isBoss() or not ttd or ttd >= 8)
    if not spendDown then
      return "Ferocious Bite"
    end
    -- fall through: Rake if it is down, then Claw / Shred
  end

  -- Rake measured as a wash behind the target, where every builder is a Shred.
  -- In front it is a different ability: the builder becomes Claw, and Open
  -- Wounds gives Claw +30% per active bleed - so Rake goes up when fronting
  -- whatever the toggle says.
  if (F_.useRake or not isBehindTarget())
     and getRakeRemaining() <= 0
     and not isImmune("Rake") and not npBlocked("Rake")
     -- Rake does not need its full duration to pay off: the initial hit lands
     -- at once, and while the bleed is up every Claw gets +30% (Open Wounds)
     -- and every tick returns energy. Only skip it on targets about to drop.
     and (isBoss() or not ttd or ttd >= F_.ttdMinRake)
     and opts.power >= (F_.costs["Rake"] + 10) then
    return "Rake"
  end

  -- Open Wounds 3/3 gives Claw +30% damage PER active bleed, so with Rake and
  -- Rip both up Claw hits for +60% at 40 energy against Shred's 48 - and needs
  -- no positioning. Whether that beats Shred depends on weapon damage, so this
  -- is a toggle to measure, not a default.
  if F_.clawBleeds and getRipRemaining() > 0 and getRakeRemaining() > 0
     and not (isClearcasting() and isBehindTarget()) then
    return "Claw"
  end

  return isBehindTarget() and "Shred" or "Claw"
end

-- Farm priority (cat, short fights, usually from the front, Idol of Ferocity):
--   The goal is the fastest kill on a mob that lives 8-20s, not sustained
--   DPS. No Faerie Fire (a GCD that never pays off in 10s), no Rip (18s on a
--   mob that dies in 10), no waiting for 5 CP.
--   1. Prowl                 -> Ravage (behind) / Pounce (front)
--   2. Tiger's Fury          -> buff missing: +50 damage per hit AND +20% haste
--   3. Berserk               -> on cooldown, in combat, energy low
--   4. Ferocious Bite        -> 5 CP, OR 3+ CP with the target under 35%,
--                               OR 2+ CP when it will not live to the next builder
--   5. Rake                  -> not up (Open Wounds: every Claw after it is +30%,
--                               and the initial hit is Claw-sized on its own)
--   6. Shred (behind) / Claw (front)
local function nextSpell_Farm(opts)
  if isPlayerBuff(F_.texProwl) then
    return isBehindTarget() and "Ravage" or "Pounce"
  end

  if wantTigersFury(opts.power, opts.pts, false) then
    return "Tiger's Fury"
  end

  if F_.useBerserk and opts.power < 30
     and UnitAffectingCombat("player")
     and (not F_.useTigersFury or isPlayerBuff(F_.texTF))
     and spellReady("Berserk") then
    return "Berserk"
  end

  local hp, max = UnitHealth("target"), UnitHealthMax("target")
  local frac = (hp and max and max > 0) and (hp / max) or 1
  local ttd  = getTTD()
  if opts.pts >= 5
     or (opts.pts >= 3 and frac < 0.35)
     or (opts.pts >= 2 and ((ttd and ttd < 3) or frac < 0.12)) then
    return "Ferocious Bite"
  end

  if getRakeRemaining() <= 0 and not isImmune("Rake")
     and frac > 0.3
     and opts.power >= F_.costs["Rake"] then
    return "Rake"
  end

  return isBehindTarget() and "Shred" or "Claw"
end

-- Bear priority (single target threat):
--   1. Faerie Fire (Feral)   -> debuff missing (free, big threat)
--   2. Demoralizing Roar     -> debuff missing
--   3. Maul                  -> rage available (queues on next swing)
local function nextSpell_Bear(opts)
  if F_.useFaerieFire and getFFRemaining() <= 0 and not isTargetDebuff(F_.texFF)
     and not isImmune("Faerie Fire (Feral)") and not npBlocked("Faerie Fire (Feral)") and ffReady() then
    return "Faerie Fire (Feral)"
  end
  if getDemoRemaining() <= 0 and opts.power >= F_.costs["Demoralizing Roar"] then
    return "Demoralizing Roar"
  end
  -- Maul and Savage Bite are both fired off the GCD in executeRotation. The
  -- GCD slot is only worth a Swipe when rage is piling up beyond what Maul
  -- and Bite can spend (single target Swipe is poor threat per rage).
  if opts.power >= 60 and opts.power >= F_.costs["Swipe"] + F_.costs["Maul"]
     and F_.swipeHoldUntil <= GetTime() then
    return "Swipe"
  end
  return nil
end

-- AoE priority (bear, several mobs). Maul is queued off the GCD on the
-- current target; the GCD goes to whatever spreads threat across the pack:
--   1. Demoralizing Roar     -> debuff missing (hits every mob around you)
--   2. Swipe                 -> rage for it AND for the queued Maul
--   3. Faerie Fire (Feral)   -> target lacks it: free threat while rage builds
local function nextSpell_AoE(opts)
  if getDemoRemaining() <= 0 and opts.power >= F_.costs["Demoralizing Roar"] then
    return "Demoralizing Roar"
  end
  if opts.power >= F_.costs["Swipe"] + F_.costs["Maul"] then return "Swipe" end
  if F_.useFaerieFire and getFFRemaining() <= 0 and not isTargetDebuff(F_.texFF)
     and not isImmune("Faerie Fire (Feral)") and not npBlocked("Faerie Fire (Feral)") and ffReady() then
    return "Faerie Fire (Feral)"
  end
  return nil
end

local function pickSpell(spec, opts)
  if spec == "bear" then return nextSpell_Bear(opts) end
  if spec == "aoe"  then return nextSpell_AoE(opts)  end
  if spec == "farm" then return nextSpell_Farm(opts) end
  return nextSpell_Cat(opts)
end

-- Which specs run in cat form (everything else is bear)
local function isCatSpec(spec)
  return spec == "cat" or spec == "farm"
end

-- Maul is on-next-swing: pressing it while already queued CANCELS it. So a
-- Maul that is already waiting for the swing must not be pressed again.
local function maulAlreadyQueued()
  local q = isQueuedOnBar("ability_druid_maul")
  if q ~= nil then return q end
  -- Maul not on any bar: assume it stays queued for one bear swing (2.5s)
  return (GetTime() - F_.lastMaulTime) < 2.5
end

-- Shift back and forth to refill energy (cat only, needs DruidBar)
local function tryPowershift(currentForm)
  if not F_.powershift then return false end
  if not UnitExists("target") then return false end
  local mana, cost = getShiftMana()
  if not mana or not cost then return false end
  if mana < cost then return false end
  CastShapeshiftForm(currentForm)   -- drop form; the next press shifts back in
  return true
end

-- Mana while shifted. The 1.12 API shows energy in cat form and nothing
-- else; Nampower reads the raw unit field (power1 = mana), DruidBar keeps
-- its own count. nil when neither is there.
local function playerMana()
  if type(GetUnitField) == "function" then
    local m = GetUnitField("player", "power1")
    if type(m) == "number" then return m, GetUnitField("player", "maxPower1") end
  end
  if DruidBarKey and DruidBarKey.keepthemana then return DruidBarKey.keepthemana, DruidBarKey.maxmana end
  return nil
end

-- Reshift: OctoWoW's level 60 skill that simulates a powershift in one
-- press without leaving the form - Furor pays 40 energy (the top feral logs
-- show "Furor 40" right after each one), the head enchant adds to it. Used
-- when the rotation would otherwise stand and wait for energy, never with
-- Clearcasting up (that press is a free Shred), never into a full bar, and
-- never below the mana reserve.
-- Seconds until the next energy tick, or nil when no tick has been seen
-- for a while (energy sitting at 100 shows no ticks).
local function energyTickIn()
  if F_.energyTickAt == 0 then return nil end
  local since = GetTime() - F_.energyTickAt
  if since > 2.3 then return nil end
  local left = 2.0 - since
  if left < 0 then left = 0 end
  return left
end

local function reshiftWhy(power)
  if not F_.useReshift then return "off" end
  if not (F_.book and F_.book["Reshift"]) then return "not in the spellbook" end
  -- No talent gate: on OctoWoW the 40 energy on shifting is paid whether or
  -- not a talent called Furor shows up in the tree (René gets 60 with the
  -- head enchant, with "Furor 0/5" by name). The first Reshift measures it.
  if F_.reshiftNoGain and F_.reshiftNoGain >= 2 then return "paid no energy twice this fight - tried again next fight" end
  if power > F_.reshiftEnergy then return "energy above " .. F_.reshiftEnergy end
  if isClearcasting() then return "Clearcasting up" end
  -- What the Reshift is actually worth, in energy (1.15.17). It empties the
  -- bar and sets it to a level: Furor's 40 plus the head enchant's 20 = 60
  -- for René (the bar shows 60; the energize events only log Furor's 40, so
  -- the measured level from the bar is what counts, see the TTD frame). It
  -- also knocks Tiger's Fury off (only the +40 damage buff; the Blood Frenzy
  -- haste stays), and TF costs 30 to put back. So with a running TF a Reshift
  -- nets 60 - 30 - whatever was in the bar; with TF down or about to drop it
  -- nets the full 60 minus the bar, because that TF was due anyway. The mana
  -- buys 7-9 Reshifts per fight, so each one has to be worth at least
  -- reshiftMinNet (20): with TF up that means a bar under 10, with TF down
  -- or in its last 3s anything under the usual ceiling.
  local tfLeft = (F_.useTigersFury and getTFRemaining()) or 0
  local gain   = F_.reshiftGain or 60
  local tfCost = (F_.useTigersFury and tfLeft > 3) and (F_.costs["Tiger's Fury"] or 30) or 0
  local net    = gain - power - tfCost
  if net < F_.reshiftMinNet then
    return string.format("worth only %d energy (pays %d, bar %d%s)", net, gain, power,
      tfCost > 0 and string.format(", TF recast %d with %.0fs left", tfCost, tfLeft) or "")
  end
  local mana = playerMana()
  -- (no regen-tick guard: the bar is emptied by the shift, so a tick that
  -- lands first is lost either way, and one that lands after just adds)
  if GetTime() < F_.reshiftHoldUntil then return "held after a failed one" end
  if GetTime() - F_.lastReshiftTime < 1.5 then return "just reshifted" end
  if not spellReady("Reshift") then return "on cooldown" end
  local mana, maxMana = playerMana()
  if not mana then return "mana unknown (no Nampower / DruidBar)" end
  if mana < F_.reshiftCost + F_.reshiftReserve then
    return string.format("mana %d, need %d (%d + %d reserve)", mana, F_.reshiftCost + F_.reshiftReserve, F_.reshiftCost, F_.reshiftReserve)
  end
  -- Farming: a Reshift on every mob would drain the bar in a few pulls and
  -- leave nothing for the one that matters. Only from a mostly full bar.
  if F_.lastSpec == "farm" and maxMana and mana < 0.6 * maxMana then
    return string.format("farm: mana %d of %d, kept for later", mana, maxMana)
  end
  -- Raid trash: the mana is for the bosses. Trash gets Reshifts only while
  -- the bar is nearly full (there is no drinking in cat form between pulls).
  if maxMana and not isBoss() and mana < 0.8 * maxMana then
    return string.format("trash: mana %d of %d, saved for the boss", mana, maxMana)
  end
  return nil
end

local function tryReshift(power)
  local why = reshiftWhy(power)
  if why then
    if why ~= "off" and why ~= "energy above " .. F_.reshiftEnergy and not string.find(why, "^Tiger") and not string.find(why, "^worth") then trace("press", "no Reshift: " .. why) end
    return false
  end
  local now = GetTime()
  F_.lastReshiftTime = now
  F_.lastCastTime = now
  F_.lastAttempt, F_.lastAttemptTime, F_.lastAttemptGcd = "Reshift", now, true
  F_.reshiftCount = F_.reshiftCount + 1
  F_.reshiftWatch = { t0 = now, before = power, peak = power, tickAt = F_.energyTickAt }   -- measure what it pays (TTD frame)
  trace("cast", string.format("Reshift (energy %d, mana %d)", power, playerMana() or -1))
  if FeralDPS.OnDecision then FeralDPS.OnDecision("Reshift", power, GetComboPoints(), true, false) end
  castSpell("Reshift")
  return true
end

local function executeRotation(specOverride)
  -- Every button press lands here first, so companion addons can measure the
  -- press rate itself (FeralTrack: presses/s and pauses between presses).
  if FeralDPS.OnPress then FeralDPS.OnPress() end

  local spec = specOverride or F_.spec
  F_.lastSpec = spec
  local currentForm = resolveForms()
  local wantForm = isCatSpec(spec) and F_.catIndex or F_.bearIndex

  -- Not in the right form: shift (caster -> form, or wrong form -> caster first)
  if currentForm ~= wantForm then
    if wantForm then
      F_.lastCastTime = GetTime()
      trace("cast", "shapeshift -> form " .. tostring(wantForm))
      CastShapeshiftForm(wantForm)
    end
    return
  end

  -- Target safety. This used to be a bare TargetNearestEnemy(), which after the
  -- last mob of a pack died would grab the NEXT pack, and Faerie Fire (30 yd)
  -- or the auto attack would then pull it. The rules now:
  --   * out of combat, never pick a target - a pull is the player's decision
  --   * in combat, a missing/dead target may be replaced, but only by a mob
  --     that is already fighting; anything else is dropped again
  --   * in combat, never act on a target that is not part of the fight
  -- /fdps pull lifts the last rule for deliberate chain-pulling in bear.
  local inCombat = UnitAffectingCombat("player")
  if not UnitExists("target") or UnitIsDead("target") then
    if not inCombat then trace("press", "wait: no target, out of combat") return end
    TargetNearestEnemy()
    if not UnitExists("target") then trace("press", "wait: no target found") return end
    if not UnitAffectingCombat("target") or not UnitCanAttack("player", "target") then
      ClearTarget()
      trace("press", "dropped a target that is not fighting")
      return
    end
  end
  if not UnitCanAttack("player", "target") then trace("press", "wait: target not attackable") return end
  if inCombat and not F_.allowPull and not UnitAffectingCombat("target") then
    trace("press", "wait: target not in combat (pull off)")
    return
  end

  -- A crowd-controlled target (banished Firesworn...) is worth nothing: try to
  -- find a mob in the fight that is not, otherwise wait. Same for a target
  -- that just shrugged off two abilities as "immune" (shield phase).
  if inCombat and targetCrowdControlled() then
    local startName = UnitName("target")
    local found = false
    for i = 1, 8 do
      TargetNearestEnemy()
      if UnitExists("target") and not UnitIsDead("target") and UnitCanAttack("player", "target")
         and UnitAffectingCombat("target") and not targetCrowdControlled() then
        found = true
        break
      end
      if UnitName("target") == startName then break end
    end
    if not found then trace("press", "wait: target crowd-controlled, nothing else to hit") return end
    trace("target", "switched off a CC'd target to " .. tostring(UnitName("target")))
  end
  if F_.immuneHoldUntil > GetTime() and UnitName("target") == F_.immuneHoldTarget then
    trace("press", "wait: target immune (hold)")
    return
  end

  -- Melee first, and BEFORE the GCD guard. Swinging is not a spell cast, so a
  -- fresh target should start taking hits immediately - waiting out the GCD, or
  -- waiting until there is enough energy for an ability, would cost real swings
  -- every time one mob dies and the next is picked up.
  ensureAttacking()

  -- Savage Bite has NO global cooldown on this server, so in bear it goes out
  -- on every press it is ready for, on top of whatever the GCD ability is.
  -- It must NOT eat the rage Maul needs: Maul's rage is only taken when the
  -- swing lands, so a Bite that drops rage below Maul's cost un-queues the
  -- Maul that was already waiting. Maul is ~3x the threat per rage of a Bite,
  -- so the Bite only fires from what is left over ABOVE Maul's cost.
  if not isCatSpec(spec) and spellReady("Savage Bite")
     and (GetTime() - F_.lastBiteTime) > 1.0
     and not isImmune("Savage Bite")
     and UnitMana("player") >= F_.costs["Savage Bite"] + F_.costs["Maul"] then
    F_.lastBiteTime = GetTime()
    F_.lastAttempt, F_.lastAttemptTime, F_.lastAttemptGcd = "Savage Bite", GetTime(), false
    castSpell("Savage Bite")
    if FeralDPS.OnDecision then
      FeralDPS.OnDecision("Savage Bite", UnitMana("player"), 0, true, false)
    end
  end

  -- Enrage: +10 rage at once (Blood Frenzy) and 20 more over 10s, at the price
  -- of an armor debuff. Used when rage-starved on trash; never on bosses
  -- unless /fdps enrageboss is on, because the armor loss matters there.
  if not isCatSpec(spec) and F_.useEnrage and inCombat
     and UnitMana("player") < F_.costs["Maul"]
     and (F_.enrageBoss or not isBoss())
     and spellReady("Enrage") and (GetTime() - F_.lastEnrageTime) > 12 then
    F_.lastEnrageTime = GetTime()
    F_.lastAttempt, F_.lastAttemptTime, F_.lastAttemptGcd = "Enrage", GetTime(), false
    castSpell("Enrage")
    if FeralDPS.OnDecision then
      FeralDPS.OnDecision("Enrage", UnitMana("player"), 0, true, false)
    end
  end

  -- Maul is on-next-swing and does NOT use the global cooldown, so in bear it
  -- is queued here, outside the GCD guard, exactly like Savage Bite. Treating
  -- it as the GCD ability (as before) burned a GCD per Maul that could have
  -- been a free Faerie Fire or a Swipe - a big loss of threat on packs.
  if not isCatSpec(spec) and not maulAlreadyQueued()
     and UnitMana("player") >= F_.costs["Maul"] then
    F_.lastMaulTime = GetTime()
    F_.lastAttempt, F_.lastAttemptTime, F_.lastAttemptGcd = "Maul", GetTime(), false
    castSpell("Maul")
    if FeralDPS.OnDecision then
      FeralDPS.OnDecision("Maul", UnitMana("player"), 0, true, false)
    end
  end

  -- Tiger's Fury has no global cooldown either (1.15.17): fired here, outside
  -- the GCD guard, so it goes out the moment it is wanted - in particular
  -- right after a Reshift (which knocks it off and starts a 1.5s GCD) instead
  -- of 1.5s later. Energy is checked live; the GCD ability picked below sees
  -- what is left.
  if isCatSpec(spec) and (GetTime() - F_.lastTFTime) > 2
     and wantTigersFury(UnitMana("player"), GetComboPoints(), spec ~= "farm")
     and spellReady("Tiger's Fury") then
    local tfPower = UnitMana("player")
    F_.lastAttempt, F_.lastAttemptTime, F_.lastAttemptGcd = "Tiger's Fury", GetTime(), false
    trace("cast", "Tiger's Fury (off the GCD)")
    if FeralDPS.OnDecision then FeralDPS.OnDecision("Tiger's Fury", tfPower, GetComboPoints(), true, false) end
    castAndTrack("Tiger's Fury", GetComboPoints())
  end

  -- Boss consumables are off the GCD too (see tryBossConsumables)
  if inCombat and (F_.useRagePot or F_.useJuju) then
    tryBossConsumables(isCatSpec(spec), UnitMana("player"), GetComboPoints())
  end

  -- GCD guard. 0.3s after our own press the client may not show the GCD yet
  -- (it starts when the server confirms the cast), after that the client's
  -- own reading decides: 1.0s in cat, 1.5s in bear, 0 when the cast never
  -- went out - so a silently failed press is retried at once instead of
  -- after a full second.
  local sinceCast = GetTime() - F_.lastCastTime
  if sinceCast < 0.3 then
    trace("press", string.format("wait: just pressed (%.2fs ago)", sinceCast))
    return
  end
  local gcdLeft = gcdRemaining(isCatSpec(spec))
  if gcdLeft > 0.02 then
    trace("press", string.format("wait: GCD %.2fs left", gcdLeft))
    return
  end

  local opts = {
    power = UnitMana("player"),   -- energy in cat, rage in bear
    pts   = GetComboPoints(),
  }

  local spell = pickSpell(spec, opts)
  if not spell then trace("press", "wait: nothing for the GCD (bear)") return end

  local affordable = canAfford(spell, opts.power) or isClearcasting()
  -- Companion addons (FeralTrack) can watch every decision the rotation makes
  if FeralDPS.OnDecision then
    FeralDPS.OnDecision(spell, opts.power, opts.pts, affordable, isClearcasting())
  end
  trace("decide", string.format("%s  energy %d cp %d behind=%s rip %.1f rake %.1f ff %.1f%s tf %.1f%s",
    spell, opts.power, opts.pts, tostring(isBehindTarget()), getRipRemaining(), getRakeRemaining(),
    getFFRemaining(), ffReady() and "" or " (FF on cd)", getTFRemaining(),
    affordable and "" or "  (cannot afford)"))

  if affordable then
    F_.lastCastTime = GetTime()
    F_.lastAttempt, F_.lastAttemptTime, F_.lastAttemptGcd = spell, GetTime(), true
    trace("cast", spell)
    castAndTrack(spell, opts.pts)
  elseif isCatSpec(spec) and inCombat then
    -- Out of energy for what the rotation wants: refill with Reshift (or the
    -- old DruidBar powershift when that is what is turned on).
    if not tryReshift(opts.power) and opts.power < 35 then
      if tryPowershift(currentForm) then
        F_.lastCastTime = GetTime()
        trace("cast", "powershift")
      end
    end
  end
end

-- ============================================================
-- PUBLIC API - read-only snapshot for companion addons
-- ============================================================
function FeralDPS.State()
  return {
    spec       = F_.spec,
    power      = UnitMana("player"),
    cp         = GetComboPoints(),
    rip        = getRipRemaining(),
    rake       = getRakeRemaining(),
    ff         = getFFRemaining(),
    demo       = getDemoRemaining(),
    tf         = getTFRemaining(),
    behind     = isBehindTarget(),
    clearcast  = isClearcasting(),
    inCombat   = UnitAffectingCombat("player"),
    ripTicks   = F_.ripTicks,
    carnage    = F_.carnageRefreshes,
    ttd        = getTTD(),
    costs      = F_.costs,
    useRake    = F_.useRake,
    useTF      = F_.useTigersFury,
    useBerserk = F_.useBerserk,
  }
end

-- ============================================================
-- HUD
-- ============================================================
-- Blink helper. WoW 1.12 runs Lua 5.0, which has math.mod and NOT math.fmod,
-- so the modulo is done with floor arithmetic instead.
local function blink(rate)
  local t = math.floor(GetTime() * rate)
  return (t - math.floor(t / 2) * 2) == 0
end

local function colorRow(lbl, tmr, left)
  local r, g, b
  if left <= 0 then
    r, g, b = 1, 0.2, 0.2
    tmr:SetText("--")
  elseif left <= 3 then
    r, g, b = 1, 0.8, 0
    tmr:SetText(string.format("%.1f", left))
  else
    r, g, b = 0.2, 1, 0.2
    tmr:SetText(string.format("%.1f", left))
  end
  lbl:SetTextColor(r, g, b)
  tmr:SetTextColor(r, g, b)
end

local saveSettings   -- defined in the INIT section below

-- The HUD stays where it was dragged: its screen position is saved with the
-- settings when the drag ends and applied again at login. /fdps hudreset
-- puts it back at the default spot.
local function hudApplyPosition(f)
  f:ClearAllPoints()
  local p = F_.hudPos
  if p and p.left and p.bottom then
    f:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", p.left, p.bottom)
  else
    f:SetPoint("CENTER", UIParent, "CENTER", 350, -150)
  end
end

local function hudSavePosition(f)
  F_.hudPos = { left = f:GetLeft(), bottom = f:GetBottom() }
  saveSettings()
end

local function createHUD()
  local f = CreateFrame("Frame", "FeralDPSFrame", UIParent)
  f:SetWidth(205)
  f:SetHeight(192)
  hudApplyPosition(f)
  f:SetBackdrop({
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
  })
  f:SetBackdropColor(0, 0, 0, 0.82)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function() this:StartMoving() end)
  f:SetScript("OnDragStop",  function() this:StopMovingOrSizing(); hudSavePosition(this) end)

  local titleText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  titleText:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -6)
  titleText:SetText("|cFFFFD700FeralDPS|r")

  F_.hud.specText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  F_.hud.specText:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -6)

  local function addRow(yOff, labelStr, iconPath)
    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetWidth(20)
    icon:SetHeight(20)
    icon:SetPoint("TOPLEFT", f, "TOPLEFT", 8, yOff)
    if iconPath then icon:SetTexture(iconPath) end

    local lbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetPoint("LEFT", icon, "RIGHT", 4, 0)
    lbl:SetWidth(95)
    lbl:SetJustifyH("LEFT")
    lbl:SetText(labelStr)

    local tmr = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tmr:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, yOff)
    tmr:SetJustifyH("RIGHT")
    tmr:SetText("--")

    return icon, lbl, tmr
  end

  -- Row 1 swaps between Rip (cat) and Demoralizing Roar (bear/aoe)
  F_.hud.r1Icon, F_.hud.r1Lbl, F_.hud.r1Tmr =
    addRow(-24, "Rip", "Interface\\Icons\\Ability_GhoulFrenzy")
  F_.hud.r2Icon, F_.hud.r2Lbl, F_.hud.r2Tmr =
    addRow(-48, "Rake", "Interface\\Icons\\Ability_Druid_Disembowel")
  F_.hud.r3Icon, F_.hud.r3Lbl, F_.hud.r3Tmr =
    addRow(-72, "Faerie Fire", "Interface\\Icons\\Spell_Nature_FaerieFire")

  local sep = f:CreateTexture(nil, "ARTWORK")
  sep:SetHeight(1)
  sep:SetWidth(189)
  sep:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -98)
  sep:SetTexture(0.4, 0.4, 0.4, 0.6)

  -- Position bar (cat only): green behind, flashing red in front
  local posBar = CreateFrame("Frame", "FeralDPSPosBar", f)
  posBar:SetHeight(20)
  posBar:SetWidth(189)
  posBar:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -104)
  posBar:SetBackdrop({
    bgFile  = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 8,
    insets = { left = 2, right = 2, top = 2, bottom = 2 },
  })
  posBar:SetBackdropColor(0, 0.6, 0, 0.7)
  F_.hud.posBar = posBar

  F_.hud.posText = posBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  F_.hud.posText:SetPoint("CENTER", posBar, "CENTER", 0, 0)
  F_.hud.posText:SetText("|cFF00FF00BEHIND|r")

  F_.hud.cpText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  F_.hud.cpText:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -130)
  F_.hud.cpText:SetJustifyH("LEFT")

  F_.hud.ccAlert = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  F_.hud.ccAlert:SetPoint("BOTTOM", f, "BOTTOM", 0, 24)
  F_.hud.ccAlert:SetText("")

  F_.hud.nextText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  F_.hud.nextText:SetPoint("BOTTOM", f, "BOTTOM", 0, 9)
  F_.hud.nextText:SetText("Next: --")

  F_.hud.frame = f

  f:SetScript("OnUpdate", function()
    if (this.tick or 0) > GetTime() then return end
    this.tick = GetTime() + 0.1

    local power = UnitMana("player")
    local pts   = GetComboPoints()
    local isCat = isCatSpec(F_.spec)

    -- Timer rows
    if isCat then
      F_.hud.r1Lbl:SetText("Rip")
      F_.hud.r1Icon:SetTexture("Interface\\Icons\\Ability_GhoulFrenzy")
      colorRow(F_.hud.r1Lbl, F_.hud.r1Tmr, getRipRemaining())

      F_.hud.r2Icon:Show(); F_.hud.r2Lbl:Show(); F_.hud.r2Tmr:Show()
      -- With Rake upkeep off there is no Rake to watch, so the row shows the
      -- buff that actually needs watching: Tiger's Fury.
      if F_.useRake then
        F_.hud.r2Lbl:SetText("Rake")
        F_.hud.r2Icon:SetTexture("Interface\\Icons\\Ability_Druid_Disembowel")
        colorRow(F_.hud.r2Lbl, F_.hud.r2Tmr, getRakeRemaining())
      else
        F_.hud.r2Lbl:SetText("Tiger's Fury")
        F_.hud.r2Icon:SetTexture("Interface\\Icons\\Ability_Mount_JungleTiger")
        colorRow(F_.hud.r2Lbl, F_.hud.r2Tmr, getTFRemaining())
      end
    else
      F_.hud.r1Lbl:SetText("Demo Roar")
      F_.hud.r1Icon:SetTexture("Interface\\Icons\\Ability_Druid_DemoralizingRoar")
      colorRow(F_.hud.r1Lbl, F_.hud.r1Tmr, getDemoRemaining())

      F_.hud.r2Icon:Hide(); F_.hud.r2Lbl:Hide(); F_.hud.r2Tmr:Hide()
    end

    colorRow(F_.hud.r3Lbl, F_.hud.r3Tmr, getFFRemaining())

    -- Combo points (cat) or rage readout (bear)
    if isCat then
      local cpStr = "CP: "
      for i = 1, 5 do
        if i <= pts then cpStr = cpStr .. "|cFFFFD700O|r"
        else             cpStr = cpStr .. "|cFF444444O|r" end
      end
      local manaStr = ""
      if F_.useReshift then
        local mana = playerMana()
        if mana then
          local ok = mana >= F_.reshiftCost + F_.reshiftReserve
          manaStr = (ok and "   |cFF8888FF" or "   |cFF884444") .. mana .. " mana|r"
        end
      end
      local tickIn = energyTickIn()
      local tickStr = tickIn and string.format(" |cFF888888(+%d in %.1fs)|r", F_.energyTickSize, tickIn) or ""
      F_.hud.cpText:SetText(cpStr .. "   |cFFFFFF00" .. power .. "|r energy" .. tickStr .. manaStr)
    else
      F_.hud.cpText:SetText("|cFFFF4444" .. power .. "|r rage")
    end

    -- Position bar: only meaningful in cat (Shred)
    if isCat then
      F_.hud.posBar:Show()
      if not hasSuperWoW() then
        F_.hud.posBar:SetBackdropColor(0.5, 0.4, 0, 0.7)
        F_.hud.posText:SetText("|cFFFFD700NO SUPERWOW|r")
      elseif isBehindTarget() then
        F_.hud.posBar:SetBackdropColor(0, 0.55, 0, 0.75)
        F_.hud.posText:SetText("|cFF00FF00BEHIND|r")
      else
        if UnitAffectingCombat("player") and blink(3) then
          F_.hud.posBar:SetBackdropColor(0.85, 0, 0, 0.85)
        else
          F_.hud.posBar:SetBackdropColor(0.5, 0, 0, 0.6)
        end
        F_.hud.posText:SetText("|cFFFF3333FRONTING|r")
      end
    else
      F_.hud.posBar:Hide()
    end

    -- Next ability. In bear the GCD slot can be empty (Maul and Savage Bite
    -- are queued off the GCD), so the HUD shows those instead.
    local nextAb = pickSpell(F_.spec, { power = power, pts = pts })
    if not nextAb then
      if power >= F_.costs["Savage Bite"] + F_.costs["Maul"] then
        nextAb = "Maul + Savage Bite"
      else
        nextAb = "Maul"
      end
      if power >= F_.costs["Maul"] then
        F_.hud.nextText:SetText("Next: |cFF00FF00" .. nextAb .. "|r")
      else
        F_.hud.nextText:SetText("Next: |cFF888888Maul|r |cFFFF4444(low rage)|r")
      end
    elseif canAfford(nextAb, power) or isClearcasting() then
      F_.hud.nextText:SetText("Next: |cFF00FF00" .. nextAb .. "|r")
    elseif isCat and UnitAffectingCombat("player") and not reshiftWhy(power) then
      F_.hud.nextText:SetText("Next: |cFF8888FFReshift|r |cFF888888(energy -> " .. tostring(F_.reshiftGain or 60) .. ", then " .. nextAb .. ")|r")
    else
      local lack = isCat and "(low energy)" or "(low rage)"
      F_.hud.nextText:SetText("Next: |cFF888888" .. nextAb .. "|r |cFFFF4444" .. lack .. "|r")
    end

    -- Spec label
    if F_.spec == "cat" then
      F_.hud.specText:SetText("|cFF00FFFFCat|r")
    elseif F_.spec == "farm" then
      F_.hud.specText:SetText("|cFF7FFF00Farm|r")
    elseif F_.spec == "bear" then
      F_.hud.specText:SetText("|cFFFF8C00Bear|r")
    else
      F_.hud.specText:SetText("|cFFFF4444AoE|r")
    end

    -- Target state warnings first: a banished / immune target explains an
    -- energy bar stuck at 100 better than any other line on this HUD
    if F_.lastError and (GetTime() - F_.lastErrorTime) < 2 then
      F_.hud.ccAlert:SetText("|cFFFF3333" .. F_.lastError .. "|r")
    elseif UnitExists("target") and targetCrowdControlled() then
      F_.hud.ccAlert:SetText("|cFFFF3333TARGET BANISHED / CC'D|r")
    elseif F_.immuneHoldUntil > GetTime() and UnitName("target") == F_.immuneHoldTarget then
      F_.hud.ccAlert:SetText("|cFFFF3333TARGET IMMUNE (phase?)|r")
    else
    -- Clearcasting (Omen of Clarity) alert
    if isClearcasting() then
      if blink(4) then
        F_.hud.ccAlert:SetText("|cFFFFD700!! CLEARCASTING !!|r")
      else
        F_.hud.ccAlert:SetText("|cFFFFFFFF!! CLEARCASTING !!|r")
      end
    elseif npBlocked("Rip") then
      F_.hud.ccAlert:SetText("|cFFFF8800RIP NOT ON TARGET (debuff cap) - biting|r")
    else
      F_.hud.ccAlert:SetText("")
    end
    end
  end)

  return f
end

-- ============================================================
-- INIT
-- ============================================================
saveSettings = function()
  FeralDPS_Settings = {
    version       = 10,
    spec          = F_.spec,
    useRip        = F_.useRip,
    useRake       = F_.useRake,
    useFaerieFire = F_.useFaerieFire,
    clawBleeds    = F_.clawBleeds,
    useTigersFury = F_.useTigersFury,
    useBerserk    = F_.useBerserk,
    allowPull     = F_.allowPull,
    berserkTrash  = F_.berserkTrash,
    chatWindow    = F_.chatWindow,
    powershift    = F_.powershift,
    useReshift    = F_.useReshift,
    reshiftEnergy = F_.reshiftEnergy,
    reshiftEnergyManual = F_.reshiftEnergyManual,
    reshiftGain   = F_.reshiftGain,
    reshiftReserve = F_.reshiftReserve,
    reshiftMinNet = F_.reshiftMinNet,
    bossHp        = F_.bossHp,
    reshiftCost   = F_.reshiftCost,
    useEnrage     = F_.useEnrage,
    useRagePot    = F_.useRagePot,
    useJuju       = F_.useJuju,
    enrageBoss    = F_.enrageBoss,
    hudPos        = F_.hudPos,
  }
  FeralDPS_Settings.trace   = F_.traceLog
  FeralDPS_Settings.traceOn = F_.trace
  -- learned bleed immunities survive logout (see persistImmune)
  persistImmune()
end

-- Talents are looked up by name, so a moved talent tree does not break costs.
local function talentRank(wanted)
  local want = string.lower(wanted)
  for tab = 1, (GetNumTalentTabs() or 0) do
    for i = 1, (GetNumTalents(tab) or 0) do
      local name, _, _, _, rank = GetTalentInfo(tab, i)
      if name and string.lower(name) == want then return rank or 0 end
    end
  end
  return 0
end

-- 1.15.15: the talent ranks were read once, at PLAYER_LOGIN - and on this
-- client the talent tree is still empty then (every rank came back 0: Furor
-- 0/5 in the Reshift gate, Shred priced at 60, Carnage 0/2, so a 5-CP Rip
-- was recast at 2s left instead of letting the Bite refresh it). The ranks
-- are now read again after entering the world, and re-tried every second
-- until the tree answers. Returns true when at least one rank was found.
local function readTalents()
  local f, s, n, b, c, u = talentRank("Ferocity"), talentRank("Improved Shred"),
    talentRank("Natural Shapeshifter"), talentRank("Blood Frenzy"),
    talentRank("Carnage"), talentRank("Furor")
  F_.ferocityRank, F_.impShredRank, F_.natShifterRank = f, s, n
  F_.bloodFrenzyRank, F_.carnageRank, F_.furorRank = b, c, u
  F_.tfDur = 6 + (F_.bloodFrenzyRank * 6)
  local found = (f + s + n + b + c + u) > 0
  F_.talentsRead = found
  return found
end

local function talentSummary()
  return string.format("Ferocity %d  Improved Shred %d  Carnage %d  Blood Frenzy %d  Furor %d  Natural Shapeshifter %d",
    F_.ferocityRank, F_.impShredRank, F_.carnageRank, F_.bloodFrenzyRank, F_.furorRank, F_.natShifterRank)
end

local function computeCosts()
  local fero  = F_.ferocityRank
  local shred = F_.impShredRank
  local idol  = F_.idolReduction
  local brut  = F_.idolRage or 0     -- Idol of Brutality: -3 rage on Maul / Swipe

  F_.costs = {
    -- Cat (energy)
    ["Shred"]               = 60 - (shred * 6),
    ["Claw"]                = 45 - fero - idol,
    ["Rake"]                = 40 - fero - idol,
    ["Rip"]                 = 30,
    ["Ferocious Bite"]      = 35,
    ["Ravage"]              = 60,
    ["Pounce"]              = 50,
    ["Tiger's Fury"]        = 30,
    ["Cower"]               = 20,
    -- Bear (rage)
    ["Maul"]                = 15 - fero - brut,
    ["Swipe"]               = 20 - brut,
    ["Savage Bite"]         = 25 - fero,
    ["Demoralizing Roar"]   = 10,
    ["Bash"]                = 10,
    ["Growl"]               = 10,
    -- Free
    ["Faerie Fire (Feral)"] = 0,
    ["Berserk"]             = 0,
  }
end

-- The relic (ranged) slot changes both energy costs and bleed durations.
--   Idol of Ferocity  : -3 energy on Claw and Rake
--   Idol of Savagery  : Rake and Rip tick 10% faster AND last 10% shorter,
--                       so the tick COUNT is unchanged - the whole bleed is
--                       just compressed. Only the durations move.
--   Idol of Brutality : -3 rage on Maul and Swipe (bear)
local function readRelic()
  F_.idolReduction = 0
  F_.idolRage    = 0
  F_.relicFactor = 1
  F_.rakeDur = 9
  F_.relic   = nil

  local slot = GetInventorySlotInfo("RangedSlot")
  local link = GetInventoryItemLink("player", slot)
  if not link then return end

  if string.find(link, "Idol of Ferocity") then
    F_.idolReduction = 3
    F_.relic = "Idol of Ferocity"
  elseif string.find(link, "Idol of Savagery") then
    F_.relicFactor = 0.9
    F_.rakeDur = 9 * 0.9
    F_.relic = "Idol of Savagery"
  elseif string.find(link, "Idol of Brutality") then
    F_.idolRage = 3
    F_.relic = "Idol of Brutality"
  end
  setRipDuration(F_.lastRipCP > 0 and F_.lastRipCP or 5)
end

local function feralInit()
  if FeralDPS_Settings then
    if FeralDPS_Settings.spec          then F_.spec          = FeralDPS_Settings.spec          end
    if type(FeralDPS_Settings.hudPos) == "table" then F_.hudPos = FeralDPS_Settings.hudPos end
    if FeralDPS_Settings.useRip        ~= nil then F_.useRip        = FeralDPS_Settings.useRip        end
    if FeralDPS_Settings.useRake       ~= nil then F_.useRake       = FeralDPS_Settings.useRake       end
    if FeralDPS_Settings.useFaerieFire ~= nil then F_.useFaerieFire = FeralDPS_Settings.useFaerieFire end
    if FeralDPS_Settings.useTigersFury ~= nil then F_.useTigersFury = FeralDPS_Settings.useTigersFury end
    if FeralDPS_Settings.clawBleeds    ~= nil then F_.clawBleeds    = FeralDPS_Settings.clawBleeds    end
    if FeralDPS_Settings.useBerserk    ~= nil then F_.useBerserk    = FeralDPS_Settings.useBerserk    end
    if FeralDPS_Settings.allowPull     ~= nil then F_.allowPull     = FeralDPS_Settings.allowPull     end
    if FeralDPS_Settings.berserkTrash  ~= nil then F_.berserkTrash  = FeralDPS_Settings.berserkTrash  end
    if FeralDPS_Settings.chatWindow    ~= nil then F_.chatWindow    = FeralDPS_Settings.chatWindow    end
    if FeralDPS_Settings.powershift    ~= nil then F_.powershift    = FeralDPS_Settings.powershift    end
    if FeralDPS_Settings.useReshift    ~= nil then F_.useReshift    = FeralDPS_Settings.useReshift    end
    if tonumber(FeralDPS_Settings.reshiftEnergy)  then F_.reshiftEnergy  = tonumber(FeralDPS_Settings.reshiftEnergy)  end
    if FeralDPS_Settings.reshiftEnergyManual ~= nil then F_.reshiftEnergyManual = FeralDPS_Settings.reshiftEnergyManual end
    if tonumber(FeralDPS_Settings.reshiftGain)    then F_.reshiftGain    = tonumber(FeralDPS_Settings.reshiftGain)    end
    if tonumber(FeralDPS_Settings.reshiftReserve) then F_.reshiftReserve = tonumber(FeralDPS_Settings.reshiftReserve) end
    if tonumber(FeralDPS_Settings.reshiftMinNet)  then F_.reshiftMinNet  = tonumber(FeralDPS_Settings.reshiftMinNet)  end
    if tonumber(FeralDPS_Settings.bossHp)         then F_.bossHp         = tonumber(FeralDPS_Settings.bossHp)         end
    if tonumber(FeralDPS_Settings.reshiftCost)    then F_.reshiftCost    = tonumber(FeralDPS_Settings.reshiftCost)    end
    if FeralDPS_Settings.useEnrage     ~= nil then F_.useEnrage     = FeralDPS_Settings.useEnrage     end
    if FeralDPS_Settings.useRagePot    ~= nil then F_.useRagePot    = FeralDPS_Settings.useRagePot    end
    if FeralDPS_Settings.useJuju       ~= nil then F_.useJuju       = FeralDPS_Settings.useJuju       end
    if FeralDPS_Settings.enrageBoss    ~= nil then F_.enrageBoss    = FeralDPS_Settings.enrageBoss    end
    if type(FeralDPS_Settings.trace) == "table" then F_.traceLog = FeralDPS_Settings.trace end
    if FeralDPS_Settings.traceOn then
      F_.trace = true
      F_.traceStart = GetTime()
      table.insert(F_.traceLog, "---- reload / login ----")
    end
    if type(FeralDPS_Settings.immune) == "table" then
      -- Only bleeds and Faerie Fire are a property of the mob. Anything else
      -- (Maul, Savage Bite, Demo Roar...) that once read "immune" was a boss
      -- shield PHASE, and must not be remembered - it would silence the whole
      -- bear rotation on that boss forever. Old entries are cleaned up here.
      F_.immune = FeralDPS_Settings.immune
      for mob, t in pairs(F_.immune) do
        for sp, _ in pairs(t) do
          if not LEARNABLE_IMMUNE[sp] then t[sp] = nil end
        end
        if not next(t) then F_.immune[mob] = nil end
      end
    end

    -- Version 2 forced Rake ON (Ancient Brutality guess); the 6-minute runs then
    -- measured it as a wash behind the target, so version 3 turns it OFF once.
    -- Fronting still applies Rake regardless of this toggle.
    if (FeralDPS_Settings.version or 1) < 3 then
      F_.useRake = false
      out(
        "|cFFFFD700FeralDPS|r: Rake upkeep set to off (measured neutral). |cFFFFFFFF/fdps rake|r to undo.")
    end
    -- Version 4/5: Rips the client refused ("Out of range." - Onyxia in the
    -- air) used to count as "Rip landed, no debuff", and three of those in a
    -- row marked the target bleed-immune for good. Onyxia and Broodcommander
    -- Axelus got that mark on 02/10 while the combat log never once said
    -- "immune" for them. The same heuristic built most of the old list, so
    -- version 5 keeps only the mobs whose immunity is a matter of record -
    -- elementals, skeletons and ghosts - and forgets the rest. A real
    -- immunity is re-learned from the combat log at the cost of one Rip;
    -- a wrong one costs every Rip and Rake of the fight. /fdps immune lists it.
    if (FeralDPS_Settings.version or 1) < 5 then
      local doubtful = {
        "Onyxia", "Broodcommander Axelus",                     -- 02/10, refused Rips in the air
        "The Beast", "Sorcerer-Thane Thaurissan",              -- beast / dwarf: bleed in vanilla
        "Lord Valthalak", "Alarus", "Corpsemuncher",           -- undead, but not skeletal
        "Commander Andreon", "Guard Captain Gort",             -- humanoids
        "Hivaxxis", "Grellkin Channeler", "Cindarion",         -- Turtle mobs, type unclear
        "Echo of Time", "Shadowforge Blazeweaver",
      }
      local dropped = ""
      for _, mob in ipairs(doubtful) do
        if F_.immune[mob] then F_.immune[mob] = nil; dropped = dropped .. mob .. ", " end
      end
      if dropped ~= "" then
        out("|cFFFFD700FeralDPS|r: forgot bleed immunities that were learned by guesswork: "
          .. string.sub(dropped, 1, -3) .. ". Real ones are re-learned from the combat log. |cFFFFFFFF/fdps immune|r lists what is left.")
      end
    end
    -- Version 6 (1.15): the Chronicle logs of the three best ferals on the
    -- server (Onyxia, 5-6/10) keep Rake up 60-70% of the fight and build with
    -- Claw while both bleeds are on (Open Wounds +60%, no positioning), with
    -- Shred saved for Clearcasting. Rake was measured neutral behind a dummy
    -- in isolation, but its ticks also hand back energy (Ancient Brutality)
    -- and feed Claw - so both go on once. /fdps rake and /fdps claw undo it.
    if (FeralDPS_Settings.version or 1) < 6 then
      F_.useRake, F_.clawBleeds, F_.useReshift = true, true, true
      out("|cFFFFD700FeralDPS|r 1.15: Rake upkeep ON, Claw with both bleeds ON, Reshift ON (the top feral logs do all three). "
        .. "|cFFFFFFFF/fdps rake|r, |cFFFFFFFF/fdps claw|r, |cFFFFFFFF/fdps reshift|r to undo.")
    end
    -- Version 7 (1.15.8): the energy-bar measurement of what a Reshift pays
    -- was noisy and once pinned the ceiling at 30 from a "+70"; the exact
    -- Nampower energize events replace it. Start over from 30.
    if (FeralDPS_Settings.version or 1) < 7 and not F_.reshiftEnergyManual then
      F_.reshiftEnergy, F_.reshiftGain, F_.reshiftGains = 30, nil, nil
    end
    -- Version 8 (1.15.9): René pointed out that a Reshift empties the bar
    -- first and sets it to 60 - it does not add 60. Energy in the bar is
    -- lost, so it is pressed at 15 or less from now on (was 30).
    if (FeralDPS_Settings.version or 1) < 8 and not F_.reshiftEnergyManual then
      F_.reshiftEnergy = 15
      out("|cFFFFD700FeralDPS|r 1.15.9: Reshift empties the energy bar before paying its 60, so it now fires at 15 energy or less (was 30). |cFFFFFFFF/fdps reshift energy <n>|r to change.")
    end
    -- Version 9 (1.15.18): the measured Reshift level had settled on 40
    -- because the energize events only carry Furor's 40 and a regen tick in
    -- the window threw the bar reading (60) away. Forget it: the next Reshift
    -- measures again from the bar, 60 assumed until then.
    if (FeralDPS_Settings.version or 1) < 9 then
      F_.reshiftGain = nil
    end
    -- Version 10 (1.15.19): the bar measurement still read 40, because the
    -- enchant's +20 passed for a regen tick and was taken off. Once more.
    if (FeralDPS_Settings.version or 1) < 10 then
      F_.reshiftGain = nil
    end
  end

  readTalents()

  readRelic()
  computeCosts()
  buildSpellbook()
  npInitPlayer()

  out("|cFFFFD700FeralDPS|r loaded.  Ferocity " .. F_.ferocityRank
    .. " / Improved Shred " .. F_.impShredRank .. " / Carnage " .. F_.carnageRank
    .. "  ->  Shred " .. F_.costs["Shred"] .. ", Claw " .. F_.costs["Claw"] .. ", Maul " .. F_.costs["Maul"]
    .. (F_.talentsRead and "" or "   |cFFFF8800(talent tree not loaded yet - read again shortly)|r"))
  if F_.relic then
    out(string.format(
      "  Relic: |cFF00FF00%s|r  ->  Rip %.1fs at 5 CP, Rake %.1fs", F_.relic, F_.ripBase[5] * F_.relicFactor, F_.rakeDur))
  end
  out("  Macros: |cFFFFFFFF#showtooltip Shred|r / |cFFFFFFFF/fdps cat|r")
  out("          |cFFFFFFFF#showtooltip Maul|r  / |cFFFFFFFF/fdps bear|r")
  out("          |cFFFFFFFF#showtooltip Swipe|r / |cFFFFFFFF/fdps aoe|r")

  if not UnitXP then
    out(
      "  |cFFFF8800Note:|r UnitXP not found — Shred/Claw position check disabled (needs SuperWoW).")
  end
  if type(GetNampowerVersion) == "function" then
    local a, b, c = GetNampowerVersion()
    out("  Nampower " .. tostring(a) .. "." .. tostring(b) .. "." .. tostring(c)
      .. ": debuffs read by spell id, bleed ticks and the raid debuff cap tracked.")
  else
    out("  |cFFFF8800Note:|r Nampower not found — raid debuff cap detection off.")
  end
  if F_.powershift and not DruidBarKey then
    F_.powershift = false
    out(
      "  |cFFFF8800Note:|r powershifting turned off — DruidBar not found.")
  end
  if F_.useReshift then
    local mana = playerMana()
    if not (F_.book and F_.book["Reshift"]) then
      out("  |cFFFF8800Note:|r Reshift is on but not in the spellbook (level 60 skill from the trainer) - it will not be used.")
    elseif not mana then
      out("  |cFFFF8800Note:|r Reshift is on but mana cannot be read while shifted (needs Nampower or DruidBar) - it will not be used.")
    else
      out(string.format("  Reshift on: at or below %d energy (sets the bar to %s), %d mana each, %d kept back (mana now %d).",
        F_.reshiftEnergy, tostring(F_.reshiftGain or "?"), F_.reshiftCost, F_.reshiftReserve, mana))
    end
  end
  saveSettings()     -- the version stamp and any migration above are kept
end

-- ============================================================
-- ADDON ENTRY POINT (called from FeralDPS.xml OnLoad)
-- ============================================================
function FeralDPS_OnLoad()
  SLASH_FDPS1 = "/fdps"
  SLASH_FDPS2 = "/feraldps"

  local function toggle(field, label)
    F_[field] = not F_[field]
    saveSettings()
    local state = F_[field] and "|cFF00FF00on|r" or "|cFFFF4444off|r"
    announce("|cFFFFD700FeralDPS|r: " .. label .. " " .. state)
  end

  SlashCmdList["FDPS"] = function(subcmd)
    local raw = subcmd or ""
    local _, _, word, rest = string.find(raw, "^%s*(%S*)%s*(.-)%s*$")
    local cmd = string.lower(word or "")

    if cmd == "chat" then
      if rest == "" then
        F_.chatWindow = nil
        saveSettings()
        out("|cFFFFD700FeralDPS|r: output back in the general chat window.")
      else
        if not chatFrameByName(rest) then
          if FCF_OpenNewWindow then FCF_OpenNewWindow(rest) end
        end
        F_.chatWindow = rest
        saveSettings()
        out("|cFFFFD700FeralDPS|r: output now goes to the |cFFFFFFFF" .. rest .. "|r chat tab"
          .. (chatFrameByName(rest) and "." or " — create a tab with that name (right-click a chat tab -> Create New Window)."))
      end
      return
    end

    if cmd == "cat" then
      F_.spec = "cat";  saveSettings(); executeRotation("cat")

    elseif cmd == "bear" then
      F_.spec = "bear"; saveSettings(); executeRotation("bear")

    elseif cmd == "aoe" then
      F_.spec = "aoe";  saveSettings(); executeRotation("aoe")

    elseif cmd == "farm" then
      F_.spec = "farm"; saveSettings(); executeRotation("farm")

    elseif cmd == "rip"   then toggle("useRip",        "Rip upkeep")
    elseif cmd == "rake"  then toggle("useRake",       "Rake upkeep")
    elseif cmd == "ff"    then toggle("useFaerieFire", "Faerie Fire (Feral)")
    elseif cmd == "tf"    then toggle("useTigersFury", "Tiger's Fury")
    elseif cmd == "claw"  then toggle("clawBleeds",    "Claw while both bleeds are up")
    elseif cmd == "berserk" then toggle("useBerserk",  "Auto-Berserk on bosses (energy low, Rip up, Tiger's Fury up; /fdps btrash for trash too)")
    elseif cmd == "pull"  then toggle("allowPull",     "Acting on out-of-combat targets mid-fight (chain pull)")
    elseif cmd == "btrash" then toggle("berserkTrash", "Berserk on trash too (on cooldown whenever the energy dips; off = bosses only)")
    elseif cmd == "enrage" then toggle("useEnrage",    "Bear: Enrage when rage-starved (trash)")
    elseif cmd == "pot"    then F_.potWarned = false; toggle("useRagePot", "Boss: Mighty Rage Potion (before the first Rip, then Shred bursts; bear: when rage is short)")
    elseif cmd == "juju"   then F_.jujuWarned = false; toggle("useJuju", "Boss: Juju Flurry whenever it is ready")
    elseif cmd == "enrageboss" then toggle("enrageBoss", "Bear: Enrage on bosses too (armor debuff!)")

    elseif cmd == "shift" then
      if not DruidBarKey then
        out(
          "|cFFFFD700FeralDPS|r: powershifting needs |cFFFFFFFFDruidBar|r installed. On OctoWoW use |cFFFFFFFF/fdps reshift|r instead.")
      else
        toggle("powershift", "Powershifting")
        if F_.powershift then
          out(
            "  |cFFFF8800Note:|r shifting drops Tiger's Fury — with Blood Frenzy that is an 18s +20% attack speed buff.")
        end
      end

    elseif cmd == "reshift" then
      local sub = string.lower(rest or "")
      local _, _, key, num = string.find(sub, "^(%a+)%s*(%d*)")
      num = tonumber(num)
      if key == "energy" and num then
        F_.reshiftEnergy = num; F_.reshiftEnergyManual = true; saveSettings()
        announce("|cFFFFD700FeralDPS|r: Reshift when energy is at or below |cFFFFFFFF" .. num .. "|r (that much is thrown away by the shift).")
      elseif key == "energy" and string.find(sub, "auto") then
        F_.reshiftEnergyManual = false; F_.reshiftEnergy = 15; saveSettings()
        announce("|cFFFFD700FeralDPS|r: Reshift energy ceiling back to the default 15.")
      elseif key == "reserve" and num then
        F_.reshiftReserve = num; saveSettings()
        announce("|cFFFFD700FeralDPS|r: Reshift keeps |cFFFFFFFF" .. num .. "|r mana back.")
      elseif key == "cost" and num then
        F_.reshiftCost = num; saveSettings()
        announce("|cFFFFD700FeralDPS|r: Reshift counted as |cFFFFFFFF" .. num .. "|r mana per use.")
      elseif (key == "net" or key == "minnet" or key == "worth") and num then
        F_.reshiftMinNet = num; saveSettings()
        announce("|cFFFFD700FeralDPS|r: Reshift only when it is worth at least |cFFFFFFFF" .. num .. "|r energy (what it pays, minus the bar, minus a Tiger's Fury recast if TF has over 3s left).")
      elseif sub == "" then
        toggle("useReshift", "Reshift when out of energy")
        F_.reshiftNoGain = 0
        if F_.useReshift then
          local mana, max = playerMana()
          out(string.format("  energy at or below %d, %d mana per use, %d kept back  ->  mana now %s, Furor %d/5, in spellbook: %s",
            F_.reshiftEnergy, F_.reshiftCost, F_.reshiftReserve, tostring(mana), F_.furorRank,
            tostring(F_.book and F_.book["Reshift"] ~= nil)))
          if not mana then out("  |cFFFF8800Note:|r mana cannot be read while shifted without Nampower (or DruidBar) - Reshift stays off until it can.") end
          out("  sets the bar to " .. tostring(F_.reshiftGain or "? (measured on the first one)") .. " energy (what is in it is lost), used at or below " .. F_.reshiftEnergy
            .. ", and only when worth " .. F_.reshiftMinNet .. "+ energy net (a TF recast counts against it)")
        end
      else
        out("|cFFFFD700FeralDPS|r: /fdps reshift  |  /fdps reshift energy 15  |  /fdps reshift reserve 700  |  /fdps reshift cost 348  |  /fdps reshift net 20")
      end

    elseif cmd == "trace" then
      local sub = string.lower(rest or "")
      if string.find(sub, "^show") then
        local _, _, n = string.find(sub, "(%d+)")
        n = tonumber(n) or 30
        local total = table.getn(F_.traceLog)
        out("|cFFFFD700FeralDPS|r: trace, last " .. math.min(n, total) .. " of " .. total .. " lines:")
        for i = math.max(1, total - n + 1), total do out("  " .. F_.traceLog[i]) end
      elseif sub == "clear" then
        F_.traceLog = {}
        saveSettings()
        out("|cFFFFD700FeralDPS|r: trace cleared.")
      else
        F_.trace = not F_.trace
        if F_.trace then
          F_.traceLog = {}
          F_.traceStart = GetTime()
          out("|cFFFFD700FeralDPS|r: trace |cFF00FF00on|r - every press, decision, cast and client error is logged. /reload writes it to disk.")
        else
          out("|cFFFFD700FeralDPS|r: trace |cFFFF4444off|r - " .. table.getn(F_.traceLog) .. " lines kept.")
        end
        saveSettings()
      end

    elseif cmd == "immune" then
      -- /fdps immune            list the learned bleed immunities
      -- /fdps immune clear X    forget mob X (or "all"); the combat log's
      --                         "is immune" line re-learns a real one at once
      local _, _, sub, who = string.find(rest or "", "^(%S*)%s*(.-)%s*$")
      sub = string.lower(sub or "")
      if sub == "clear" and who ~= "" then
        if string.lower(who) == "all" then
          F_.immune = {}
          out("|cFFFFD700FeralDPS|r: all learned immunities forgotten.")
        else
          local hit = nil
          for mob, _ in pairs(F_.immune) do
            if string.lower(mob) == string.lower(who) then hit = mob end
          end
          if hit then
            F_.immune[hit] = nil
            out("|cFFFFD700FeralDPS|r: " .. hit .. " forgotten - Rip and Rake will be tried again.")
          else
            out("|cFFFFD700FeralDPS|r: no immunity stored for '" .. who .. "'.")
          end
        end
        saveSettings()
      else
        local n = 0
        out("|cFFFFD700FeralDPS|r: learned immunities (|cFFFFFFFF/fdps immune clear <name>|r forgets one):")
        for mob, t in pairs(F_.immune) do
          local sp = ""
          for s, _ in pairs(t) do sp = sp .. s .. " " end
          out("  " .. mob .. "  -  " .. sp)
          n = n + 1
        end
        if n == 0 then out("  (none)") end
      end

    elseif cmd == "hudreset" then
      F_.hudPos = nil
      if F_.hud.frame then hudApplyPosition(F_.hud.frame) end
      saveSettings()
      out("|cFFFFD700FeralDPS|r: HUD moved back to its default position.")

    elseif cmd == "show" then
      if F_.hud.frame then F_.hud.frame:Show() end

    elseif cmd == "hide" then
      if F_.hud.frame then F_.hud.frame:Hide() end

    elseif cmd == "reload" then
      F_.immune = {}
      saveSettings()          -- forget learned immunities on disk too
      feralInit()

    elseif cmd == "bosshp" then
      local n = tonumber(rest)
      if n then
        F_.bossHp = n; saveSettings()
        out("|cFFFFD700FeralDPS|r: an elite with |cFFFFFFFF" .. n .. "|r+ max health counts as a boss (Berserk, Reshift mana, Rip on trust).")
      else
        out("|cFFFFD700FeralDPS|r: /fdps bosshp <health>  - currently " .. tostring(F_.bossHp) .. " (dungeons only; in a raid zone or raid group only ?? counts). Zone: " .. tostring(GetRealZoneText()) .. (inRaid() and " (raid)" or " (not a raid)") .. ". Target: " .. tostring(UnitName("target")) .. " " .. tostring(UnitClassification("target")) .. " " .. tostring(UnitHealthMax("target")) .. " hp  ->  boss: " .. tostring(isBoss()))
      end

    elseif cmd == "talents" then
      -- What the client reports for the talent tree, and what the rotation
      -- made of it. Only talents with points in them are listed.
      local tabs = GetNumTalentTabs() or 0
      out("|cFFFFD700FeralDPS talents:|r " .. tabs .. " tab(s) reported by the client")
      local shown = 0
      for tab = 1, tabs do
        local tabName = GetTalentTabInfo(tab)
        for i = 1, (GetNumTalents(tab) or 0) do
          local name, _, _, _, rank, maxRank = GetTalentInfo(tab, i)
          if name and (rank or 0) > 0 then
            shown = shown + 1
            out(string.format("  [%s %d] %s %d/%d", tostring(tabName), i, name, rank or 0, maxRank or 0))
          end
        end
      end
      if shown == 0 then
        out("  |cFFFF8800No talent with points reported|r - the tree has not been sent to the client yet. Open the talent window once, then |cFFFFFFFF/fdps reload|r.")
      end
      if readTalents() then computeCosts() end
      out("  Used by the rotation: " .. talentSummary())
      out("  Costs: Shred " .. F_.costs["Shred"] .. "  Claw " .. F_.costs["Claw"] .. "  Rake " .. F_.costs["Rake"]
        .. "   Tiger's Fury " .. F_.tfDur .. "s   Carnage sure at 5 CP: " .. tostring((F_.carnageRank * 0.5) >= 0.999))

    elseif cmd == "debug" then
      local form = resolveForms()
      out("|cFFFFD700FeralDPS Debug:|r")
      out(string.format(
        "  Spec=%s  Power=%d  CP=%d  Form=%d (cat=%s bear=%s)",
        F_.spec, UnitMana("player"), GetComboPoints(), form,
        tostring(F_.catIndex), tostring(F_.bearIndex)))
      out(string.format(
        "  Rip=%.1fs  Rake=%.1fs  FF=%.1fs  Demo=%.1fs  Clearcast=%s",
        getRipRemaining(), getRakeRemaining(), getFFRemaining(), getDemoRemaining(),
        tostring(isClearcasting())))
      out("  SuperWoW (UnitXP): " .. (hasSuperWoW() and "|cFF00FF00loaded|r" or "|cFFFF4444MISSING - behind check disabled, assuming behind|r"))
      do
        local ok, v = pcall(UnitXP, "behind", "player", "target")
        out("  UnitXP raw: ok=" .. tostring(ok) .. " value=" .. tostring(v)
          .. "   target=" .. tostring(UnitName("target")))
      end
      out("  Behind target: " .. tostring(isBehindTarget())
        .. "   ClawBleeds: " .. tostring(F_.clawBleeds))
      local imm = ""
      for n, t in pairs(F_.immune) do
        for sp, _ in pairs(t) do imm = imm .. n .. ":" .. sp .. "  " end
      end
      out("  Immune (learned): " .. (imm ~= "" and imm or "none"))
      out("  Target debuff bar full (raid cap): " .. tostring(debuffBarFull())
        .. "   last Rip tick " .. (F_.lastRipTickTime > 0 and string.format("%.1fs ago", GetTime() - F_.lastRipTickTime) or "never"))
      out("  Rip ticks seen: " .. F_.ripTicks .. "/" .. F_.ripTickCount
        .. "   Rake ticks seen: " .. F_.rakeTicks .. "/" .. F_.rakeTickCount)
      local ttd = getTTD()
      out("  Time to die: " .. (ttd and string.format("%.1fs", ttd) or "unknown")
        .. "   Target worth Rip: " .. tostring(targetWorthRipping(5))
        .. "   Boss: " .. tostring(isBoss()))
      out("  Maul queued: " .. tostring(isQueuedOnBar("ability_druid_maul")))
      out("  Berserk: auto=" .. tostring(F_.useBerserk)
        .. "  ready=" .. tostring(spellReady("Berserk"))
        .. "  TigersFury " .. string.format("%.1fs left (exact)", getTFRemaining()))
      local mana, cost = getShiftMana()
      out("  DruidBar mana/shift cost: "
        .. tostring(mana) .. " / " .. tostring(cost))
      do
        local mana, max = playerMana()
        out("  Reshift: " .. (F_.useReshift and "on" or "off") .. "  used " .. F_.reshiftCount .. " this session"
          .. "  sets the bar to " .. tostring(F_.reshiftGain or "?") .. "  used at or below " .. F_.reshiftEnergy .. (F_.reshiftEnergyManual and " (pinned)" or "")
          .. "  mana " .. tostring(mana) .. "/" .. tostring(max) .. "  Furor " .. F_.furorRank .. "/5"
          .. "  in book: " .. tostring(F_.book and F_.book["Reshift"] ~= nil)
          .. "  would fire now: " .. tostring(reshiftWhy(UnitMana("player")) or "yes"))
      end
      do
        local t = energyTickIn()
        out("  Energy tick: " .. (t and string.format("next in %.1fs (+%d)", t, F_.energyTickSize) or "not seen lately (bar full or out of form)")
          .. "   Relic: " .. tostring(F_.relic) .. " (Claw " .. F_.costs["Claw"] .. ", Rake " .. F_.costs["Rake"] .. " energy)")
      end
      out("  Rip ticks seen this session: " .. tostring(F_.ticksSeen or 0)
        .. "  (0 after a boss fight means the combat log is not showing bleed ticks)")
      if F_.np.live then
        local slots = npDebuffSlotsUsed()
        local ripById = npAuraOnTarget("Rip")
        out("  Nampower " .. F_.np.version .. ": visible debuff slots " .. tostring(slots) .. "/16"
          .. " (server cap 40: the 17th and up are on but invisible)"
          .. "   Rip visible (by spell id): " .. tostring(ripById)
          .. "   Rip held: " .. tostring(npBlocked("Rip")))
        out("  Nampower this session: bleed ticks " .. F_.np.ticks .. "   casts seen landing " .. F_.np.landed
          .. "   casts into a full bar " .. F_.np.capped .. " (of which ticking out of sight " .. F_.np.hidden
          .. ", held back " .. F_.np.blocked .. ")   player guid " .. tostring(F_.np.playerGuid))
      else
        out("  Nampower: |cFFFF4444not found|r - debuff cap detection off, chat log only")
      end
      out("  Spellbook: Faerie Fire (Feral)="
        .. tostring(F_.book and F_.book["Faerie Fire (Feral)"])
        .. "  Shred=" .. tostring(F_.book and F_.book["Shred"])
        .. "  Maul=" .. tostring(F_.book and F_.book["Maul"]))
      out(string.format(
        "  Relic: %s  Rip dur %.1fs (%d CP)  Rake dur %.1fs  Carnage %d/2",
        tostring(F_.relic), F_.ripDur, F_.lastRipCP, F_.rakeDur, F_.carnageRank))
      out("  Costs: Shred " .. F_.costs["Shred"]
        .. "  Claw " .. F_.costs["Claw"] .. "  Rake " .. F_.costs["Rake"]
        .. "  Maul " .. F_.costs["Maul"])
      out("  Target debuff textures:")
      for i = 1, 16 do
        local tex = UnitDebuff("target", i)
        if tex then out("    [" .. i .. "] " .. tex) end
      end
      out("  Player buff textures:")
      local b = 0
      while not (GetPlayerBuff(b) == -1) do
        local tex = GetPlayerBuffTexture(GetPlayerBuff(b))
        out("    [" .. b .. "] " .. tostring(tex))
        b = b + 1
      end

    elseif cmd == "talents" then
      out("|cFFFFD700FeralDPS|r talents:")
      for tab = 1, GetNumTalentTabs() do
        local tabName, _, spent = GetTalentTabInfo(tab)
        out("  |cFF00FFFF" .. tostring(tabName)
          .. "|r (" .. tostring(spent) .. " points)")
        for i = 1, GetNumTalents(tab) do
          local name, _, _, _, rank, maxRank = GetTalentInfo(tab, i)
          if rank and rank > 0 then
            out("    " .. name .. " " .. rank .. "/" .. maxRank)
          end
        end
      end

    elseif cmd == "help" then
      out("|cFFFFD700FeralDPS|r commands:")
      out("  |cFFFFFFFF/fdps|r        — execute current rotation")
      out("  |cFFFFFFFF/fdps cat|r    — cat DPS")
      out("  |cFFFFFFFF/fdps bear|r   — bear tanking")
      out("  |cFFFFFFFF/fdps aoe|r    — bear AoE (Swipe)")
      out("  |cFFFFFFFF/fdps farm|r   — cat farming: fast kills, no FF/Rip, early Bites")
      out("  |cFFFFFFFF/fdps rip|r    — toggle Rip upkeep")
      out("  |cFFFFFFFF/fdps rake|r   — toggle Rake upkeep")
      out("  |cFFFFFFFF/fdps ff|r     — toggle Faerie Fire (Feral)")
      out("  |cFFFFFFFF/fdps tf|r     — toggle Tiger's Fury")
      out("  |cFFFFFFFF/fdps claw|r   — Claw instead of Shred while Rake+Rip are up")
      out("  |cFFFFFFFF/fdps berserk|r— auto-Berserk (off = save it for Fear)")
      out("  |cFFFFFFFF/fdps pull|r   — allow acting on unpulled mobs mid-fight (default off)")
      out("  |cFFFFFFFF/fdps btrash|r — Berserk on cooldown instead of waiting for Rip (default off)")
      out("  |cFFFFFFFF/fdps enrage|r — bear: Enrage for rage when starved, trash only (default on)")
      out("  |cFFFFFFFF/fdps pot|r    — bosses: drink Mighty Rage Potion at the right moment (default off; shares the potion cooldown)")
      out("  |cFFFFFFFF/fdps juju|r   — bosses: use Juju Flurry whenever it is ready (default off)")
      out("  |cFFFFFFFF/fdps enrageboss|r — bear: allow Enrage on bosses too (default off)")
      out("  |cFFFFFFFF/fdps reshift|r — Reshift (OctoWoW powershift: empties the bar, sets it to 60) when nearly out of energy; energy/reserve/cost <n> to tune")
      out("  |cFFFFFFFF/fdps shift|r  — old DruidBar powershifting")
      out("  |cFFFFFFFF/fdps talents|r — print your talent ranks")
      out("  |cFFFFFFFF/fdps chat <tab>|r — send addon text to a chat tab (|cFFFFFFFF/fdps chat|r = general)")
      out("  |cFFFFFFFF/fdps trace|r  — log every press/cast/error with timestamps (|cFFFFFFFFtrace show [n]|r, |cFFFFFFFFtrace clear|r)")
      out("  |cFFFFFFFF/fdps immune|r — learned bleed immunities (|cFFFFFFFFimmune clear <name>|r forgets one)")
      out("  |cFFFFFFFF/fdps hudreset|r — put the HUD back where it started (it remembers where you drag it)")
      out("  |cFFFFFFFF/fdps show|r / |cFFFFFFFFhide|r / |cFFFFFFFFdebug|r / |cFFFFFFFFreload|r")

    else
      executeRotation()
    end
  end

  -- One bleed tick on the current target, from the chat log or from Nampower.
  local function bleedTick(spell, now)
    if spell == "Rip" then
      F_.lastRipTickTime = now
      if F_.lastRipTime == 0 then F_.lastRipTime = now; setRipDuration(5) end  -- ticking but unseen
      F_.ripTicks = F_.ripTicks + 1
      if F_.ripTicks > F_.ripTickCount then                        -- 7th tick = Carnage refresh
        F_.ripTicks = 1
        F_.carnageRefreshes = F_.carnageRefreshes + 1
      end
      F_.lastRipTime = now - F_.ripTicks * (F_.ripTick * F_.relicFactor)
      F_.ticksSeen = (F_.ticksSeen or 0) + 1
      trace("tick", "Rip tick #" .. F_.ripTicks)
    elseif spell == "Rake" then
      F_.lastRakeTickTime = now
      if F_.lastRakeTime == 0 then F_.lastRakeTime = now end
      F_.rakeTicks = F_.rakeTicks + 1
      if F_.rakeTicks > F_.rakeTickCount then F_.rakeTicks = 1 end
      F_.lastRakeTime = now - F_.rakeTicks * (F_.rakeDur / F_.rakeTickCount)
    end
  end

  -- Combat log: the only window 1.12 gives into a target's debuffs.
  --   "X suffers N damage from your Rip."   -> one tick; count them
  --   "X is afflicted by Rip."               -> (re)application, if the client prints it on refresh
  --   "Rip fades from X."                    -> gone, right now, no polling grace needed
  local timerKey = {
    ["Rip"] = "lastRipTime", ["Rake"] = "lastRakeTime",
    ["Faerie Fire (Feral)"] = "lastFFTime", ["Demoralizing Roar"] = "lastDemoTime",
  }
  local log = CreateFrame("Frame", "FeralDPSLogFrame")
  log:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE")
  log:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_DAMAGE")
  log:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_DAMAGE")
  log:RegisterEvent("CHAT_MSG_SPELL_AURA_GONE_OTHER")
  log:RegisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE")
  log:SetScript("OnEvent", function()
    local msg = arg1
    if not msg then return end
    local tname = UnitName("target")
    if not tname then return end
    local now = GetTime()

    -- "Your Rip failed. Chromaggus is immune."
    local _, _, spellI, whoI = string.find(msg, "^Your (.-) failed%. (.-) is immune%.$")
    if spellI and whoI then
      trace("log", msg)
      markImmune(whoI, spellI)
      if not LEARNABLE_IMMUNE[spellI] and whoI == tname then
        if now - F_.immuneHitTime < 3 then F_.immuneHits = F_.immuneHits + 1 else F_.immuneHits = 1 end
        F_.immuneHitTime = now
        if F_.immuneHits >= 2 then
          F_.immuneHoldUntil, F_.immuneHoldTarget = now + 4, whoI
          F_.immuneHits = 0
        end
      end
      return
    end

    -- A cast that never landed leaves no debuff, whatever the timer thinks:
    -- "Your Faerie Fire (Feral) was resisted by X." / "Your Rip was dodged by X."
    local _, _, spellM, howM, whoM = string.find(msg, "^Your (.-) was (%a+) by (.-)%.$")
    if not spellM then _, _, spellM, whoM = string.find(msg, "^Your (.-) missed (.-)%.$") end
    if spellM and whoM == tname then trace("log", msg) end
    if spellM and whoM == tname and timerKey[spellM] then
      F_[timerKey[spellM]] = 0
      if spellM == "Rip" then F_.ripTicks = 0; F_.ripAttemptVoid = true   -- a dodged Rip says nothing about immunity
      elseif spellM == "Rake" then F_.rakeTicks = 0 end
      return
    end

    -- Fade: exact expiry
    local _, _, spell, who = string.find(msg, "^(.-) fades from (.-)%.$")
    if spell and who == tname and timerKey[spell] then
      F_[timerKey[spell]] = 0
      if spell == "Rip" then F_.ripTicks = 0 elseif spell == "Rake" then F_.rakeTicks = 0 end
      return
    end

    -- Tick: count, and re-anchor the timer to the tick cadence. With Nampower
    -- the ticks arrive as SPELL_DAMAGE_EVENT_SELF instead (see below), and the
    -- chat line is ignored so a tick is not counted twice.
    local _, _, who2, spell2 = string.find(msg, "^(.-) suffers %d+ .-damage from your (.-)%.$")
    if spell2 and who2 == tname then
      if not F_.np.ticksLive then bleedTick(spell2, now) end
      return
    end

    -- Application / refresh. The message never says whose, so only trust it
    -- as a refresh when our own timer is already running on this target.
    local _, _, who3, spell3 = string.find(msg, "^(.-) is afflicted by (.-)%.$")
    if spell3 and who3 == tname and timerKey[spell3] and F_[timerKey[spell3]] > 0 then
      F_[timerKey[spell3]] = now
      if spell3 == "Rip" then F_.ripTicks = 0 elseif spell3 == "Rake" then F_.rakeTicks = 0 end
    end
  end)

  -- Nampower events (see NAMPOWER WITNESSES above). Registering an event the
  -- client does not know is harmless, so this is only gated on the function
  -- Nampower adds. From 4.5.0 on, registering is all it takes to enable the
  -- gated events; the CVars are set as well for older builds.
  if type(GetNampowerVersion) == "function" then
    local maj, min, pat = GetNampowerVersion()
    F_.np.live = true
    F_.np.version = tostring(maj) .. "." .. tostring(min) .. "." .. tostring(pat)
    for name, ids in pairs(NP_IDS) do
      for i = 1, table.getn(ids) do NP_NAME[ids[i]] = name end
    end
    pcall(SetCVar, "NP_EnableAuraCastEvents", 1)
    pcall(SetCVar, "NP_EnableSpellGoEvents", 1)

    local np = CreateFrame("Frame", "FeralDPSNampowerFrame")
    np:RegisterEvent("AURA_CAST_ON_OTHER")
    np:RegisterEvent("DEBUFF_ADDED_OTHER")
    np:RegisterEvent("DEBUFF_REMOVED_OTHER")
    np:RegisterEvent("SPELL_DAMAGE_EVENT_SELF")
    np:RegisterEvent("SPELL_MISS_SELF")
    np:RegisterEvent("SPELL_GO_SELF")
    np:RegisterEvent("SPELL_ENERGIZE_ON_SELF")
    pcall(SetCVar, "NP_EnableSpellEnergizeEvents", 1)
    np:SetScript("OnEvent", function()
      local now = GetTime()
      if event == "SPELL_ENERGIZE_ON_SELF" then
        -- arg3 spellId, arg4 power type (3 = energy), arg5 amount, arg6 periodic
        -- Everything that lands in the 1.5s after a Reshift press is its
        -- payout (Furor 40, the head enchant 20 as a second energize); the
        -- 10 from Tiger's Fury and the 5 from a bleed tick are periodic and
        -- small, and stay out.
        local w = F_.reshiftWatch
        if w and arg4 == 3 and (arg6 or 0) == 0 and (tonumber(arg5) or 0) >= 15 then
          w.exact = (w.exact or 0) + tonumber(arg5)
          trace("np", "Reshift energize +" .. tostring(arg5) .. " (spell " .. tostring(arg3) .. ")")
        end
        return
      end
      if event == "AURA_CAST_ON_OTHER" then
        -- arg1 spellId, arg2 caster, arg3 target, arg8 durationMs, arg9 cap bits (2 = debuff bar full)
        local name = NP_NAME[arg1]
        if not name then return end
        local mine = (F_.np.playerGuid == nil) or (normGuid(arg2) == F_.np.playerGuid)
        if not mine then return end
        local capped = (arg9 == 2 or arg9 == 3)
        F_.np.cast[name] = { t = now, guid = normGuid(arg3), capped = capped, landed = false }
        if capped then F_.np.capped = F_.np.capped + 1 end
        trace("np", name .. " went off on " .. (UnitName("target") or "?")
          .. string.format(" (%.1fs)", (tonumber(arg8) or 0) / 1000)
          .. (capped and "  16 VISIBLE SLOTS FULL - watching for ticks" or ""))
      elseif event == "DEBUFF_ADDED_OTHER" then
        -- arg1 guid, arg3 spellId, arg6 raw slot, arg7 state (0 = added)
        local name = NP_NAME[arg3]
        if not name or (arg7 and arg7 ~= 0) then return end
        local g = normGuid(arg1)
        local c = F_.np.cast[name]
        local timer = NP_TIMER[name]
        if c and (c.guid == nil or c.guid == g) and (now - c.t) < 3 then
          c.landed = true
          F_.np.landed = F_.np.landed + 1
          if timer and (g == targetGuid() or c.guid == nil) then
            F_[timer] = now
            if name == "Rip" then F_.ripTicks = 0 elseif name == "Rake" then F_.rakeTicks = 0 end
          end
          F_.np.block[name] = nil
          trace("np", name .. " landed (slot " .. tostring(arg6) .. ")")
        elseif timer and g == targetGuid() and F_[timer] == 0 then
          -- A Rip or Rake is only ours if we sent one in the last moments
          -- (the aura event does not say whose it is - another feral on the
          -- same training dummy restarted our Rake timer this way on 6/10).
          -- A Faerie Fire or Roar from anyone serves us all the same.
          local ours = (F_.np.goAt and F_.np.goAt[name] and (now - F_.np.goAt[name]) < 2.5)
          if ours or (name ~= "Rip" and name ~= "Rake") then
            F_[timer] = now                        -- a manual cast, or someone else's FF
            if name == "Rip" then F_.ripTicks = 0; setRipDuration(5) elseif name == "Rake" then F_.rakeTicks = 0 end
          end
        end
      elseif event == "DEBUFF_REMOVED_OTHER" then
        local name = NP_NAME[arg3]
        if not name or (arg7 and arg7 ~= 1) then return end
        local timer = NP_TIMER[name]
        if timer and normGuid(arg1) == targetGuid() and not npAuraOnTarget(name) then
          F_[timer] = 0
          if name == "Rip" then F_.ripTicks = 0 elseif name == "Rake" then F_.rakeTicks = 0 end
          trace("np", name .. " removed from the target")
        end
      elseif event == "SPELL_DAMAGE_EVENT_SELF" then
        -- arg1 target, arg3 spellId, arg4 amount, arg8 "effect1,effect2,effect3,auraType"
        local name = NP_NAME[arg3]
        if not name or (name ~= "Rip" and name ~= "Rake") then return end
        if not string.find(tostring(arg8), ",3$") and not string.find(tostring(arg8), ",89$") then return end
        F_.np.ticks = F_.np.ticks + 1
        F_.np.ticksLive = true
        local g = normGuid(arg1)
        F_.np.tickT[name .. "@" .. (g or "")] = now
        local c = F_.np.cast[name]
        if c and not c.landed and (c.guid == nil or c.guid == g) then
          c.landed = true
          if c.capped then
            F_.np.hidden = F_.np.hidden + 1
            trace("np", name .. " ticks: on the target out of sight (16 visible slots full)")
          end
        end
        if g == targetGuid() then bleedTick(name, now) end
      elseif event == "SPELL_MISS_SELF" then
        -- arg2 target, arg3 spellId, arg4 miss type (3 dodge, 7/8 immune)
        local name = NP_NAME[arg3]
        if not name then return end
        F_.np.cast[name] = nil
        local timer = NP_TIMER[name]
        if timer and normGuid(arg2) == targetGuid() then
          F_[timer] = 0
          if name == "Rip" then F_.ripTicks = 0; F_.ripAttemptVoid = true elseif name == "Rake" then F_.rakeTicks = 0 end
        end
        trace("np", name .. " missed (type " .. tostring(arg4) .. ")")
      elseif event == "SPELL_GO_SELF" then
        -- arg2 spellId, arg3 caster (that is us: remember our guid), arg6 hit, arg7 missed
        if F_.np.playerGuid == nil then F_.np.playerGuid = normGuid(arg3) end
        local name = NP_NAME[arg2]
        if name then
          F_.np.goAt = F_.np.goAt or {}
          F_.np.goAt[name] = now
          trace("np", name .. " go: hit " .. tostring(arg6) .. " missed " .. tostring(arg7))
        end
      end
    end)
  end

  -- Catch debuffs applied outside the macro (manual Rip, someone else's Faerie
  -- Fire) so the timers and the HUD do not go stale.
  local watcher = CreateFrame("Frame", "FeralDPSWatcher")
  watcher:SetScript("OnUpdate", function()
    if (this.tick or 0) > GetTime() then return end
    this.tick = GetTime() + 0.5
    local now = GetTime()
    -- Rip and Rake are per-caster bleeds: with Nampower the re-arm only
    -- accepts one we sent ourselves in the last moments (SPELL_GO_SELF), so
    -- another feral's bleed on the same target is not taken for ours.
    local function oursRecently(name)
      if not F_.np.live then return true end
      local t = F_.np.goAt and F_.np.goAt[name]
      return t and (now - t) < 2.5
    end
    if F_.lastRipTime  == 0 and debuffSeen("Rip", F_.texRip) and oursRecently("Rip") then
      F_.lastRipTime = now; F_.ripTicks = 0; setRipDuration(5)
    end
    if F_.lastRakeTime == 0 and debuffSeen("Rake", F_.texRake) and oursRecently("Rake") then F_.lastRakeTime = now end
    if F_.lastFFTime   == 0 and debuffSeen("Faerie Fire (Feral)", F_.texFF)   then F_.lastFFTime   = now end
    if F_.lastDemoTime == 0 and debuffSeen("Demoralizing Roar", F_.texDemo) then F_.lastDemoTime = now end

    -- Our casts in flight (Nampower). One that appeared, or that ticks, is on
    -- the target - out of sight when the 16 visible slots were full. A bleed
    -- that went off into a full bar and did neither within a tick interval is
    -- not there: hold it on this target, Bite instead. Faerie Fire and Roar
    -- have no ticks to prove themselves with, so they are never held.
    if F_.np.live then
      for name, c in pairs(F_.np.cast) do
        local tick = (name == "Rip" and F_.ripTick * F_.relicFactor)
                  or (name == "Rake" and F_.rakeDur / F_.rakeTickCount) or nil
        local tk = F_.np.tickT[name .. "@" .. (c.guid or "")]
        if c.landed or (tk and tk > c.t) then
          F_.np.cast[name] = nil
        elseif not c.capped or not tick then
          if (now - c.t) > 3 then F_.np.cast[name] = nil end
        elseif (now - c.t) > tick + 1.5 then
          F_.np.cast[name] = nil
          F_.np.blocked = F_.np.blocked + 1
          F_.np.block[name] = { guid = c.guid, untilT = now + RIP_BLOCK_HOLD }
          local timer = NP_TIMER[name]
          if timer and (c.guid == nil or c.guid == targetGuid()) then F_[timer] = 0 end
          local tname = UnitName("target") or "the target"
          trace("np", name .. " went off into a full debuff bar and neither appeared nor ticked in "
            .. string.format("%.1f", tick + 1.5) .. "s - not on the target, held for " .. RIP_BLOCK_HOLD .. "s")
          out("|cFFFFD700FeralDPS|r: |cFFFF8800" .. name .. "|r is not on " .. tname
            .. " - it went off into a full debuff bar and never ticked. "
            .. (name == "Rip" and "Ferocious Bite" or "No " .. name) .. " for the next " .. RIP_BLOCK_HOLD .. "s.")
          if FeralDPS.OnCastFailed then FeralDPS.OnCastFailed(name, "Debuff bar full") end
        end
      end
    end
  end)

  -- Re-read the relic slot when gear changes (idol swaps mid-fight)
  local gear = CreateFrame("Frame", "FeralDPSGearFrame")
  gear:RegisterEvent("UNIT_INVENTORY_CHANGED")
  gear:SetScript("OnEvent", function()
    if arg1 == "player" then
      readRelic()
      computeCosts()
    end
  end)

  -- Re-read talents after a respec or a new talent point, so costs and the
  -- Tiger's Fury duration follow the build without a manual /fdps reload.
  -- 1.15.15: at PLAYER_LOGIN the tree is still empty on this client, so the
  -- ranks are read again after PLAYER_ENTERING_WORLD and then once a second
  -- (for up to a minute) until something comes back. The first successful
  -- read prints the ranks it found and the costs they give.
  local talents = CreateFrame("Frame", "FeralDPSTalentFrame")
  talents:RegisterEvent("CHARACTER_POINTS_CHANGED")
  talents:RegisterEvent("PLAYER_ENTERING_WORLD")
  talents.retryUntil = 0
  talents.nextTry = 0
  local function talentsArrived()
    computeCosts()
    out("|cFFFFD700FeralDPS|r talents: " .. talentSummary()
      .. "  ->  Shred " .. F_.costs["Shred"] .. ", Claw " .. F_.costs["Claw"]
      .. ", Rake " .. F_.costs["Rake"] .. ", Tiger's Fury " .. F_.tfDur .. "s")
  end
  talents:SetScript("OnEvent", function()
    if event == "CHARACTER_POINTS_CHANGED" then
      if readTalents() then computeCosts() end
      return
    end
    -- PLAYER_ENTERING_WORLD: try now, keep trying for a while
    if readTalents() then
      talentsArrived()
      talents.retryUntil = 0
    else
      talents.retryUntil = GetTime() + 60
      talents.nextTry = GetTime() + 1
    end
  end)
  talents:SetScript("OnUpdate", function()
    if talents.retryUntil == 0 or GetTime() < talents.nextTry then return end
    talents.nextTry = GetTime() + 1
    if readTalents() then
      talentsArrived()
      talents.retryUntil = 0
    elseif GetTime() > talents.retryUntil then
      talents.retryUntil = 0
      out("|cFFFFD700FeralDPS|r: |cFFFF8800the talent tree never answered|r - costs assume no talents. Open the talent window once and type |cFFFFFFFF/fdps reload|r, or |cFFFFFFFF/fdps talents|r to see what the client reports.")
    end
  end)

  -- Re-read the spellbook when a new rank is trained
  local books = CreateFrame("Frame", "FeralDPSBookFrame")
  books:RegisterEvent("LEARNED_SPELL_IN_TAB")
  books:RegisterEvent("SPELLS_CHANGED")
  books:SetScript("OnEvent", function() buildSpellbook() end)

  -- Fight durations feed the time-to-die prior for fresh targets
  local fights = CreateFrame("Frame", "FeralDPSFightFrame")
  fights:RegisterEvent("PLAYER_REGEN_DISABLED")
  fights:RegisterEvent("PLAYER_REGEN_ENABLED")
  fights:SetScript("OnEvent", function()
    if event == "PLAYER_REGEN_DISABLED" then
      F_.fightStart = GetTime()
      F_.reshiftNoGain = 0            -- a new fight gets a fresh try
      F_.reshiftHoldUntil = 0
    elseif F_.fightStart then
      table.insert(F_.recentFights, GetTime() - F_.fightStart)
      while table.getn(F_.recentFights) > 5 do table.remove(F_.recentFights, 1) end
      F_.fightStart = nil
    end
  end)

  -- Time-to-die sampler: its own frame, so it keeps running with the HUD hidden
  local ttdFrame = CreateFrame("Frame", "FeralDPSTTDFrame")
  ttdFrame:SetScript("OnUpdate", function()
    if (this.tick or 0) > GetTime() then return end
    this.tick = GetTime() + 0.1
    sampleTTD()
    -- What a Reshift pays: the first jump of 30+ energy inside 1.5s of the
    -- press (a regen tick is 20, Furor alone 40, with the head enchant 60).
    -- Sets the energy ceiling for the next one unless it was set by hand.
    -- The first measurements (dummy, 6/10) came back as 50, 65, 35, 54, 30...
    -- for a shift that pays 60: the sample caught the Tiger's Fury pressed
    -- right after it (-30), a bleed tick (+5) or a regen tick (+20). So: the
    -- PEAK inside 0.8s minus the energy at the press, a regen tick seen in
    -- that window taken off again, and the ceiling set from the median of
    -- the last five, rounded to 5 - one wild sample moves nothing.
    local w = F_.reshiftWatch
    if w then
      local e = UnitMana("player")
      if e > w.peak then w.peak = e; w.peakAt = GetTime() end
      if GetTime() - w.t0 > 1.5 then
        F_.reshiftWatch = nil
        -- Nampower's energize events give the exact payout; the energy bar
        -- (peak minus start, a regen tick taken off) is the fallback and
        -- missed part of it on the dummy (45, 55, 70 for a 60).
        -- A Reshift empties the bar and then pays Furor (40) and the head
        -- enchant (20) into it - René's dummy numbers (45 from 15, 50 from
        -- 10, 55 from 5) were exactly 60 minus what was in the bar. So the
        -- figure kept is the LEVEL the bar is set to: the energize sum when
        -- Nampower reports it, the bar's peak otherwise. It is shown, not
        -- used for the ceiling: the ceiling is about what is thrown away.
        -- The energize events carry Furor's 40; the head enchant's 20 showed
        -- up on the bar in ZG without one, so the bar's peak wins when it is
        -- higher and no regen tick landed inside the window.
        -- 1.15.18: the energize events only ever carry Furor's 40 - the head
        -- enchant's 20 is paid without one (Chronicle and Nampower both show
        -- 40 while the bar reads 60, as René sees in game). So the bar is the
        -- truth and the energize sum only a floor. A regen tick inside the
        -- window used to throw the bar reading away (and with ticks every 2s
        -- that was three samples in four); now its size is simply taken off.
        -- 1.15.19: only a regen tick that landed BEFORE the peak was read can
        -- have inflated it; one that came after (energy already spent on TF)
        -- did not, and taking it off anyway was reading 60 as 40.
        local tickLanded = (F_.energyTickAt > w.tickAt) and (F_.energyTickAt <= (w.peakAt or w.t0))
        local fromBar = w.peak - (tickLanded and (F_.energyTickSize or 20) or 0)
        local d = w.exact or 0
        local source = "exact"
        if fromBar > d then d = fromBar; source = tickLanded and "bar, regen tick taken off" or "bar" end
        if d >= 25 then
          F_.reshiftNoGain = 0
          d = math.floor(d / 5 + 0.5) * 5
          if F_.reshiftGain ~= d then
            F_.reshiftGain = d
            saveSettings()
          end
          trace("np", "Reshift set the bar to " .. d .. " energy (" .. w.before .. " thrown away) (" .. source .. ")")
        else
          F_.reshiftNoGain = (F_.reshiftNoGain or 0) + 1
          trace("np", "Reshift paid no energy (" .. F_.reshiftNoGain .. ")")
          if F_.reshiftNoGain >= 2 then
            out("|cFFFFD700FeralDPS|r: two Reshifts in a row paid no energy - holding it. |cFFFFFFFF/fdps reshift|r twice to try again.")
          end
        end
      end
    end
  end)

  -- Clear stale timers when the target changes
  local tgt = CreateFrame("Frame", "FeralDPSTargetFrame")
  tgt:RegisterEvent("PLAYER_TARGET_CHANGED")
  tgt:SetScript("OnEvent", function()
    -- Back on the mob the debuffs were cast on, with a full (raid) debuff
    -- bar: nothing can be read, so the timers stand. Anything else: the
    -- debuff decides.
    if not npLive() and debuffBarFull() and UnitName("target") == F_.debuffTarget then return end
    if not debuffSeen("Rip", F_.texRip)  then F_.lastRipTime  = 0 end
    if not debuffSeen("Rake", F_.texRake) then F_.lastRakeTime = 0 end
    if not debuffSeen("Faerie Fire (Feral)", F_.texFF)   then F_.lastFFTime   = 0 end
    if not debuffSeen("Demoralizing Roar", F_.texDemo) then F_.lastDemoTime = 0 end
  end)

  -- Cycle the nearest enemies for one that is in the fight, not crowd
  -- controlled, not the one that just failed, and (when SuperWoW can tell)
  -- within maxDist yards. Leaves the target where it was when nothing fits.
  local function retargetInReach(far, maxDist)
    for i = 1, 8 do
      TargetNearestEnemy()
      if UnitExists("target") and not UnitIsDead("target") and UnitCanAttack("player", "target")
         and UnitAffectingCombat("target") and not targetCrowdControlled()
         and UnitName("target") ~= far then
        local ok, d = pcall(UnitXP, "distanceBetween", "player", "target")
        if not (ok and type(d) == "number") or d <= maxDist then
          return true
        end
      end
      if UnitName("target") == far then break end
    end
    if far and UnitName("target") ~= far then TargetByName(far, true) end
    return false
  end

  -- Client errors. The important one: "You must be behind your target." -
  -- UnitXP said behind, the server said no (huge hitboxes: Onyxia, Garr). The
  -- rotation then plays "in front" for 3s (Claw / Rake) instead of pressing a
  -- Shred that never lands, and every refused press frees the GCD guard at
  -- once instead of costing a full second.
  local errs = CreateFrame("Frame", "FeralDPSErrorFrame")
  errs:RegisterEvent("UI_ERROR_MESSAGE")
  errs:RegisterEvent("SPELLCAST_FAILED")
  errs:RegisterEvent("SPELLCAST_STOP")
  errs:SetScript("OnEvent", function()
    if event == "UI_ERROR_MESSAGE" then
      local msg = tostring(arg1)
      local now = GetTime()
      local since = now - F_.lastAttemptTime
      local attempt = F_.lastAttempt
      trace("error", msg .. string.format("  (%.2fs after press, attempt %s)", since, tostring(attempt)))
      if since < 0.6 and attempt then
        F_.lastError, F_.lastErrorTime = msg .. " (" .. attempt .. ")", now
        if FeralDPS.OnCastFailed then FeralDPS.OnCastFailed(attempt, msg) end
        local m = string.lower(msg)
        if string.find(m, "behind") then
          F_.frontUntil = now + 3
        end
        if F_.lastAttemptGcd then
          if string.find(m, "not ready") then
            F_.lastCastTime = now - 0.1      -- retry in 0.2s; the GCD reading holds it if needed
          else
            F_.lastCastTime = 0              -- the press did nothing: try again now
          end
        end
        -- "Out of range." in bear: the target stands back (a caster, or the
        -- other tank's mob). AoE swaps to the nearest mob in the fight - that
        -- is what Swipe and Maul can reach; single-target bear holds Swipe
        -- for a moment and lets Faerie Fire / Demoralizing Roar go instead.
        -- In cat the same swap happens only when SuperWoW can see that the
        -- target is really far off (Onyxia in the air, a mob being kited):
        -- then the whelps in reach are the job, not a Shred that never lands.
        local outOfRange = string.find(m, "range") or string.find(m, "too far")
        if outOfRange and UnitAffectingCombat("player") then
          local far = UnitName("target")
          local okD, dist = pcall(UnitXP, "distanceBetween", "player", "target")
          if not (okD and type(dist) == "number") then dist = nil end
          if F_.lastSpec == "aoe" then
            if retargetInReach(far, 8) then
              trace("target", "out of range in AoE: switched to " .. tostring(UnitName("target")))
            else
              F_.swipeHoldUntil = now + 2
            end
          elseif not isCatSpec(F_.lastSpec) then
            F_.swipeHoldUntil = now + 2
          elseif dist and dist > 12 and now > F_.retargetAt then
            F_.retargetAt = now + 2
            if retargetInReach(far, 8) then
              trace("target", string.format("%s is %.0f yd away: switched to %s", tostring(far), dist, tostring(UnitName("target"))))
            end
          end
        end
        -- a Rip/Rake/FF that never went out must not sit on the HUD as "up"
        if attempt == "Rip" then F_.lastRipTime = 0; F_.ripAttemptVoid = true   -- and says nothing about immunity
        elseif attempt == "Rake" then F_.lastRakeTime = 0
        elseif attempt == "Faerie Fire (Feral)" then F_.lastFFTime = 0
        elseif attempt == "Tiger's Fury" then F_.lastTFTime = 0
        elseif attempt == "Demoralizing Roar" then F_.lastDemoTime = 0
        elseif attempt == "Maul" then F_.lastMaulTime = 0
        elseif attempt == "Reshift" then
          -- "Not enough mana." or anything else: do not press it into the
          -- same wall every second - and a refused press paid nothing, so it
          -- must not count as a Reshift that "paid no energy" either
          F_.reshiftCount = F_.reshiftCount - 1
          F_.reshiftWatch = nil
          F_.reshiftHoldUntil = now + (string.find(m, "mana") and 20 or 5)
        end
        F_.lastAttempt = nil             -- one refusal per press
      end
    elseif event == "SPELLCAST_FAILED" then
      trace("event", "FAILED (attempt " .. tostring(F_.lastAttempt) .. ")")
    elseif event == "SPELLCAST_STOP" then
      trace("event", "STOP")
    end
  end)

  -- Energy regen ticks. UNIT_ENERGY fires on every change; a jump of exactly
  -- 20 (40 under Berserk) that is not one of our own gains is the server's
  -- regen tick, and the next one is 2.0s after it.
  local energy = CreateFrame("Frame", "FeralDPSEnergyFrame")
  energy:RegisterEvent("UNIT_ENERGY")
  energy:RegisterEvent("PLAYER_TARGET_CHANGED")
  energy:SetScript("OnEvent", function()
    if event ~= "UNIT_ENERGY" or arg1 ~= "player" then return end
    local e = UnitMana("player")
    local last = F_.lastEnergySeen
    F_.lastEnergySeen = e
    if not last then return end
    local d = e - last
    -- 1.15.19: the head enchant's +20 arrives as its own update right after
    -- Furor's +40 on a Reshift, and looked exactly like a regen tick here -
    -- which is why the bar measurement kept landing on 40 (60 minus a "tick").
    -- A +20 inside the first second after a Reshift press is the shift's own.
    if (d == 20 or d == 40) and (GetTime() - F_.lastReshiftTime) > 1.0 then
      F_.energyTickAt = GetTime()
      F_.energyTickSize = d
    end
  end)

  local loader = CreateFrame("Frame", "FeralDPSLoader")
  loader:RegisterEvent("PLAYER_LOGIN")
  loader:SetScript("OnEvent", function()
    feralInit()
    if not F_.hud.frame then
      createHUD()
    end
  end)
end
