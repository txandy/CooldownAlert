# CooldownAlert

> Idiomas: **Español** · [English](README.md)

Addon para **World of Warcraft (Midnight / 11.2+)** con dos alertas complementarias:

1. **Alerta al pulsar en CD** — reproduce un sonido cuando pulsas una tecla de acción para una habilidad que está en CD real, no es usable (sin recursos/stance), u opcionalmente fuera de rango. Ignora el GCD. Pensada para corregir el vicio de machacar teclas mientras las habilidades siguen en CD.
2. **Alerta de habilidad lista** — reproduce un sonido distinto (y muestra el icono del hechizo encima del personaje) en el momento en que una habilidad trackeada vuelve a estar disponible. Sólo suena para los hechizos que añades a la lista.

## Características

- **Botón de minimapa** — click izquierdo abre la UI, click derecho activa/desactiva el addon, arrastrable.
- **UI con dos pestañas**: una para el sonido al pulsar en CD, otra para la alerta de "lista" + lista de hechizos trackeados.
- **Selector de sonido** — popup scrollable con presets (preview con icono de altavoz) + campo manual para cualquier ID.
- **Hechizos trackeados** — añadir/quitar por spellID con modo por-hechizo:
  - `cd` — dispara al terminar el cooldown real (ignora recursos).
  - `usable` — dispara cuando la habilidad se puede lanzar de verdad (CD terminado **Y** recursos OK). Ideal para habilidades que combinan ambas condiciones, como ciertos hero talents.
- **Icono flotante (pulse)** — aparece encima del personaje cuando un hechizo trackeado está listo, con fade-out. Arrastrable cuando está desbloqueado.
- Detección fiable vía `IsUsableAction` sobre el slot en barra (booleanos, inmunes al "secret number" privacy taint de Midnight en combate), con `C_Spell.GetSpellCooldown` / `C_Spell.IsSpellUsable` como fallback para hechizos que no están en barras.
- Soporta **EllesmereUI** y cualquier action bar que use *native dispatch* calculando el slot como `(actionpage - 1) × 12 + buttonID`.
- Cubre las 8 barras principales (`ACTIONBUTTON1-12`, `MULTIACTIONBAR1-7 BUTTON1-12`).
- Respeta modifier prefijos: `SHIFT-`, `CTRL-`, `ALT-` y combinaciones.
- Anti-spam configurable entre alertas.

## Instalación

1. Descarga o clona el repo dentro de:
   ```
   World of Warcraft/_retail_/Interface/AddOns/CooldownAlert/
   ```
2. Reinicia WoW o `/reload`.
3. Escribe `/cda` en el chat para ver los comandos, o pulsa el botón del minimapa.

## Comandos

### Generales
| Comando | Acción |
|---|---|
| `/cda` | Ayuda |
| `/cda on` / `off` | Activar / desactivar addon |
| `/cda ui` | Abrir la ventana de configuración |
| `/cda minimap show`/`hide` | Mostrar/ocultar el botón del minimapa |
| `/cda reset` | Restaurar configuración por defecto |

### Alerta al pulsar en CD
| Comando | Acción |
|---|---|
| `/cda cd on`/`off` | Alertar por cooldown real |
| `/cda unusable on`/`off` | Alertar cuando la skill no es usable |
| `/cda range on`/`off` | Alertar por fuera de rango (off por defecto) |
| `/cda sound <id>` | Cambiar el sonido por ID |
| `/cda test` | Reproducir el sonido actual |

### Alerta de habilidad lista (hechizos trackeados)
| Comando | Acción |
|---|---|
| `/cda ready on`/`off` | Activar/desactivar la alerta de lista |
| `/cda track <id> [cd\|usable]` | Añadir hechizo (modo por defecto: `cd`) |
| `/cda mode <id> cd\|usable` | Cambiar el modo de un hechizo trackeado |
| `/cda untrack <id>` | Quitar un hechizo de la lista |
| `/cda tracked` | Listar hechizos trackeados con su modo |
| `/cda pulse on`/`off` | Mostrar/ocultar el icono flotante |
| `/cda pulse unlock`/`lock` | Desbloquear para mover / bloquear posición |
| `/cda pulse test` | Probar el pulse |

### Diagnóstico
| Comando | Acción |
|---|---|
| `/cda scan` | Escanea tus teclas y muestra slot/CD/usable |
| `/cda capture` | Pulsa una tecla y muestra qué nombre/binding/slot resuelve |
| `/cda diag <id>` | Diagnóstico completo del estado de un hechizo trackeado |
| `/cda d1 <id>` | Diagnóstico compacto en una sola línea |
| `/cda watch <id>` | Monitoriza estado 20s, una línea/seg |
| `/cda casts on`/`off` | Log de cada cast con su spellID |
| `/cda debug` | Prints de depuración |

## UI

Abierta con `/cda ui` o el botón del minimapa. Dos pestañas:

- **Al pulsar en CD**: selector de sonido para la alerta de "tecla en CD".
- **Habilidad lista**: selector de sonido para la alerta de "lista", checkbox de activación, toggle del icono flotante, y lista scrollable de hechizos trackeados con icono/nombre/ID/botón de modo/quitar por fila.

Puedes encontrar más IDs de sonidos en [wago.tools](https://wago.tools/db2/SoundKit).

## Compatibilidad

- **WoW Midnight (11.2+ / 12.x)** — maneja los "secret numbers" de privacidad que introdujo Blizzard, afectando a `C_Spell.GetSpellCooldown` en combate para hechizos de hero talent. Usa `IsUsableAction(slot)` (booleano, no taintado) como vía robusta.
- **EllesmereUI ActionBars** — testeado específicamente con esta UI.
- Cualquier action bar que mantenga los bindings nativos de Blizzard (`ACTIONBUTTON*` / `MULTIACTIONBAR*`).

## Limitaciones conocidas

Algunos hero talents (p. ej. **Void Ray** del DH Devourer en Metamorfosis) tienen cooldowns que Blizzard oculta a todas las APIs públicas en combate — tanto `C_Spell.GetSpellCooldown` (valores taintados) como `IsUsableAction` (devuelve `true` incluso con el CD visible). No pueden trackearse fiablemente por ningún addon hasta que Blizzard cambie el modelo de privacidad.

## Licencia

MIT — ver [LICENSE](LICENSE).
