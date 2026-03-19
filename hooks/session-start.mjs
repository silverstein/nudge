#!/usr/bin/env node
// SessionStart hook: check if the nudge daemon is running and report status.
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const home = homedir();
const sessionsFile = join(home, ".nudge", "sessions.json");
const plistLabel = "com.silverbook.nudge";

let status = "";

try {
  const uid = execFileSync("id", ["-u"], { encoding: "utf8" }).trim();
  let daemonRunning = false;
  try {
    const out = execFileSync(
      "launchctl",
      ["print", `gui/${uid}/${plistLabel}`],
      { encoding: "utf8", stdio: ["pipe", "pipe", "pipe"] }
    );
    daemonRunning = out.includes("state = waiting");
  } catch {
    daemonRunning = false;
  }

  if (existsSync(sessionsFile)) {
    const sessions = JSON.parse(readFileSync(sessionsFile, "utf8"));
    const active = Object.entries(sessions.sessions || {}).filter(
      ([, v]) => v.active && !v.paused && !v.completedAt && !v.depletedAt
    );
    if (active.length > 0) {
      const names = active.map(([k]) => k).join(", ");
      status = `Nudge: ${daemonRunning ? "running" : "NOT running"}, monitoring ${active.length} session(s): ${names}. Use /nudge for status.`;
    }
  }
} catch {
  // Silent
}

if (status) {
  console.log(JSON.stringify({ nudge_status: status }));
}
