#!/usr/bin/env node

const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const root = path.join(__dirname, "..");
const dist = path.join(root, "dist");
const exe = process.platform === "win32" ? "irelay.exe" : "irelay";
const output = path.join(dist, exe);

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function sleep(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

// 平台检测
if (process.platform !== "darwin") {
  console.error("@xdfnet/irelay currently supports macOS only.");
  process.exit(1);
}

// 编译 Go 二进制
const goCheck = spawnSync("go", ["version"], { stdio: "ignore" });
if (goCheck.status !== 0) {
  console.error("iRelay requires Go to build during npm install.");
  console.error("Install Go from https://go.dev/dl/ and run npm install again.");
  process.exit(1);
}

ensureDir(dist);
const result = spawnSync("go", ["build", "-o", output, "./cmd/irelay"], {
  cwd: root,
  stdio: "inherit",
});

if (result.status !== 0) {
  process.exit(result.status ?? 1);
}

// macOS: 配置文件和 launchd 自启动
const home = os.homedir();
const binDir = path.join(home, ".local", "bin");
const binaryPath = path.join(binDir, "irelay");
const configDir = path.join(home, ".config", "irelay");
const configPath = path.join(configDir, "config.json");
const plistDir = path.join(home, "Library", "LaunchAgents");
const plistPath = path.join(plistDir, "com.user.irelay.plist");

ensureDir(binDir);
ensureDir(configDir);
ensureDir(plistDir);

// 安装二进制到 ~/.local/bin/
fs.copyFileSync(output, binaryPath);
fs.chmodSync(binaryPath, 0o755);

// 首次安装创建示例配置
let isNewConfig = false;
if (!fs.existsSync(configPath)) {
  fs.writeFileSync(configPath, JSON.stringify({
    apiKey: "",
    upstream: "https://api.deepseek.com"
  }, null, 2) + "\n");
  isNewConfig = true;
  console.log("[irelay postinstall] 配置文件已创建: " + configPath);
}

const plistContent = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.irelay</string>
    <key>ProgramArguments</key>
    <array>
        <string>${binaryPath}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${configDir}/irelay.log</string>
    <key>StandardErrorPath</key>
    <string>${configDir}/irelay_error.log</string>
</dict>
</plist>
`;
fs.writeFileSync(plistPath, plistContent);
spawnSync("launchctl", ["unload", plistPath], { stdio: "ignore" });
spawnSync("launchctl", ["load", "-w", plistPath], { stdio: "ignore" });

// 等待服务启动
let healthy = false;
for (let i = 0; i < 30; i++) {
  sleep(200);
  try {
    const check = spawnSync("curl", ["-s", "-o", "/dev/null", "-w", "%{http_code}", "http://localhost:8787/health"], { encoding: "utf8" });
    if (check.status === 0 && check.stdout === "200") {
      healthy = true;
      break;
    }
  } catch (_) {}
}

console.log(healthy ? "[irelay postinstall] 服务已启动" : "[irelay postinstall] 服务启动中，请稍后检查 irelay status");

// 检查 API Key
if (isNewConfig) {
  console.log(`
⚠️  未配置 DeepSeek API Key，请编辑：
  open ~/.config/irelay/config.json
然后重启：
  irelay restart
`);
} else {
  try {
    const cfg = JSON.parse(fs.readFileSync(configPath, "utf8"));
    if (!cfg.apiKey) {
      console.log(`
⚠️  API Key 为空，请编辑：
  open ~/.config/irelay/config.json
然后重启：
  irelay restart
`);
    }
  } catch (_) {}
}
