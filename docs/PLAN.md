# Plan fusionado: Claude + Codex

Este documento registra el veredicto sobre el hilo, el plan que propuso cada uno, qué se adoptó de cada lado y por qué,
y lo que queda pendiente. Lo construido está en el repo y validado por `tests/e2e.mjs` contra Godot 4.5 headless.

## 1. Veredicto sobre el hilo (coincidimos)

- "No pueden ver dentro del motor": **falso**. Godot ofrece reflexión (`ClassDB`, `Script`), acceso al árbol, `EditorPlugin`/`EditorInterface`,
  LSP/DAP, formatos de texto y CLI headless. Lo que no existía era una interfaz coherente para agentes.
- "Un screenshot es plano y no es la escena": **cierto para el screenshot del SO**, pero no es un límite del motor: un `SubViewport`
  que comparte el `World3D`/`World2D` renderiza desde cualquier cámara, y la imagen se acompaña de datos estructurados.
- "three.js acceso total vs motores": exagerado. Es comodidad de tooling, no una diferencia fundamental.
- Codex añadió una precisión que adoptamos como principio: **una imagen y un árbol tomados en momentos distintos no son un snapshot
  atómico**; cada observación declara su `guarantee`, sus `limitations` y su `consistency`.

## 2. Arquitectura: qué propuso cada uno y qué se construyó

| Tema | Claude (inicial) | Codex | Decisión |
|---|---|---|---|
| Topología | El editor es servidor WS; el juego abre **otro** servidor en :6506 | Daemon coordinador aparte; editor y juego se conectan a él | **Híbrido**: el EditorPlugin es el hub (ya es el proceso longevo y donde ocurren las mutaciones), y **el juego se conecta al hub como cliente** (idea de Codex de invertir el runtime). Sin daemon extra, sin puerto por ejecución, varias instancias F5 simultáneas. |
| Puertos | Fijos 6505/6506 | Dinámicos + archivo de descubrimiento con `project_id`, puerto, PID, token | **Codex**: puerto preferido con fallback al siguiente libre, `.godot/godot_bridge.json` con token por sesión y PID (se ignora si el PID murió). |
| Identidad de nodos | `NodePath` | Handle por `object_id` (string, 64 bit) + `path_hint` | **Codex**: cada nodo lleva `id` (instance id) y `path`; los refs aceptan ambos. |
| Serialización | `JSON.stringify` + `str_to_var` | Codec explícito para todos los Variant | **Codex**: `core/codec.gd` con tipos etiquetados `{"$t":...}` y coerción por tipo de destino. |
| Cámaras | Duplicar transform en un SubViewport | Tres modos con garantías distintas; cámara auxiliar sin duplicar scripts; Camera2D con centro efectivo | **Codex**: `viewport` / `camera_preview` / `camera_takeover`; la aux copia proyección, FOV, near/far, cull mask, environment, attributes, compositor, offsets; Camera2D usa `get_screen_center_position()`; se declara que los `CanvasLayer` no se incluyen. |
| Concurrencia | "varios clientes = ok" | Leases con vencimiento, cola de mutaciones, precondiciones, atribución | **Codex, simplificado**: lease de escritura de 30 s por objetivo con auto-adquisición y `CONFLICT` explícito; `expected_old` en `set_property`; historial de mutaciones con autor; etiqueta de undo con el nombre del cliente. La cola es implícita: el hub es single-thread. |
| Stepping | "await N frames" | Contrato honesto: pedido vs observado | **Codex**: `run.step` devuelve `observed_process_frames`/`observed_physics_frames` y un `guarantee`. Añadido por Claude tras el e2e: los eventos de input se entregan **dentro** del step para que `is_action_just_pressed` sea correcto. |
| Logs | `Logger` (4.5) | Mutex, callbacks desde otros hilos, no tocar el árbol ni el socket | **Codex**: `log_sink.gd` con `Mutex` y ring buffer; lectura desde el hilo principal; `available=false` en < 4.5. |
| Gating del runtime | `OS.has_feature("editor")` | Feature `editor_runtime`, flag explícito, inerte en exports | **Codex**: `editor_runtime` o env `GODOT_BRIDGE=1` / `--godot-bridge`. |
| Tools MCP | `godot_*` y `game_*` duplicadas | Un `target` explícito | **Codex**: 23 tools con `target: editor|game|run-id`. |
| Ground truth de API | ClassDB | ClassDB + reflexión de `Script` + versión del proceso | **Ambos**: `api.class`, `api.search`, `api.script` (exports, señales, defaults). |
| exec.gdscript | Tool normal | Escape hatch opcional, sin sandbox, documentado | **Codex**: gated por `godot_bridge/allow_exec`, descripción honesta. |
| Modo pair | Skill + `codex exec` | Posponer hasta que el puente sea fiable con dos clientes | **Claude**: se incluye como capa fina (skill + `scripts/codex-consult.sh`) *porque* el e2e ya demuestra dos clientes simultáneos con leases; el puente no depende de ella. |

## 3. Qué se rechazó y por qué

- **Daemon coordinador separado** (Codex): añade ciclo de vida, bloqueo de arranque y descubrimiento de un tercer proceso. El editor ya cumple ese rol y la validación e2e muestra que dos adaptadores + un juego se coordinan bien contra él. Si algún día hace falta operar sin editor, el runtime ya puede escuchar solo (`GODOT_BRIDGE_LISTEN`).
- **Transacciones ACID en `scene.patch`** (Codex lo descartó también): se valida todo el batch antes de aplicar (`dry_run`), pero setters con efectos externos no se pueden revertir; se documenta.
- **Debugger DAP / breakpoints / profiler completo**: fuera de v1 (ver pendientes).

## 4. Lo que el e2e demuestra (Godot 4.5 headless, `tests/e2e.mjs`)

Dos agentes conectados a la vez; status; `api.class`/`api.script`; tree/find/inspect/cameras; patch con `dry_run`, precondición,
5 operaciones en una sola acción de undo, undo/redo; conflicto de lease entre agentes; guardado a `.tscn` y `remove_node` deshecho;
`exec.gdscript`; captura de `push_error`/`print` por el Logger; `validate.scripts` detecta un script roto; captura rechazada con
`UNSUPPORTED` en headless; `run.start` lanza el juego headless y éste se conecta al hub; en el juego: status, tree, `scene.call`,
pausa + step con frames observados, input de acción y tecla que llegan al script (contador y señal), logs del juego, patch sin undo,
métricas, bounds, exec, lease sobre el run; `run.stop`.

## 5. Pendiente (orden sugerido)

1. Validar `camera_preview`/`camera_takeover` con GPU real (escena 3D con dos cámaras; 2D con smoothing, límites, HUD en CanvasLayer).
2. `godot_watch` / eventos push (cambios de propiedades, señales) y `snapshot_diff`.
3. Integración DAP: breakpoints, stack, variables (`godot_debug_*`), y detección de "pausado en breakpoint" para no confundirlo con timeout.
4. `godot_scenario`: secuencia de input/esperas/aserciones para pruebas reproducibles; `--fixed-fps` y semillas.
5. Windows/macOS: rutas con espacios, `pidAlive`, `~/.codex/config.toml`.
6. Publicar `godot-bridge-mcp` en npm con el addon dentro del paquete (`install` ya busca `addon/` junto a `dist/`).
