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

// 编译 Go 二进制
ensureDir(dist);
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

// macOS: 配置文件和 launchd 自启动
if (process.platform === "darwin") {
  const home = os.homedir();
  const configDir = path.join(home, ".config", "irelay");
  const configPath = path.join(configDir, "config.json");
  const plistDir = path.join(home, "Library", "LaunchAgents");
  const plistPath = path.join(plistDir, "com.user.irelay.plist");

  ensureDir(configDir);
  ensureDir(plistDir);

  // 首次安装创建示例配置
  if (!fs.existsSync(configPath)) {
    fs.writeFileSync(configPath, JSON.stringify({
      apiKey: "",
      upstream: "https://api.deepseek.com"
    }, null, 2) + "\n");
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
        <string>${output}</string>
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
  spawnSync("launchctl", ["load", "-w", plistPath], { stdio: "ignore" });
  console.log("[irelay postinstall] 开机自启已设置");
}
