# Godot Bridge en Windows con tu proyecto (Godot 4.7.2, Forward+)

Rutas de este ejemplo: editor `C:\Users\Admin\Tools\Godot\Godot_v4.7.2-stable_win64.exe`, consola
`C:\Users\Admin\Tools\Godot\Godot_v4.7.2-stable_win64_console.exe`, proyecto en `<repo>\godot\project.godot`.
Sustituye `<repo>` por la carpeta real. Necesitas Node 18+.

## 1. Construir el servidor MCP (una vez)

```powershell
git clone https://github.com/slvdrfrs/godot C:\Users\Admin\Tools\godot-bridge     # main = estable; -b claude/wizardly-fermi-tsuk2z = desarrollo
cd C:\Users\Admin\Tools\godot-bridge\bridge
npm ci
npm run build
```

## 2. Instalar en tu proyecto

```powershell
node C:\Users\Admin\Tools\godot-bridge\bridge\dist\cli.js install --project <repo>\godot --write-codex --dry-run   # diff
node C:\Users\Admin\Tools\godot-bridge\bridge\dist\cli.js install --project <repo>\godot --write-codex             # aplica
```

Añade `--profile minimal` si quieres exponer solo las 12 tools centrales (2.564 tokens en vez de 4.028 por sesión).
Para revertir: `uninstall --project <repo>\godot` (acepta `--dry-run`). Quita el addon, el plugin y el autoload de
`project.godot`, los ajustes `godot_bridge/*`, la entrada `godot` de `.mcp.json` y la sección `[mcp_servers.godot]` de Codex.

Hace cuatro cosas: copia `addons\godot_bridge` dentro de `<repo>\godot`, activa el plugin en `project.godot`, escribe
`<repo>\godot\.mcp.json` (Claude Code) y añade `[mcp_servers.godot]` a `%USERPROFILE%\.codex\config.toml` (Codex).
Si Claude Code lo abres desde `<repo>` y no desde `<repo>\godot`, copia el `.mcp.json` a `<repo>` (las rutas dentro son absolutas, funciona igual).

## 3. Abrir el editor

```powershell
C:\Users\Admin\Tools\Godot\Godot_v4.7.2-stable_win64.exe --path <repo>\godot
```

En el panel inferior **Bridge** verás `ws://127.0.0.1:6505 | agents: 0 | game runs: 0`. La primera vez el plugin registra
el autoload `GodotBridgeRuntime` en `project.godot` (es lo que hace que F5 conecte el juego al hub). Añade
`.godot/` a tu `.gitignore` si no lo está: ahí va el archivo de descubrimiento con el token de sesión.

## 4. Comprobar

```powershell
node C:\Users\Admin\Tools\godot-bridge\bridge\dist\cli.js doctor --project <repo>\godot
```

Con el editor abierto debe decir `connected + authenticated` y `capture works` (en Windows con GPU sí hay captura).
Luego, en Claude Code dentro de `<repo>` escribe: "usa godot_status y godot_tree y dime qué hay en la escena".
En Codex: `codex` en la misma carpeta; `/mcp` debe listar `godot`.

## 5. Tests del puente con tu binario

```powershell
$env:GODOT = "C:\Users\Admin\Tools\Godot\Godot_v4.7.2-stable_win64_console.exe"
cd C:\Users\Admin\Tools\godot-bridge
node tests\e2e.mjs
```

Usa el ejecutable de consola (el mismo que usas para tus tests) porque el e2e lee la salida estándar del editor.

## 6. Consultar a Codex con un snapshot vivo

```powershell
node C:\Users\Admin\Tools\godot-bridge\bridge\dist\cli.js consult "Revisa mi plan para X" --project <repo>\godot [--game]
```

Sin `codex` en el PATH imprime el prompt para pegarlo a mano. `--print` solo genera el prompt.

## Tus tests headless y capturas (`--headless --path godot -- --selftest`, `--shot`)

No se ven afectados. El autoload comprueba en `_ready` si el juego lo lanzó el editor (build de editor + sesión de depuración
remota o `--editor-pid`, que solo pone el editor). Si no, retorna sin cargar ningún otro script, sin `set_process`, sin abrir
sockets y sin imprimir. El e2e lo verifica en tres variantes (ejecución directa, con flags/env, y con `core/` ausente).
`godot_exec` está apagado por defecto; para usarlo: Project Settings > Godot Bridge > Allow Exec.

## Export a Steam (Windows)

Opción A, recomendada: ejecuta `uninstall` antes de exportar y `install` después (dos comandos, sin rastro en el build).

Opción B: deja el addon pero exclúyelo del paquete. En `export_presets.cfg`, en el preset de Windows:

```ini
exclude_filter="addons/godot_bridge/core/*, addons/godot_bridge/editor/*, addons/godot_bridge/plugin.gd, addons/godot_bridge/plugin.cfg, addons/godot_bridge/runtime/runtime_handlers.gd"
```

`runtime/bridge_runtime.gd` debe quedarse porque `project.godot` lo referencia como autoload; en el build es un nodo vacío que
retorna en `_ready` (no hay build de editor, no hay `godot_bridge` en las features). Si además quieres quitar el autoload del
build, elimina la línea `GodotBridgeRuntime=` de `[autoload]` antes de exportar (es lo que hace `uninstall`).
Nunca añadas el feature tag `godot_bridge` a un preset que vaya a Steam: es el único interruptor que enciende el runtime en un export.

## Notas 4.7.x

- Validado en Linux headless con Godot 4.5 y 4.7.2 (los 21 pasos del e2e, sin cambios en el addon).
- Forward+ no cambia nada del puente; `camera_preview` copia environment, attributes y compositor de la cámara real.
- Si cambias `godot_bridge/editor_port` en Project Settings, el hub usa ese puerto (o el siguiente libre).
