#!/usr/bin/env node

const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const root = path.join(__dirname, "..");
const dist = path.join(root, "dist");
const exe = process.platform === "win32" ? "irelay.exe" : "irelay";
const output = path.join(dist, exe);

fs.mkdirSync(dist, { recursive: true });

const result = spawnSync("go", ["build", "-o", output, "./cmd/irelay"], {
  cwd: root,
  stdio: "inherit",
});

if (result.error) {
  console.error("iRelay requires Go to build during npm install.");
  console.error("Install Go from https://go.dev/dl/ and run npm install again.");
  process.exit(1);
}

if (result.status !== 0) {
  process.exit(result.status ?? 1);
}
