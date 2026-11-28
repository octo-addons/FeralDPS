-- Minimal stand-in for the WoW 1.12 client (+ Nampower / UnitXP), enough to
-- run FeralDPS's rotation and event handlers. Test harness only.
local M = {}
local W = {
  t = 1000, energy = 100, cp = 0, mana = 3300, maxMana = 3300, form = 2, inCombat = true,
  gcdStart = 0, gcdDur = 0, buffs = {}, debuffs = {}, cds = {}, casts = {}, log = {}, errors = {},
  curse = false, behind = true, dist = 3, moved = 0, attackOn = false, zone = "Molten Core", raid = 40,
  items = {}, itemCd = {}, refuseItems = false, playerGuid = "0x00000000000000AA",
  targets = {}, target = nil, biteDodges = false, autoRefuse = nil, said = {},
}
M.W = W
local SPELLS = { "Shred", "Claw", "Rake", "Rip", "Ferocious Bite", "Tiger's Fury", "Faerie Fire (Feral)",
  "Reshift", "Berserk", "Ravage", "Pounce", "Maul", "Swipe", "Savage Bite", "Demoralizing Roar", "Enrage", "Cat Form" }
local COST = { Shred = 48, Claw = 40, Rake = 35, Rip = 30, ["Ferocious Bite"] = 35, ["Tiger's Fury"] = 30 }
local SPELLID = { Rip = 9896, Rake = 9904, ["Faerie Fire (Feral)"] = 17392 }
local TEX = { Rip = "Interface\\Icons\\Ability_GhoulFrenzy", Rake = "Interface\\Icons\\Ability_Druid_Disembowel",
  ["Faerie Fire (Feral)"] = "Interface\\Icons\\Spell_Nature_FaerieFire" }

local frames = {}
local function widget()
  local w = { scripts = {}, events = {} }
  return setmetatable(w, { __index = function(_, k)
    if k == "SetScript" then return function(self, ev, fn) self.scripts[ev] = fn end end
    if k == "RegisterEvent" then return function(self, ev) self.events[ev] = true end end
    if k == "CreateFontString" or k == "CreateTexture" then return function() return widget() end end
    if k == "GetText" then return function(self) return rawget(self, "text") end end
    if k == "SetText" then return function(self, s) rawset(self, "text", s) end end
    if k == "GetLeft" or k == "GetBottom" then return function() return 100 end end
    if type(k) == "string" and string.find(k, "^%u") then return function() end end   -- methods only
    return nil
  end })
end

local env = {}
M.env = env
local function fire(ev, a1, a2, a3, a4, a5, a6, a7, a8, a9)
  for _, f in ipairs(frames) do
    if f.events[ev] and f.scripts.OnEvent then
      env.event, env.this = ev, f
      env.arg1, env.arg2, env.arg3, env.arg4, env.arg5, env.arg6, env.arg7, env.arg8, env.arg9 = a1, a2, a3, a4, a5, a6, a7, a8, a9
      f.scripts.OnEvent()
    end
  end
end
M.fire = fire
local function uierr(msg) table.insert(W.errors, { t = W.t, msg = msg }); fire("UI_ERROR_MESSAGE", msg) end
M.uierr = uierr

local function tgt() return W.target and W.targets[W.target] end
local function hasBuff(name) for i, b in ipairs(W.buffs) do if b.name == name then return i end end end
local function addBuff(name, tex, dur) local i = hasBuff(name); if i then table.remove(W.buffs, i) end
  table.insert(W.buffs, { name = name, tex = tex, untilT = W.t + dur }) end
M.addBuff, M.hasBuff = addBuff, hasBuff

function M.addTarget(key, name, guid, boss)
  W.targets[key] = { name = name, guid = guid, boss = boss, hp = 1000000, maxhp = 1000000, deb = {}, rip = nil, rake = nil, visible = true }
end
function M.setTarget(key) W.target = key; fire("PLAYER_TARGET_CHANGED") end

-- ---- globals the addon uses
env.string, env.math, env.pairs, env.ipairs, env.type, env.tostring, env.tonumber = string, math, pairs, ipairs, type, tostring, tonumber
env.next, env.pcall, env.setmetatable, env.unpack = next, pcall, setmetatable, table.unpack
env.table = setmetatable({ getn = function(t) return #t end }, { __index = table })
env.BOOKTYPE_SPELL = "spell"
env.SlashCmdList = {}
env.UIParent = widget()
env.UIErrorsFrame = widget()
env.DEFAULT_CHAT_FRAME = { AddMessage = function(self, s) table.insert(W.said, s) end }
env.getglobal = function(n) if n == "FeralDPSBuffTipTextLeft1" then return M.tipText end return env[n] end
env.GetTime = function() return W.t end
env.CreateFrame = function(kind, name)
  local f = widget()
  if kind == "GameTooltip" then
    M.tipText = widget()
    rawset(f, "SetPlayerBuff", function(self, id)
      local b = (id >= 100) and W.debuffs[id - 99] or W.buffs[id + 1]
      M.tipText.text = b and b.name or nil
    end)
  end
  table.insert(frames, f)
  if name then env[name] = f end
  return f
end
env.GetChatWindowInfo = function() return nil end
env.GetPlayerBuff = function(i, filter)
  if filter == "HARMFUL" then return W.debuffs[i + 1] and (i + 100) or -1 end
  return W.buffs[i + 1] and i or -1
end
env.GetPlayerBuffTexture = function(id) local b = W.buffs[id + 1]; return b and b.tex end
env.GetPlayerBuffTimeLeft = function(id) local b = W.buffs[id + 1]; return b and (b.untilT - W.t) or 0 end
env.CancelPlayerBuff = function(id) table.remove(W.buffs, id + 1) end
env.UnitExists = function(u) if u == "player" then return true, W.playerGuid end
  local x = tgt(); if x then return true, x.guid end return nil end
env.UnitName = function(u) if u == "player" then return "Quintis" end local x = tgt(); return x and x.name end
env.UnitIsDead = function() return false end
env.UnitCanAttack = function() return true end
env.UnitAffectingCombat = function(u) return W.inCombat end
env.UnitClassification = function() local x = tgt(); return x and (x.boss and "worldboss" or "elite") end
env.UnitLevel = function() local x = tgt(); return x and (x.boss and -1 or 62) or 0 end
env.UnitHealth = function() local x = tgt(); return x and x.hp end
env.UnitHealthMax = function() local x = tgt(); return x and x.maxhp end
env.UnitMana = function() return W.energy end
env.GetComboPoints = function() return W.cp end
env.UnitDebuff = function(u, i) local x = tgt(); if not x then return nil end
  local list = {}
  for _, d in ipairs(x.deb) do if d.visible ~= false then table.insert(list, d.tex) end end
  for k = 1, (x.filler or 0) do table.insert(list, "Interface\\Icons\\Filler") end
  return list[i] end
env.GetNumShapeshiftForms = function() return 2 end
env.GetShapeshiftFormInfo = function(i) if i == 1 then return nil, "Dire Bear Form", W.form == 1 end return nil, "Cat Form", W.form == 2 end
env.CastShapeshiftForm = function(i) W.form = i end
env.IsAttackAction = function(i) return (i == 1) and 1 or nil end
env.IsCurrentAction = function(i) return W.attackOn and 1 or nil end
env.UseAction = function() W.attackOn = true end
env.AttackTarget = function() W.attackOn = true end
env.GetActionTexture = function() return nil end
env.GetSpellName = function(i) return SPELLS[i] end
env.GetSpellCooldown = function(idx)
  local name = SPELLS[idx]
  local cd = W.cds[name]
  if cd and cd.start + cd.dur > W.t then return cd.start, cd.dur end
  -- W.hideBiteGcd: the client shows no cooldown after a Bite although the GCD runs (seen in game)
  if W.hideBiteGcd and W.gcdSpell == "Ferocious Bite" then return 0, 0 end
  if W.gcdStart + W.gcdDur > W.t then return W.gcdStart, W.gcdDur end
  return 0, 0
end
env.GetNumRaidMembers = function() return W.raid end
env.GetRealZoneText = function() return W.zone end
env.TargetNearestEnemy = function() end
env.ClearTarget = function() W.target = nil end
env.TargetByName = function() end
env.GetNumTalentTabs = function() return 1 end
env.GetNumTalents = function() return 6 end
local TAL = { { "Ferocity", 0 }, { "Improved Shred", 2 }, { "Natural Shapeshifter", 2 }, { "Blood Frenzy", 2 }, { "Carnage", 2 }, { "Furor", 5 } }
env.GetTalentInfo = function(tab, i) return TAL[i][1], nil, nil, nil, TAL[i][2], 5 end
env.GetTalentTabInfo = function() return "Feral Combat", nil, 31 end
env.GetInventorySlotInfo = function(n) return n end
env.GetInventoryItemLink = function(u, slot) if slot == "RangedSlot" then return "|Hitem:1:0|h[Idol of Savagery]|h" end return nil end
env.GetInventoryItemCooldown = function() return 0, 0, 1 end
env.UseInventoryItem = function() end
env.GetContainerNumSlots = function(bag) return (bag == 0) and 4 or 0 end
env.GetContainerItemLink = function(bag, slot) local it = W.items[slot]; return it and ("|Hitem:" .. it.id .. ":0:0:0|h[" .. it.name .. "]|h") end
env.GetContainerItemInfo = function() return nil, 1, nil end
env.GetContainerItemCooldown = function(bag, slot) local it = W.items[slot]; local cd = it and W.itemCd[it.id]
  if cd and cd.start + cd.dur > W.t then return cd.start, cd.dur, 1 end return 0, 0, 1 end
env.UseContainerItem = function(bag, slot)
  local it = W.items[slot]; if not it then return end
  table.insert(W.casts, { t = W.t, spell = "ITEM " .. it.name })
  if W.refuseItems then uierr("Item is not ready yet.") return end
  W.itemCd[it.id] = { start = W.t, dur = it.cd }
end
env.SpellIsTargeting = function() return false end
env.SpellTargetUnit = function() end
env.CursorHasItem = function() return false end
env.PickupContainerItem, env.EquipCursorItem, env.ClearCursor = function() end, function() end, function() end
env.SetCVar = function() end
env.GetNampowerVersion = function() return 4, 5, 0 end
env.GetSpellIdForName = function(n) return SPELLID[n] end
env.GetUnitField = function(u, field)
  if u == "player" then if field == "power1" then return W.mana end if field == "maxPower1" then return W.maxMana end return nil end
  if field == "aura" then
    local x = tgt(); local a = {}
    if x then local n = 32
      for _, d in ipairs(x.deb) do if d.visible ~= false then n = n + 1; a[n] = d.id end end
      for k = 1, (x.filler or 0) do n = n + 1; a[n] = 12345 end
    end
    return a
  end
end
env.UnitXP = function(what) if what == "behind" then return W.behind end if what == "distanceBetween" then return W.dist end end
env.MoveForwardStart = function() W.moving = true; W.moved = W.moved + 1 end
env.MoveForwardStop = function() W.moving = false end

-- ---- the "server"
local function debuffOn(x, name) for i, d in ipairs(x.deb) do if d.name == name and d.mine then return i, d end end end
local function applyBleed(x, name, dur, tick)
  local i = debuffOn(x, name); if i then table.remove(x.deb, i) end
  local hidden = (x.filler or 0) >= 16
  table.insert(x.deb, { name = name, tex = TEX[name], id = SPELLID[name], mine = true, visible = not hidden, untilT = W.t + dur, nextTick = W.t + tick, tick = tick })
  fire("SPELL_GO_SELF", nil, SPELLID[name], W.playerGuid, nil, nil, 1, 0)
  fire("AURA_CAST_ON_OTHER", SPELLID[name], W.playerGuid, x.guid, nil, nil, nil, nil, dur * 1000, hidden and 2 or 0)
  if not hidden then fire("DEBUFF_ADDED_OTHER", x.guid, nil, SPELLID[name], nil, nil, 1, 0) end
end
local function spend(n) local e = W.energy; W.energy = W.energy - n; fire("UNIT_ENERGY", "player") end
local function castByName(name)
  local x = tgt()
  local k = W.curse and 2 or 1
  local cc = hasBuff("Clearcasting")
  table.insert(W.casts, { t = W.t, spell = name, energy = W.energy, cp = W.cp, cc = cc and true or false })
  if name ~= "Reshift" and name ~= "Tiger's Fury" and name ~= "Berserk" and W.gcdStart + W.gcdDur > W.t + 0.001 then uierr("Ability is not ready yet.") return end
  if name == "Reshift" then
    if W.gcdStart + W.gcdDur > W.t + 0.001 then W.wastedReshift = (W.wastedReshift or 0) + 1 return end   -- into the GCD: nothing happens, no error
    if W.mana < 348 * k then uierr("Not enough mana") return end
    W.mana = W.mana - 348 * k; W.energy = 0; fire("UNIT_ENERGY", "player"); W.energy = 60; fire("UNIT_ENERGY", "player")
    local i = hasBuff("Tiger's Fury"); if i then table.remove(W.buffs, i) end
    W.gcdStart, W.gcdDur, W.gcdSpell = W.t, 1.5, "Reshift"
    return
  end
  local cost = (COST[name] or 0) * k
  if name == "Tiger's Fury" then
    if W.energy < cost then uierr("Not enough energy") return end
    spend(cost); addBuff("Tiger's Fury", "Interface\\Icons\\Ability_Mount_JungleTiger", 18); return
  end
  if name == "Berserk" then W.cds.Berserk = { start = W.t, dur = 300 } return end
  if W.dist > 5 and name ~= "Faerie Fire (Feral)" then uierr("Out of range.") return end
  local free = cc and cost > 0
  if not free and W.energy < cost then uierr("Not enough energy") return end
  if (name == "Rip" or name == "Ferocious Bite") and W.cp < 1 then uierr("That ability requires combo points") return end
  if free then table.remove(W.buffs, cc) else spend(cost) end
  W.gcdStart, W.gcdDur, W.gcdSpell = W.t, 1.0, name
  if name == "Shred" or name == "Claw" then W.cp = math.min(5, W.cp + 1)
  elseif name == "Rake" then W.cp = math.min(5, W.cp + 1); applyBleed(x, "Rake", 8.1, 2.7)
  elseif name == "Rip" then local d = ({ 10, 12, 14, 16, 18 })[W.cp] * 0.9; W.cp = 0; applyBleed(x, "Rip", d, 1.8)
  elseif name == "Ferocious Bite" then
    local cp = W.cp; W.cp = 0; W.energy = 0; fire("UNIT_ENERGY", "player")
    if W.biteDodges then fire("CHAT_MSG_SPELL_SELF_DAMAGE", "Your Ferocious Bite was dodged by " .. x.name .. ".") return end
    if cp >= 5 then                                           -- Carnage 2/2
      local _, r = debuffOn(x, "Rip"); if r then r.untilT = W.t + 16.2 end
      local _, k2 = debuffOn(x, "Rake"); if k2 then k2.untilT = W.t + 8.1 end
    end
  elseif name == "Faerie Fire (Feral)" then
    W.cds["Faerie Fire (Feral)"] = { start = W.t, dur = 6 }
    table.insert(x.deb, { name = name, tex = TEX[name], id = SPELLID[name], untilT = W.t + 40, visible = (x.filler or 0) < 16 })
  end
end
env.CastSpell = function(idx) castByName(SPELLS[idx]) end
env.CastSpellByName = function(n) castByName(n) end

M.nextRegen = W.t + 2
function M.step(dt)
  W.t = W.t + dt
  if W.t >= M.nextRegen then
    M.nextRegen = M.nextRegen + 2
    if W.energy < 100 then W.energy = math.min(100, W.energy + 20); fire("UNIT_ENERGY", "player") end
  end
  for i = #W.buffs, 1, -1 do if W.buffs[i].untilT <= W.t then table.remove(W.buffs, i) end end
  if hasBuff("Tiger's Fury") and W.t >= (M.nextTF or 0) then                       -- Tiger's Fury: energy over time
    M.nextTF = W.t + 3
    if W.energy < 100 then W.energy = math.min(100, W.energy + 10); fire("UNIT_ENERGY", "player") end
  end
  for key, x in pairs(W.targets) do
    for i = #x.deb, 1, -1 do
      local d = x.deb[i]
      if d.mine and d.nextTick and d.nextTick <= W.t and d.untilT >= d.nextTick - 0.01 then
        d.nextTick = d.nextTick + d.tick
        fire("SPELL_DAMAGE_EVENT_SELF", x.guid, nil, d.id, 300, nil, nil, nil, "0,0,0,3")
        if W.energy < 100 then W.energy = math.min(100, W.energy + 5); fire("UNIT_ENERGY", "player") end   -- Ancient Brutality
      end
      if d.untilT <= W.t then
        table.remove(x.deb, i)
        if d.visible ~= false then fire("DEBUFF_REMOVED_OTHER", x.guid, nil, d.id, nil, nil, 1, 1) end
      end
    end
  end
  for _, f in ipairs(frames) do
    if f.scripts.OnUpdate then env.this = f; f.scripts.OnUpdate() end
  end
end
function M.press(cmd) env.SlashCmdList["FDPS"](cmd or "cat") end
function M.count(spell, t0)
  local n = 0
  for _, c in ipairs(W.casts) do if c.spell == spell and (not t0 or c.t >= t0) then n = n + 1 end end
  return n
end
function M.upvalue(fn, name)
  local i = 1
  while true do local n, v = debug.getupvalue(fn, i); if not n then return nil end; if n == name then return v end; i = i + 1 end
end
return M
