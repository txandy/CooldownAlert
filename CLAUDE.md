# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single-file World of Warcraft (retail, Midnight / 11.2+) addon written in Lua. It plays a sound when the player presses an action key whose ability is on real cooldown, unusable (no mana/stance/etc.), or optionally out of range. There is no build system, no test framework, and no dependencies — the game client loads the files listed in `CooldownAlert.toc`.

## Running / testing

This addon runs inside the WoW client. There is nothing to build. To test a change:

1. Edit `CooldownAlert.lua`.
2. In-game, run `/reload` (or log out/in).
3. Use `/cda` for the command list, `/cda scan` and `/cda capture` for the two built-in diagnostic commands that print binding → button → slot resolution for the player's keys.

The `## Interface:` version in `CooldownAlert.toc` must match the current WoW client TOC number, otherwise the client marks the addon out of date.

## Architecture

The whole addon lives in `CooldownAlert.lua`. The non-obvious pieces:

**Key → action slot resolution** (`GetActionSlotForKey` → `ComputeSlotFromButton`). WoW gives us the binding name (e.g. `MULTIACTIONBAR1BUTTON3`), but not the slot number. The mapping is done in two tiers:

1. If the button frame has a numeric `action` attribute set (pure Blizzard bars), use it directly.
2. Otherwise compute `(page - 1) * 12 + buttonID`, where `page` is a fixed per-bar constant (`BUTTON_PREFIX_PAGE`) for `MultiBar*`, or the dynamic `MainMenuBar:GetAttribute("actionpage")` / `GetActionBarPage()` for the primary `ActionButton1..12`. The fixed-page fallback exists specifically so bars that dispatch natively without setting the attribute (e.g. **EllesmereUI**) still resolve correctly.

**GCD filtering** (`IsGCD`). A slot's cooldown frequently reflects the global cooldown, which we must ignore. We compare the slot's `(start, duration)` against the GCD spell's (`GCD_SPELL_ID = 61304`) cooldown; if the GCD lookup fails, anything ≤ 1.5s is treated as GCD.

**"Secret numbers" tolerance.** In Midnight (11.2+), several action APIs return opaque values in combat that throw when compared. Every check inside `GetAlertReason` and `/cda scan` is wrapped in `pcall`, and we prefer resolving the slot to a concrete `spellID`/`itemID` and calling `C_Spell.GetSpellCooldown` / `C_Item.GetItemCooldown` (which return plain numbers) over `GetActionCooldown`. When touching action-state code, keep this pattern — direct arithmetic on raw action API returns will crash mid-combat.

**Keyboard capture.** A full-screen `Frame` with `EnableKeyboard(true)` + `SetPropagateKeyboardInput(true)` observes every key without consuming it. Pure modifier presses are filtered via `MODIFIER_KEYS`. Anti-spam is a single `lastAlert` timestamp gated by `cfg("alertCooldown")`.

**Config.** `CooldownAlertDB` is the SavedVariable (declared in the TOC). `DEFAULTS` is the source of truth; `cfg(key)` lazily back-fills missing keys and `PLAYER_LOGIN` does a full reconciliation pass. When adding a new config option, update `DEFAULTS`, wire it through `cfg()`, and expose a toggle in `SlashCmdList["COOLDOWNALERT"]` (use the existing `toggleFlag` helper).

**UI.** `BuildUI` is lazy and idempotent — the frame is created once and stored in `uiFrame`. Sound presets live in the `SOUND_PRESETS` table at the top of the UI section; each row has a preview (▶) and Use button.
