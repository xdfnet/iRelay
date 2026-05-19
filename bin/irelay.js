#!/usr/bin/env node

const { spawnSync } = require("node:child_process");
const path = require("node:path");

const exe = process.platform === "win32" ? "irelay.exe" : "irelay";
const bin = path.join(__dirname, "..", "dist", exe);
const result = spawnSync(bin, process.argv.slice(2), { stdio: "inherit" });

if (result.error) {
  console.error(`iRelay binary not found at ${bin}. Try reinstalling @xdfnet/irelay.`);
  process.exit(1);
}

process.exit(result.status ?? 1);
