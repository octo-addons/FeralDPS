# Working on FeralDPS

Read this before changing anything. It exists because a version was once built on an old copy of the file and silently dropped three finished changes.

## Rule 1: always start from the file on disk

- The installed addon is the source of truth: `%LOCALAPPDATA%\OctoWoW\Interface\AddOns\FeralDPS\FeralDPS.lua` (and `...\AddOns\FeralTrack\`).
- **Read that file at the start of every session, every time.** Never edit from a copy kept in a chat, in memory or in an earlier download - other sessions change the file in between.
- Before editing, check the `## Version:` line in `FeralDPS.toc` and the last entry under *History* below. If the version on disk is newer than the one you remember, your copy is stale.
- Make changes as edits to the current file, never by writing a whole file from an older base.
- After a change: write the same files to the AddOns folder **and** to this repo (`FeralDPS\` and `FeralTrack\` subfolders - never the repo root), bump the version in the `.toc`, add a line to *History*, update `README.md`.

What went wrong on 4 Nov 2026: 1.15.30/1.15.31 (Carnage only on landed Bites, `/fdps step`, README install/troubleshooting) were on disk and in git. The Cenarion Harness change was then made from a 1.15.29 copy and saved over them. Nobody noticed for three weeks; the features came back in 1.16.10.

## Rule 2: the Lua 5.0 limits

The 1.12 client runs Lua 5.0:

- No `#t` (use `table.getn`), no `%` operator (use `math.mod` or floor arithmetic), no `string.match` / `string.gmatch` (use `string.find` / `string.gfind`), no `select`, no `...` outside vararg functions.
- A function can reach at most 60 upvalues, counting those used by its inner functions. `FeralDPS_OnLoad` is at 42. 1.16.8 reached 61 and the whole file stopped loading. New helpers used inside `FeralDPS_OnLoad` go through the `X` table (one upvalue for all of them); new slash commands go in the small dispatcher in front of `mainSlash`.
- Event handlers use the globals `event`, `arg1`..`arg9` and `this`.
- Nampower's functions must not be called through `pcall` (type-check them instead).

## Rule 3: what must not be undone

Each of these fixed a problem that was measured in the raid logs. Keep them when changing nearby code.

| Since | Behaviour | Where |
|---|---|---|
| 1.16.10 | A 5-CP Bite resets the Rip/Rake timers only if it lands; a dodged, parried, missed or refused Bite restores them (`F_.biteUndo`, `undoCarnage`) | `castAndTrack`, combat-log handler, error handler |
| 1.16.10 | Carnage is counted when a Rip tick arrives after the Rip's own end (`F_.ripNaturalEnd`, `carnagePendingN`). The old "tick number past the tick count" could never count | `bleedTick` |
| 1.16.10 | Our Rip/Rake timers are stored per target GUID and restored on target change (`F_.byGuid`). A target we have no bleed on starts at zero even when another feral's Rip is on it | `PLAYER_TARGET_CHANGED` handler |
| 1.16.10 | Red error text is only a refused press when it can be: looting text is ignored, text after an item press belongs to the item, self-casts (Reshift, Tiger's Fury, Berserk, Enrage) are not refused by range/facing text | `UI_ERROR_MESSAGE` handler |
| 1.16.10 | Potion / juju are confirmed by their cooldown before they are announced or counted; a refused one is held 20 s (`F_.itemPending`, `F_.itemHold`) | `tryBossConsumables` |
| 1.16.10 | Lucifron's Curse doubles the cost table and holds Reshift (`COST_CURSES`, `curseFactor`, `F_.costFactor`) | `computeCosts`, `refreshCostFactor`, `reshiftWhy` |
| 1.16.10 | `/fdps farm` on a ?? boss plays the cat rotation | `executeRotation`, `pickSpell` |
| 1.16.10 | Clearcasting from behind goes to Shred before Bite/Rake (not when Rip is missing or has 3 s or less at 5 CP) | `nextSpell_Cat` |
| 1.16.13 | Reshift waits 0.95 s after our own last GCD ability (`F_.gcdPressAt`, cleared when that press is refused) - the client's GCD reading can be empty right after a Bite that kills | `tryReshift`, `executeRotation`, error handler |
| 1.16.12 | Tiger's Fury waits when a Bite is ready: for the Reshift that follows the Bite if one can, otherwise only when it would take the Bite's energy; six seconds at most (`F_.tfWaitSince`) | `wantTigersFury` |
| 1.16.12 | The trace folds a run of the same refusal into one line and takes the refused press's decide/cast lines back out; waits fold by kind, not by exact text | `trace` |
| 1.16.11 | **The addon never moves the character.** `/fdps step` was removed: the OctoWoW client blocks `MoveForwardStart()` from addons ("FeralDPS has been blocked from an action only available to the Blizzard UI"). Do not add movement, in any form | - |
| 1.16.9 | `X` table to stay under the upvalue limit | above `FeralDPS_OnLoad` |
| 1.16.7 | Tiger's Fury and boss items held on a full buff bar (32) | `wantTigersFury`, `tryBossConsumables` |
| 1.16.1 | Shred from behind, not Claw, with both bleeds up (`/fdps claw` is off by default) | `nextSpell_Cat` |

Left alone on purpose: the "spend-down" builder before a Bite prices the builder as Claw although it is usually a Shred now. The logs show no measurable loss, and raising the threshold would switch the rule off.

## How changes are checked

There is no way to run the client from here, so every version is checked like this before it is handed over, and then confirmed in game:

1. `python tests/run.py FeralDPS/FeralDPS.lua` (needs `pip install lupa`). It checks the syntax and runs the addon against a scripted stand-in for the client (`tests/mock.lua`): a cat on a raid boss with Nampower events, target swaps, dodged Bites, refused items, the curse, every spec and every slash command, with and without Nampower/UnitXP. Everything must say PASS. Run the previous version with `old` as a second argument to see which cases a change is about - 1.16.9 fails nine of them.
2. A change adds a scenario to `tests/run.lua` for what it fixes.
3. Scan the new code for constructs Lua 5.0 does not have, and count upvalues (Rule 2). The stand-in runs on a newer Lua, so it does not catch either.
4. In game: `/fdps trace` on a dummy, then the next raid's FeralTrack and Chronicle logs.

The stand-in is a model of the game, not the game. A pass is necessary, not sufficient.

Open after 1.16.13: why the client shows no global cooldown after some Bites is not known (seen once, after a Bite that killed the target with a second mob in combat). Also: none of the 1.16.10 changes has been through a raid yet. Mighty Rage Potion is refused on Vaelastrasz for a reason that is not known. If Lucifron's Curse has another name on OctoWoW, change the one entry in `COST_CURSES`.

## History

- 1.16.13 (28 Nov 2026) - Reshift is no longer pressed into the GCD of the ability before it (traced: 0.3s after a killing Bite the client showed no cooldown; the press did nothing and locked Reshift for 1.5s). Trace: "cannot afford" decisions fold per energy level.
- 1.16.12 (28 Nov 2026) - Tiger's Fury no longer goes out in front of a ready Bite (traced on Winterspring cats: 25 energy for three seconds of buff, Bite 1.5s late); the trace keeps minutes instead of 20 seconds when a key is held out of range.
- 1.16.11 (28 Nov 2026) - `/fdps step` removed: the client blocks addons from moving the character (popup on the first step). Everything else from 1.16.10 stays.
- 1.16.10 (28 Nov 2026) - restores what 1.15.30/31 had (Carnage on landed Bites, Carnage counter, `/fdps step`, README install + troubleshooting); potion/juju confirmed by cooldown; error text no longer blamed on the wrong ability; Lucifron's Curse; farm on a boss plays cat; Clearcasting to Shred; bleeds per target. FeralTrack 1.7.6: "Not enough mana" is its own reason, up to 12 different unknown messages kept.
- 1.16.9 - fix load failure (upvalue limit)
- 1.16.8 - `/fdps trim`
- 1.16.7 - buff cap
- 1.16.6 - built-in bleed-immune list
- 1.16.5 - on-use trinkets
- 1.16.1 - 1.16.4 - Shred default, three idols, HUD hide remembered, idol status
- 1.15.30 (second one) / 1.16.0 - Cenarion Harness 5-set (built on a stale copy, see Rule 1)
