import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { HubClient } from "./hub.js";
import { registerTools, Profile } from "./tools.js";

export async function runMcp(opts: { projectDir?: string; url?: string; token?: string; clientName: string; profile?: Profile }) {
  const hub = new HubClient({ ...opts, connectTimeoutMs: 4000 });
  const server = new McpServer({ name: "godot-bridge", version: "0.2.0" }, { instructions: INSTRUCTIONS });
  registerTools(server, hub, opts.profile ?? "full");
  hub.on("disconnected", () => console.error("[godot-bridge] hub disconnected; will reconnect on next call"));
  await server.connect(new StdioServerTransport());
  console.error(`[godot-bridge] MCP ready as "${opts.clientName}" (${opts.profile ?? "full"} profile); hub: ${hub.describeTarget()}`);
  hub.connect().catch((e) => console.error(`[godot-bridge] ${e.message}`));
}

const INSTRUCTIONS = `Godot Bridge: eyes and hands inside the Godot editor and the running game. Workflow: godot_status -> godot_tree/godot_inspect -> godot_api (exact signatures) -> godot_patch + godot_scene save -> godot_run start -> godot_step/godot_observe -> godot_logs. See AGENTS.md.`;
