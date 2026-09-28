import { EventEmitter } from "node:events";
import WebSocket from "ws";
import { Discovery, findProjectDir, readDiscovery, pidAlive } from "./discovery.js";

export class BridgeError extends Error {
  code: string;
  data: any;
  constructor(code: string, message: string, data?: any) {
    super(message);
    this.code = code;
    this.data = data;
  }
}

export interface HubOptions {
  projectDir?: string;
  url?: string;
  token?: string;
  clientName: string;
  connectTimeoutMs?: number;
  requestTimeoutMs?: number;
}

interface Pending {
  resolve: (v: any) => void;
  reject: (e: any) => void;
  timer: NodeJS.Timeout;
  method: string;
}

/** JSON-RPC client for the Godot Bridge hub with discovery, hello/auth and auto-reconnect. */
export class HubClient extends EventEmitter {
  opts: HubOptions;
  projectDir?: string;
  discovery?: Discovery;
  hello?: any;
  private ws?: WebSocket;
  private pending = new Map<string | number, Pending>();
  private nextId = 1;
  private connecting?: Promise<void>;
  closed = false;

  constructor(opts: HubOptions) {
    super();
    this.opts = opts;
    this.projectDir = findProjectDir(opts.projectDir);
  }

  get connected(): boolean {
    return !!this.ws && this.ws.readyState === WebSocket.OPEN && !!this.hello;
  }

  describeTarget(): string {
    if (this.discovery) return `${this.discovery.url} (project "${this.discovery.project}", Godot ${this.discovery.godot}, pid ${this.discovery.pid})`;
    if (this.opts.url) return this.opts.url;
    return `project dir ${this.projectDir ?? "<not found>"}`;
  }

  /** Resolve url/token: explicit options, else discovery file in the project. */
  private resolveEndpoint(): { url: string; token: string } | undefined {
    if (this.opts.url) return { url: this.opts.url, token: this.opts.token ?? "" };
    if (!this.projectDir) return undefined;
    const d = readDiscovery(this.projectDir);
    if (!d) return undefined;
    if (d.pid && !pidAlive(d.pid)) return undefined; // stale file from a crashed editor
    this.discovery = d;
    return { url: d.url, token: d.token };
  }

  async connect(timeoutMs = this.opts.connectTimeoutMs ?? 5000): Promise<void> {
    if (this.connected) return;
    if (this.connecting) return this.connecting;
    this.connecting = this._connect(timeoutMs).finally(() => (this.connecting = undefined));
    return this.connecting;
  }

  private async _connect(timeoutMs: number): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    let endpoint = this.resolveEndpoint();
    while (!endpoint && Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 500));
      endpoint = this.resolveEndpoint();
    }
    if (!endpoint) {
      throw new BridgeError(
        "EDITOR_NOT_RUNNING",
        `No Godot Bridge hub found for ${this.projectDir ?? "<no project dir>"}. Open the project in the Godot editor with the Godot Bridge plugin enabled (Project > Project Settings > Plugins), or pass --url. Looked for ${this.projectDir ? this.projectDir + "/.godot/godot_bridge.json" : "a project.godot up the directory tree"}.`,
      );
    }
    await new Promise<void>((resolve, reject) => {
      const ws = new WebSocket(endpoint!.url, { maxPayload: 256 * 1024 * 1024 });
      const timer = setTimeout(() => {
        ws.terminate();
        reject(new BridgeError("CONNECT_TIMEOUT", `Timed out connecting to ${endpoint!.url}`));
      }, Math.max(1000, deadline - Date.now()));
      ws.on("open", () => {
        clearTimeout(timer);
        this.ws = ws;
        resolve();
      });
      ws.on("error", (e) => {
        clearTimeout(timer);
        reject(new BridgeError("CONNECT_FAILED", `Cannot connect to ${endpoint!.url}: ${e.message}`));
      });
      ws.on("message", (data) => this.onMessage(data.toString()));
      ws.on("close", () => this.onClose());
    });
    this.hello = await this.request("bridge.hello", { client: this.opts.clientName, role: "agent", token: endpoint.token }, 10000);
    this.emit("connected", this.hello);
  }

  private onMessage(text: string): void {
    let msg: any;
    try {
      msg = JSON.parse(text);
    } catch {
      return;
    }
    if (msg.method) {
      this.emit("notification", msg);
      return;
    }
    const p = this.pending.get(msg.id);
    if (!p) return;
    this.pending.delete(msg.id);
    clearTimeout(p.timer);
    if (msg.error) {
      const data = msg.error.data ?? {};
      p.reject(new BridgeError(data.code ?? `RPC_${msg.error.code}`, msg.error.message, data.data ?? data));
    } else {
      p.resolve(msg.result);
    }
  }

  private onClose(): void {
    const wasConnected = !!this.hello;
    this.ws = undefined;
    this.hello = undefined;
    for (const [id, p] of this.pending) {
      clearTimeout(p.timer);
      p.reject(new BridgeError("DISCONNECTED", `Hub connection closed while waiting for ${p.method}`));
      this.pending.delete(id);
    }
    if (wasConnected) this.emit("disconnected");
  }

  async request(method: string, params: Record<string, any> = {}, timeoutMs = this.opts.requestTimeoutMs ?? 60000): Promise<any> {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      if (method === "bridge.hello") throw new BridgeError("DISCONNECTED", "Not connected");
      await this.connect();
    }
    const id = this.nextId++;
    const ws = this.ws!;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new BridgeError("TIMEOUT", `${method} timed out after ${timeoutMs} ms (is the editor blocked by a modal dialog or a breakpoint?)`));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer, method });
      ws.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
    });
  }

  close(): void {
    this.closed = true;
    this.ws?.close();
  }
}
