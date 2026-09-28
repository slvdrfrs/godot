import fs from "node:fs";
import path from "node:path";

export interface Discovery {
  protocol: number;
  url: string;
  port: number;
  token: string;
  pid: number;
  godot: string;
  project: string;
  project_path: string;
  started_at: string;
}

export const DISCOVERY_REL = path.join(".godot", "godot_bridge.json");

/** Locate the Godot project directory: explicit path, GODOT_PROJECT env, or walk up from cwd looking for project.godot. */
export function findProjectDir(explicit?: string): string | undefined {
  const candidates = [explicit, process.env.GODOT_PROJECT].filter(Boolean) as string[];
  for (const c of candidates) {
    const abs = path.resolve(c);
    if (fs.existsSync(path.join(abs, "project.godot"))) return abs;
    if (fs.existsSync(abs) && fs.statSync(abs).isFile() && path.basename(abs) === "project.godot") return path.dirname(abs);
  }
  let dir = process.cwd();
  for (let i = 0; i < 8; i++) {
    if (fs.existsSync(path.join(dir, "project.godot"))) return dir;
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return explicit ? path.resolve(explicit) : undefined;
}

export function readDiscovery(projectDir: string): Discovery | undefined {
  const file = path.join(projectDir, DISCOVERY_REL);
  if (!fs.existsSync(file)) return undefined;
  try {
    const d = JSON.parse(fs.readFileSync(file, "utf8")) as Discovery;
    if (!d.url || !d.token) return undefined;
    return d;
  } catch {
    return undefined;
  }
}

export function pidAlive(pid: number): boolean {
  if (!pid) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (e: any) {
    return e?.code === "EPERM";
  }
}
