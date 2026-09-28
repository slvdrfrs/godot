import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { HubClient } from "./hub.js";
import { registerTools } from "./tools.js";

export async function runMcp(opts: { projectDir?: string; url?: string; token?: string; clientName: string }) {
  const hub = new HubClient({ ...opts, connectTimeoutMs: 4000 });
  const server = new McpServer({ name: "godot-bridge", version: "0.1.0" }, { instructions: INSTRUCTIONS });
  registerTools(server, hub);
  hub.on("disconnected", () => console.error("[godot-bridge] hub disconnected; will reconnect on next call"));
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error(`[godot-bridge] MCP server ready as "${opts.clientName}"; hub target: ${hub.describeTarget()}`);
  // Connect lazily in the background so tool listing works even when the editor is closed.
  hub.connect().catch((e) => console.error(`[godot-bridge] ${e.message}`));
}

const INSTRUCTIONS = `Godot Bridge gives you eyes and hands inside the Godot editor and the running game.
Workflow: godot_status -> godot_tree / godot_inspect (structured truth) -> godot_api (exact signatures for this build) ->
godot_patch (undoable edits) -> godot_scene save -> godot_run start -> godot_step / godot_input / godot_observe -> godot_logs.
Use godot_observe with camera_preview to render from any camera, not just the editor viewport. Prefer structured tools over godot_exec.
Edit .gd source with your own file tools, then godot_validate and godot_files rescan / godot_scene reload so the editor picks it up.
Another agent may share the editor: mutations take a short write lease; on CONFLICT wait or coordinate, do not steal blindly.`;
