# CooldownAlert

Addon para **World of Warcraft (Midnight / 11.2+)** que reproduce un sonido cuando pulsas una tecla de acción que está:

- En **cooldown real** (ignora el GCD).
- **No usable** (sin maná/rage/runas, stance incorrecta, etc).
- Opcionalmente, **fuera de rango**.

Pensado para corregir el vicio de seguir pulsando la tecla cuando la habilidad aún no está lista. Sin alerta visual — solo un sonido, configurable desde una pequeña UI.

## Características

- Detección fiable vía `C_Spell.GetSpellCooldown` / `C_Item.GetItemCooldown` (devuelven valores normales, tolerantes a los _secret numbers_ de Midnight en combate).
- Soporta **EllesmereUI** (y cualquier action bar que use *native dispatch*) calculando el slot como `(actionpage - 1) × 12 + buttonID`.
- Cubre las 8 barras principales (`ACTIONBUTTON1-12`, `MULTIACTIONBAR1-7 BUTTON1-12`).
- Respeta modifier prefijos: `SHIFT-`, `CTRL-`, `ALT-` y combinaciones.
- Anti-spam configurable entre alertas.
- UI con presets de sonido + campo manual para cualquier ID.

## Instalación

1. Descarga o clona el repo dentro de:
   ```
   World of Warcraft/_retail_/Interface/AddOns/CooldownAlert/
   ```
2. Reinicia WoW o `/reload`.
3. Escribe `/cda` en el chat para ver los comandos.

## Comandos

| Comando | Acción |
|---|---|
| `/cda` | Ayuda |
| `/cda on` / `off` | Activar / desactivar addon |
| `/cda cd on`/`off` | Alertar por cooldown real |
| `/cda unusable on`/`off` | Alertar cuando la skill no es usable |
| `/cda range on`/`off` | Alertar por fuera de rango (off por defecto) |
| `/cda sound <id>` | Cambiar el sonido por ID |
| `/cda test` | Reproducir el sonido actual |
| `/cda ui` | Abrir la interfaz de selección de sonido |
| `/cda scan` | Diagnóstico: escanea tus teclas y muestra slot/CD/usable |
| `/cda capture` | Pulsa una tecla y muestra qué nombre/binding/slot resuelve |
| `/cda debug` | Prints de depuración al saltar una alerta |
| `/cda reset` | Restaurar configuración por defecto |

## UI de sonido

`/cda ui` abre una ventana arrastrable con:

- ID del sonido actual.
- Campo para introducir un ID manual, con botones **Probar** y **Aplicar**.
- Lista de presets, cada uno con **▶** (escuchar) y **Usar** (aplicar + sonar).

Puedes encontrar más IDs de sonidos en [wago.tools](https://wago.tools/db2/SoundKit).

## Compatibilidad

- **WoW Midnight (11.2+ / 12.x)** — usa `C_Spell` y maneja los *secret numbers* que introdujo Blizzard para proteger la API privada.
- **EllesmereUI ActionBars** — testeado específicamente con esta UI.
- Cualquier action bar que mantenga los bindings nativos de Blizzard (`ACTIONBUTTON*` / `MULTIACTIONBAR*`).

## Licencia

MIT — ver [LICENSE](LICENSE).
