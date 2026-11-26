# FeralDPS

One-button feral druid rotation for **OctoWoW** (WoW 1.12 client), plus **FeralTrack**, a companion that measures how the rotation actually performed.

Every press of the key does exactly one thing - the next ability in the priority list - so it is a rotation helper, not automation. You still decide when to press, where to stand and when to stop.

## Install

Copy `FeralDPS` and `FeralTrack` into `Interface\AddOns\` (the repo root is laid out so you can also clone it straight on top of the AddOns folder). Restart the client once; afterwards `/reload` is enough for updates.

Put the rotation on a key:

```
#showtooltip Shred
/fdps cat
```

Bear (`/fdps bear`) and bear AoE (`/fdps aoe`) go on their own keys. `/fdps farm` is cat for short fights (no Faerie Fire, no Rip, early Bites).

## What the cat rotation does

Priority, first match fires: Ravage/Pounce from Prowl, Faerie Fire (Feral) when missing, Tiger's Fury when down, Berserk on a boss with Rip up and the bar empty, then at 5 combo points Rip when none is on the target - otherwise Ferocious Bite - then Rake if it is down, then Shred from behind and Claw when fronting. `/fdps claw` switches the builder to Claw while both bleeds are up; it is off by default, because Shred lands 25-30% harder in the raid logs even with both bleeds on the target.

The OctoWoW-specific parts, all read from the talent tree at login:

- **Carnage 2/2** - a 5-point Bite refreshes Rip and Rake for certain, so Rip is cast once and kept alive by Bites. The two Rip/Rake timers are reset on every 5-point Bite.
- **Reshift** (OctoWoW's one-press powershift) refills the energy bar when it runs dry. It is only pressed when it is worth at least 20 energy net: what it pays (measured from the bar on the first use - Furor's 40 plus a head enchant, if any) minus what is in the bar minus a Tiger's Fury recast if TF has more than 3 s left. Never without the mana for it, and mana is held back on raid trash. With Judgement of Wisdom (or Moonfang) feeding 300+ mana per 15 s, the mana reserve drops to a single shift's worth, since the next one is already paid for.
- **Tiger's Fury** has no global cooldown on this server and is fired outside the GCD guard, so it goes out the moment it is wanted - including right after a Reshift.
- **Cenarion Harness** - the pieces on are counted by name; with 5 the Tiger's Fury cost is 25, which the energy check and the Reshift net rule both use.
- **Rip duration** by combo points (10/12/14/16/18 s), the Idol of Savagery factor, Idol of Ferocity costs and Improved Shred / Ferocity costs are all resolved from the tree and the ranged slot.
- **Bleed-immune targets** are learned from the combat log's "immune" line and remembered across sessions; Rip and Rake are skipped on them. A built-in list of immunities confirmed on OctoWoW (Ragnaros, Baron Geddon, the MC elementals, Karazhan ghosts...) is added once on install, and `/fdps immune add <name>` adds one by hand.
- **Debuff cap** - with Nampower, bleed ticks are read from the server log, so Rip and Rake are tracked even when the 16 visible debuff slots are full (OctoWoW allows 40).
- **Buff cap** - a player holds 32 buffs, and a fully buffed raid cat sits at 30-32. On a full bar Tiger's Fury is cast and paid for but never lands, so it is held instead (and so are Mighty Rage, Juju Flurry and on-use trinkets in cat, whose buffs would not land either). A Tiger's Fury that is cast twice without the buff showing up is held for 10 s even when the count looks fine. `/fdps trim` removes Spirit and Sanctuary automatically in Cat Form (Wisdom and Intellect stay: they pay for Reshifts). Once a minute in combat the chat names the buffs a cat can right-click off (tracking, Prayer of Spirit, Blessing of Light/Sanctuary, Health II, rum, cosmetic glyph...). The HUD shows the count at the top: yellow at 29-30, orange at 31, flashing at 32/32, with "BUFF BAR FULL - NO TIGER'S FURY" when it is blocking TF.
- **Vaelastrasz** - while Essence of the Red is up (20 energy a second for the whole fight) Reshift and Berserk are skipped: the energy is free, the GCD and the 5-minute cooldown are not.
- **Dungeon bosses** - an elite with 25 000+ health counts as a boss outside raids (Berserk, Reshift mana). In raid zones only "??" counts.
- **Idol swap** (`/fdps idol`, off by default) - the relic slot can be changed in combat without a global cooldown, so the press that finds the wrong idol on equips the right one from the bags and still fires its ability: Idol of Savagery on bosses, Idol of Ferocity on trash and in `/fdps farm`, Idol of the Moonfang (mana per Shred) on bleed-immune targets. Once a boss has been the target, its adds keep the boss idol for the rest of the fight, and an idol that is not in the bags falls back to the next in line. Never from a timer or an event - only on a key press, like an `/equip` + `/cast` macro.

## Commands

`/fdps` runs the current spec. `/fdps cat | bear | aoe | farm` switches spec and runs it.

| Command | What it toggles / does |
|---|---|
| `/fdps rip`, `rake`, `ff`, `tf` | Rip upkeep, Rake upkeep, Faerie Fire, Tiger's Fury |
| `/fdps claw` | Claw instead of Shred while Rip and Rake are both up (off by default) |
| `/fdps berserk` | Auto-Berserk on bosses (`/fdps btrash` for trash too) |
| `/fdps pot`, `/fdps juju` | Mighty Rage Potion / Juju Flurry on bosses, off the GCD |
| `/fdps immune` | Lists bleed-immune mobs (learned from the combat log, plus a built-in list of confirmed Octo immunities: Ragnaros, Baron Geddon...). `immune add <name>` (or target + `immune add`), `immune clear <name>`/`all`, `immune known` |
| `/fdps trinket` | On-use trinkets (Zandalarian Hero Medallion, Molten Emberstone, ...) on bosses together with Tiger's Fury, off the GCD (default on) |
| `/fdps buffs` | How many buffs are on you out of the 32 that fit, every buff by name, the ones a cat can drop in orange |
| `/fdps trim` | Removes Prayer of Spirit / Divine Spirit and (Greater) Blessing of Sanctuary while in Cat Form, like LazyPig's Salvation remover (off by default). `trim add <buff>`, `trim remove <buff>`, `trim reset` |
| `/fdps reshift` | Reshift on/off; `reshift energy <n>`, `reserve <mana>`, `cost <mana>`, `net <energy>`, `farm <mana%>`, `farmnet <energy>`, `income <mana>` |
| `/fdps bosshp [n]` | What the current target is judged as; sets the dungeon-boss health threshold |
| `/fdps idol` | Idol swap on the press (off by default) and the three idols it uses; `idol boss <name>`, `idol trash <name>`, `idol immune <name>` pick them |
| `/fdps enrage`, `enrageboss` | Bear: Enrage when rage-starved on trash / also on bosses |
| `/fdps pull` | Allow acting on unpulled mobs while in combat (chain-pulling in bear) |
| `/fdps chat <tab>` | Route all output (FeralTrack too) to a chat tab |
| `/fdps talents` | What the client reports for the talent tree and the costs derived from it |
| `/fdps trace` | Log every press, decision, cast and client error (`/fdps trace show`, `clear`) |
| `/fdps show`, `hide`, `hudreset` | The HUD (hide is remembered across logins) |
| `/fdps debug`, `reload`, `help` | |

## FeralTrack

Loads next to FeralDPS and records a **run** - one fight, a whole dungeon or raid (it starts when you zone in and reports when you leave), or anything between `/ftrack start <label>` and `/ftrack stop`.

Per run and per fight: uptime of Rip, Rake, Tiger's Fury and Faerie Fire as a share of cat time; leaks (TF gaps, Rip gaps, seconds capped at 100 energy, idle time, time spent fronting); damage and DPS from the combat log; casts per ability and how often the rotation wanted something it could not afford; misses, dodges and parries; Clearcasting procs and how many were spent; Berserk timings; Reshift count.

`/ftrack` reports the last run, `/ftrack fights [label]` lists every fight, `/ftrack compare A B` puts two runs side by side, `/ftrack list` shows the saved runs. `/ftrack instance`, `auto`, `warn`, `rate`, `min <sec>` and `clear` configure it.

## Requirements

- OctoWoW client (1.12). Written for its Lua 5.0 and its custom spells (Reshift, Berserk, Carnage, Open Wounds, Ancient Brutality, Blood Frenzy).
- **Nampower** (optional, strongly recommended): debuffs by spell id, bleed ticks, energize events and mana while shifted. Without it the addon falls back to the chat combat log and cannot read mana in cat form, so Reshift stays off.
- **UnitXP (SuperWoW)** (optional): behind-target detection, which decides Shred vs Claw. Without it the rotation assumes you are behind.

## Versions

The version in `FeralDPS.toc` is what the addon reports in chat; releases are tagged with it (`v1.16.9`).

The 1.12 client runs Lua 5.0, where one function can reach at most 60 upvalues (file-level locals it or its inner functions use). `FeralDPS_OnLoad` holds every event handler and the slash commands, so it is the one that fills up: 1.16.8 reached 61 and did not load at all. Helpers that are only used in there go through the `X` table (one upvalue for all of them). Before a release, compile the file with a Lua 5.0 `luac -p` or `loadfile`; a newer Lua does not catch this.
