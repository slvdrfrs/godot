# Godot Bridge

**Un puente pensado solo para Godot para que Claude Code y Codex CLI vean dentro del editor y del juego en ejecución.**
Árbol de escena estructurado, la API exacta del build que corre, render desde *cualquier* cámara, edición deshacible,
control del juego en vivo (pausa, frames, input, errores, métricas). Local, sin nube, sin recompilar Godot.

```
Claude Code ──MCP stdio──┐                       ┌── EditorPlugin (hub, ws://127.0.0.1:6505)
                         ├── bridge/ (Node/TS) ──┤        │  reenvía target=game
Codex CLI   ──MCP stdio──┘                       └── GodotBridgeRuntime (autoload en el juego F5)
```

## ¿Es verdad que "los motores no están listos para IA y solo pueden adivinar"?

Respuesta corta: **exagerado, y falso en su punto central.** Detalle en [`docs/PLAN.md`](docs/PLAN.md).

| Afirmación del hilo | Veredicto |
|---|---|
| "No pueden ver dentro del motor, solo adivinar" | **Falso.** Godot expone `ClassDB`, `EditorInterface`, `EditorPlugin`, formatos de texto `.tscn/.tres`, LSP (6005), DAP (6006), `--headless`. Lo que faltaba es una interfaz coherente para agentes. Esto es esa interfaz. |
| "Un screenshot es una foto plana de toda la pantalla, no de la escena" | **Cierto para un screenshot del SO; falso como límite.** `godot_observe` renderiza desde cualquier `Camera3D`/`Camera2D` (editor o juego) y devuelve, junto a la imagen, el árbol, la transform de la cámara y qué garantiza esa captura. |
| "three.js es acceso total, los motores no" | **Exagerado.** Con un plugin dentro del proceso tienes el mismo nivel de acceso: reflexión, mutación, render, input, tiempo. |
| "Godot no está listo *out of the box* para agentes" | **Razonable.** Por eso existe este repo. |

## Instalar

Linux/macOS:

```bash
git clone https://github.com/slvdrfrs/godot godot-bridge && cd godot-bridge/bridge
npm ci && npm run build                                   # servidor MCP + CLI
node dist/cli.js install --project /ruta/a/tu/proyecto --write-codex --dry-run   # muestra el diff
node dist/cli.js install --project /ruta/a/tu/proyecto --write-codex             # aplica
```

Windows (PowerShell; Godot 4.7.2 en `C:\Users\Admin\Tools\Godot`):

```powershell
git clone https://github.com/slvdrfrs/godot C:\Users\Admin\Tools\godot-bridge
cd C:\Users\Admin\Tools\godot-bridge\bridge
npm ci; npm run build
node dist\cli.js install --project <repo>\godot --write-codex --dry-run
node dist\cli.js install --project <repo>\godot --write-codex
C:\Users\Admin\Tools\Godot\Godot_v4.7.2-stable_win64.exe --path <repo>\godot
node dist\cli.js doctor --project <repo>\godot
```

`main` contiene la versión estable; la rama de desarrollo es `claude/wizardly-fermi-tsuk2z` (`git clone -b <rama> ...`).

`install` copia el addon a `addons/godot_bridge`, lo activa en `project.godot`, escribe `.mcp.json` (Claude Code) y la sección
`[mcp_servers.godot]` en `~/.codex/config.toml` (Codex). `uninstall` revierte exactamente eso (addon, plugin, autoload, ajustes
`godot_bridge/*`, entrada de `.mcp.json`, sección de Codex); ambos aceptan `--dry-run`. Abre el proyecto en **Godot 4.5 o superior**
(e2e en verde con 4.5 y 4.7.2; 4.3/4.4 funcionan sin captura de logs). El panel inferior **Bridge** muestra el puerto y los agentes.
Claude y Codex pueden estar conectados **a la vez**.

## Qué puede hacer un agente (23 tools MCP)

| Ver | Saber | Editar | Ejecutar |
|---|---|---|---|
| `godot_tree`, `godot_inspect`, `godot_find`, `godot_cameras` | `godot_api` (ClassDB + scripts del proyecto), `godot_files`, `godot_project` | `godot_patch` (deshacible), `godot_scene`, `godot_selection`, `godot_history` | `godot_run`, `godot_step`, `godot_input`, `godot_call`, `godot_exec` |
| `godot_observe` (viewport / camera_preview / camera_takeover), `godot_spatial` | `godot_validate`, `godot_logs`, `godot_metrics`, `godot_status` | `godot_lease` (varios agentes) | |

Todas aceptan `target: "editor" | "game" | run-<pid>`; las mismas tools sirven para la escena editada y para el juego corriendo.
Con varias instancias del juego, `target: "game"` devuelve `AMBIGUOUS` con la lista de runs en vez de elegir una en silencio.

**Coste de contexto** (tokens o200k del `tools/list`, medido): perfil `full` 23 tools = **4.028**; perfil `minimal`
(`--profile minimal`, 12 tools: status, api, tree, inspect, find, patch, scene, run, step, input, observe, logs) = **2.564**.
La versión anterior costaba 6.654. Las capturas salen por defecto en JPEG 640x360 (~300 tokens de imagen en Claude); con
`width: 320, height: 180` ≈ 80. `godot_tree` corta a profundidad 3 / 150 nodos y devuelve `class_counts`; `exclude_classes`
oculta subárboles ruidosos (colisionadores, luces). `godot_inspect` devuelve solo propiedades no-default.

## Modo pair (Claude + Codex)

`AGENTS.md` (Codex) y `CLAUDE.md` (Claude) describen el mismo flujo. El skill `/godot-pair` y `godot-bridge consult "<brief>"`
envían a Codex un brief con un snapshot vivo del editor (árbol, cámaras, errores) y devuelven su plan para fusionarlo.
Ambos agentes comparten el editor con *write leases* de 30 s por objetivo: quien edita tiene el lease, el otro lee.

## Probarlo

```bash
GODOT=/ruta/Godot_v4.5 tests/run_e2e.sh
```

Arranca un editor headless sobre `tests/project`, conecta dos agentes, edita/deshace/guarda, lanza el juego headless,
lo pausa, avanza frames, inyecta input, lee logs y métricas, lo para, comprueba AMBIGUOUS con dos instancias, rechaza tokens
inválidos y verifica que el runtime es inerte fuera del editor. 26 pasos, en verde con Godot 4.5 y 4.7.2 (Linux headless).
En Windows: `$env:GODOT="C:\Users\Admin\Tools\Godot\Godot_v4.7.2-stable_win64_console.exe"; node tests\e2e.mjs`.
CI en `.github/workflows/e2e.yml`.

## Seguridad y builds de Steam

- Hub solo en `127.0.0.1`, token aleatorio por sesión en `.godot/godot_bridge.json`; sin token válido no se acepta ninguna llamada
  (un token vacío en el servidor rechaza a todos, nunca autentica a todos).
- `godot_exec` está **desactivado por defecto** (`godot_bridge/allow_exec = false`). Sin sandbox ni preempción: la respuesta
  incluye `sandbox: "none"` y un `warning` si tardó más de `soft_limit_ms`.
- El autoload `GodotBridgeRuntime` solo actúa en juegos lanzados **por el editor** (F5/F6). En `godot --path proyecto --headless`,
  `--script`, tests o exports no carga ningún script, no procesa ningún frame y no imprime nada. Variables de entorno y flags no lo
  activan; en un export solo lo activa el feature tag `godot_bridge` de un preset. Modo `GODOT_BRIDGE_LISTEN` genera su propio token.
- Para el build: excluye el addon en el preset (`docs/WINDOWS.md`, sección Export) o ejecuta `uninstall` antes de exportar.

## Qué NO garantiza (léelo)

- Sin GPU/headless no hay captura: `godot_observe` devuelve `UNSUPPORTED` en vez de una imagen falsa.
- `camera_preview` comparte el mundo pero no los `CanvasLayer` (HUD) ni el historial de efectos temporales; `camera_takeover` es exacto pero cambia la cámara actual un frame. Cada captura dice su `guarantee` y sus `limitations`.
- `godot_step` es cooperativo: informa frames pedidos vs. observados; nodos con `process_mode = ALWAYS` siguen corriendo en pausa.
- `godot_exec` no tiene sandbox ni timeout (por eso está apagado por defecto).

Windows + Godot 4.7.2 paso a paso con rutas reales: [`docs/WINDOWS.md`](docs/WINDOWS.md).
Protocolo interno: [`docs/PROTOCOL.md`](docs/PROTOCOL.md). Plan fusionado Claude + Codex: [`docs/PLAN.md`](docs/PLAN.md).
