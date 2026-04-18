# CooldownAlert

> Languages: **English** · [Español](README.es.md)

A **World of Warcraft (Midnight / 11.2+)** addon with two complementary alerts:

1. **Press-on-cooldown alert** — plays a sound when you press an action key for a spell that's on real CD, not usable (missing resource/stance), or optionally out of range. Ignores the GCD. Designed to break the habit of mashing keys while abilities are still down.
2. **Ready alert for tracked spells** — plays a different sound (and shows a spell icon above your character) the moment a tracked spell becomes ready again. Tracks only the spells you add to the list.

## Features

- **Minimap button** — left-click opens the UI, right-click toggles the addon, drag to reposition.
- **Two-tab UI**: one tab for the press-on-cooldown sound, another for the ready alert + tracked spell list.
- **Sound selector** — scrollable popup with presets (speaker-icon preview) plus a manual sound-ID input.
- **Tracked spells** — add/remove by spellID with a per-spell mode:
  - `cd` — fires when the real cooldown ends (ignores resources).
  - `usable` — fires when the spell can actually be cast now (CD done **and** resources OK). Good for combined spells like hero-talent abilities gated by both.
- **On-screen pulse** — configurable icon fades in above the player when a tracked spell is ready, draggable when unlocked.
- Reliable detection via action-slot `IsUsableAction` (booleans are immune to Midnight's "secret number" privacy taint in combat), with `C_Spell.GetSpellCooldown` / `C_Spell.IsSpellUsable` as fallback for spells not on action bars.
- Supports **EllesmereUI** and any action bar using *native dispatch* by computing the slot as `(actionpage - 1) × 12 + buttonID`.
- Covers the 8 main bars (`ACTIONBUTTON1-12`, `MULTIACTIONBAR1-7 BUTTON1-12`).
- Respects modifier prefixes: `SHIFT-`, `CTRL-`, `ALT-` and combinations.
- Configurable anti-spam cooldown between alerts.

## Installation

1. Download or clone the repo into:
   ```
   World of Warcraft/_retail_/Interface/AddOns/CooldownAlert/
   ```
2. Restart WoW or `/reload`.
3. Type `/cda` in chat to see the command list, or click the minimap button.

## Commands

### Core
| Command | Action |
|---|---|
| `/cda` | Help |
| `/cda on` / `off` | Enable / disable the addon |
| `/cda ui` | Open the configuration window |
| `/cda minimap show`/`hide` | Show/hide the minimap button |
| `/cda reset` | Restore default configuration |

### Press-on-cooldown alert
| Command | Action |
|---|---|
| `/cda cd on`/`off` | Alert on real cooldown |
| `/cda unusable on`/`off` | Alert when the skill is not usable |
| `/cda range on`/`off` | Alert when out of range (off by default) |
| `/cda sound <id>` | Change the sound by ID |
| `/cda test` | Play the currently configured sound |

### Ready alert (tracked spells)
| Command | Action |
|---|---|
| `/cda ready on`/`off` | Enable/disable the ready alert |
| `/cda track <id> [cd\|usable]` | Add a spell (default mode: `cd`) |
| `/cda mode <id> cd\|usable` | Change the mode of a tracked spell |
| `/cda untrack <id>` | Remove a spell from the list |
| `/cda tracked` | List tracked spells with their modes |
| `/cda pulse on`/`off` | Show/hide the on-screen icon |
| `/cda pulse unlock`/`lock` | Unlock to drag / lock to fix position |
| `/cda pulse test` | Play a test pulse |

### Diagnostics
| Command | Action |
|---|---|
| `/cda scan` | Scan your keys and show slot/CD/usable |
| `/cda capture` | Press a key and show its name/binding/slot |
| `/cda diag <id>` | Full diagnostic of a tracked spell's state |
| `/cda d1 <id>` | Compact one-line diagnostic |
| `/cda watch <id>` | Monitor state for 20s, 1 line per second |
| `/cda casts on`/`off` | Log each cast with its spellID |
| `/cda debug` | Toggle debug prints |

## UI

Opened with `/cda ui` or the minimap button. Two tabs:

- **Al pulsar en CD**: sound selector for the press-on-cooldown alert.
- **Habilidad lista**: sound selector for the ready alert, enable toggle, pulse-icon toggle, and the scrollable list of tracked spells with per-row icon/name/ID/mode toggle/remove.

More sound IDs can be found at [wago.tools](https://wago.tools/db2/SoundKit).

## Compatibility

- **WoW Midnight (11.2+ / 12.x)** — handles Blizzard's "secret numbers" privacy taint that affects `C_Spell.GetSpellCooldown` in combat for hero-talent spells. Falls back to `IsUsableAction(slot)` (boolean, untainted) for robust in-combat detection.
- **EllesmereUI ActionBars** — specifically tested with this UI.
- Any action bar that preserves Blizzard's native bindings (`ACTIONBUTTON*` / `MULTIACTIONBAR*`).

## Known limitations

Some hero-talent abilities (e.g., DH Devourer's **Void Ray** in Metamorphosis) have cooldowns that Blizzard hides from all public APIs in combat — both `C_Spell.GetSpellCooldown` (tainted values) and `IsUsableAction` (returns `true` even during the visible CD). These cannot be tracked reliably by any addon until Blizzard changes the privacy model.

## License

MIT — see [LICENSE](LICENSE).
