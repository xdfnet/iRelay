#!/usr/bin/env node
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const root = path.join(__dirname, "..");
const dist = path.join(root, "dist");
const exe = process.platform === "win32" ? "irelay.exe" : "irelay";
const output = path.join(dist, exe);

if (process.platform !== "darwin") {
  console.error("@xdfnet/irelay currently supports macOS only.");
  process.exit(1);
}

const goCheck = spawnSync("go", ["version"], { stdio: "ignore" });
if (goCheck.status !== 0) {
  console.error("iRelay requires Go to build during npm install.");
  console.error("Install Go from https://go.dev/dl/ and run npm install again.");
  process.exit(1);
}

const pkg = require(path.join(root, "package.json"));

fs.mkdirSync(dist, { recursive: true });
const result = spawnSync("go", ["build", "-ldflags", `-s -w -X main.version=${pkg.version}`, "-o", output, "./cmd/irelay"], {
  cwd: root,
  stdio: "inherit",
});
if (result.status !== 0) {
  process.exit(result.status ?? 1);
}

const home = require("node:os").homedir();
const binDir = path.join(home, ".local", "bin");
fs.mkdirSync(binDir, { recursive: true });
fs.copyFileSync(output, path.join(binDir, "irelay"));
fs.chmodSync(path.join(binDir, "irelay"), 0o755);

console.log(`\n  ✅ iRelay v${pkg.version} 已安装`);
console.log("  首次使用运行: irelay setup");
console.log("  升级后重启:   irelay restart");
