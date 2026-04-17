# CooldownAlert

> Languages: **English** · [Español](README.es.md)

A **World of Warcraft (Midnight / 11.2+)** addon that plays a sound when you press an action key that is:

- On **real cooldown** (GCD is ignored).
- **Not usable** (not enough mana/rage/runes, wrong stance, etc).
- Optionally, **out of range**.

Designed to break the habit of mashing a key while the ability is still on cooldown. No visual alert — just a configurable sound, tweakable from a small UI.

## Features

- Reliable detection via `C_Spell.GetSpellCooldown` / `C_Item.GetItemCooldown` (plain values, tolerant to Midnight's _secret numbers_ during combat).
- Supports **EllesmereUI** (and any action bar using *native dispatch*) by computing the slot as `(actionpage - 1) × 12 + buttonID`.
- Covers the 8 main bars (`ACTIONBUTTON1-12`, `MULTIACTIONBAR1-7 BUTTON1-12`).
- Respects modifier prefixes: `SHIFT-`, `CTRL-`, `ALT-` and combinations.
- Configurable anti-spam cooldown between alerts.
- UI with sound presets plus a manual input for any sound ID.

## Installation

1. Download or clone the repo into:
   ```
   World of Warcraft/_retail_/Interface/AddOns/CooldownAlert/
   ```
2. Restart WoW or `/reload`.
3. Type `/cda` in chat to see the command list.

## Commands

| Command | Action |
|---|---|
| `/cda` | Help |
| `/cda on` / `off` | Enable / disable the addon |
| `/cda cd on`/`off` | Alert on real cooldown |
| `/cda unusable on`/`off` | Alert when the skill is not usable |
| `/cda range on`/`off` | Alert when out of range (off by default) |
| `/cda sound <id>` | Change the sound by ID |
| `/cda test` | Play the currently configured sound |
| `/cda ui` | Open the sound-selection interface |
| `/cda scan` | Diagnostics: scan your keys and show slot/CD/usable |
| `/cda capture` | Press a key and show its name/binding/slot |
| `/cda debug` | Toggle debug prints when an alert fires |
| `/cda reset` | Restore default configuration |

## Sound UI

`/cda ui` opens a draggable window with:

- Current sound ID displayed.
- A manual input field with **Play** and **Apply** buttons.
- A list of presets, each with **▶** (preview) and **Use** (apply + play).

More sound IDs can be found at [wago.tools](https://wago.tools/db2/SoundKit).

## Compatibility

- **WoW Midnight (11.2+ / 12.x)** — uses `C_Spell` and handles Blizzard's new *secret numbers* introduced to protect private API.
- **EllesmereUI ActionBars** — specifically tested with this UI.
- Any action bar that preserves Blizzard's native bindings (`ACTIONBUTTON*` / `MULTIACTIONBAR*`).

## License

MIT — see [LICENSE](LICENSE).
