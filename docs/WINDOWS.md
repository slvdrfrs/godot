# Godot Bridge en Windows con tu proyecto (Godot 4.7.2, Forward+)

Rutas de este ejemplo: editor `C:\Users\Admin\Tools\Godot\Godot_v4.7.2-stable_win64.exe`, consola
`C:\Users\Admin\Tools\Godot\Godot_v4.7.2-stable_win64_console.exe`, proyecto en `<repo>\godot\project.godot`.
Sustituye `<repo>` por la carpeta real. Necesitas Node 18+.

## 1. Construir el servidor MCP (una vez)

```powershell
git clone https://github.com/slvdrfrs/godot C:\Users\Admin\Tools\godot-bridge
cd C:\Users\Admin\Tools\godot-bridge\bridge
npm ci
npm run build
```

## 2. Instalar en tu proyecto

```powershell
node C:\Users\Admin\Tools\godot-bridge\bridge\dist\cli.js install --project <repo>\godot --write-codex
```

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

## Notas 4.7.x

- Validado en Linux headless con Godot 4.5 y 4.7.2 (los 21 pasos del e2e, sin cambios en el addon).
- Forward+ no cambia nada del puente; `camera_preview` copia environment, attributes y compositor de la cámara real.
- Si cambias `godot_bridge/editor_port` en Project Settings, el hub usa ese puerto (o el siguiente libre).
