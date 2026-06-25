# iRelay

[![Build](https://github.com/xdfnet/iRelay/actions/workflows/build.yml/badge.svg)](https://github.com/xdfnet/iRelay/actions/workflows/build.yml)
![macOS](https://img.shields.io/badge/macOS-14.0+-brightgreen)
![Swift](https://img.shields.io/badge/Swift-5.9+-orange)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

> 纯原生 macOS 菜单栏 App — Codex ↔ DeepSeek 本机中转服务。
>
> 纯 Swift 实现，**零外部依赖**。服务随 App 启停，无需手动管理。

## 功能

| 功能 | 说明 |
|------|------|
| 代理开关 | 配置 Codex 使用 iRelay 中转，默认使用 DeepSeek V4 Pro |
| 补丁开关 | 独立修补 Codex 桌面版模型白名单过滤，与代理解耦 |
| 权限检查 | 操作前检测 App 管理权限，未授权弹窗引导 |
| 数据流指示 | 菜单栏图标在有请求流经时闪烁，实时反映中转服务活跃状态 |
| 模型重写 | 非 DeepSeek 模型自动转成已配置的 DeepSeek 模型 |
| API Key | 窗口配置 DeepSeek API Key |
| 端口固定 | 固定 `8787`，即开即用 |
| 模型元数据 | 自动为 Codex 提供完整模型信息，消除 fallback 警告 |
| Chat 透传 | 额外提供 `/v1/chat/completions` 直通接口 |

## 要求

- macOS 14+
- Xcode 15+ 或 Swift 5.9+

## 安装

### 从 GitHub Releases 下载（推荐）

```bash
curl -sL https://github.com/xdfnet/iRelay/releases/latest/download/iRelay.zip -o /tmp/iRelay.zip
unzip -qo /tmp/iRelay.zip -d /Applications
open /Applications/iRelay.app
```

或一条命令：

```bash
bash <(curl -sL https://raw.githubusercontent.com/xdfnet/iRelay/main/install.sh)
```

> ⚠️ 首次运行需右键 `iRelay.app` → **打开**（未签名应用 Gatekeeper 拦截）

### 从源码构建

```bash
# 需要 Xcode 15+ 或 Swift 5.9+
git clone https://github.com/xdfnet/iRelay.git
cd iRelay
swift run                    # 开发调试
./build.sh                   # 构建正式包
open iRelay.app               # 启动
```

## 使用

1. 启动 iRelay，点击菜单栏图标 → **设置密钥** → 输入 DeepSeek API Key
2. 点击 **开启补丁** → 授权 App 管理权限 → 修补 Codex 模型白名单
3. 点击 **开启代理** → 配置 Codex 使用 iRelay 中转
4. 开关代理、打补丁等均在菜单栏操作

首次使用后重启 Codex，它会自动从 iRelay 获取模型列表。

完整 API 参考见 [Doc/API.md](Doc/API.md)。

## 架构

```
NSStatusItem (AppKit)
  ├─ 开启/关闭代理 / 开启/关闭补丁 / 配置 / 退出
  ├─ RelayState     — 全局状态（apiKey / model / thinking / isCodexPatched）
  │   └─ UserDefaults 持久化 + 模型列表缓存
  ├─ CodexConfigManager — ~/.codex/config.toml
  │   ├─ 写入 model_catalog_json，让 Codex 正确识别 DeepSeek 模型
  │   └─ CodexAppPatcher — 修补桌面 App 模型白名单过滤
  └─ HTTPServer         — 内嵌 HTTP 服务器
      └─ RelayHandler   — 路由 + 协议转换
          └─ ChatClient — Chat Completions API 客户端
```

- **HTTPServer**: 基于 Network.framework (NWListener)，零外部依赖
- **RelayHandler**: 路由 `/health` `/v1/models` `/v1/responses` `/v1/chat/completions`，协议转换
- **ChatClient**: URLSession + async/await，支持流式 SSE
- **CodexConfigManager**: 配 Key/切模型时写入 `model_provider = "iRelay"`、当前模型、`model_catalog_json`；关模型时清理

## 目录结构

```
Sources/iRelay/
├── iRelayApp.swift              # @main 入口，API Key 配置窗口
├── MenuBarController.swift      # NSStatusItem 菜单栏（代理/补丁/配置）
├── Models/
│   └── RelayState.swift         # @Observable 全局状态
├── Services/
│   ├── CodexConfigManager.swift # ~/.codex/config.toml 和模型 catalog 管理
│   └── CodexAppPatcher.swift    # Codex 桌面 App 模型菜单补丁
└── Core/
    ├── HTTPServer.swift         # 内嵌 HTTP 服务器 (NWListener)
    ├── RelayHandler.swift       # 路由分发 + 协议转换 + Chat 透传
    └── ChatClient.swift         # Chat Completions API 客户端
```

## Codex 桌面 App 适配

Codex 桌面 App 前端会读取远端 Statsig 模型白名单。某些版本中白名单只包含 `gpt-*` 模型，并启用了 `use_hidden_models`，导致 iRelay 提供的 `deepseek-v4-pro` / `deepseek-v4-flash` 被过滤，模型菜单显示为空。

iRelay 提供独立的「开启补丁/关闭补丁」菜单项，修补 Codex 桌面版前会先检测 `App 管理`权限，未授权则弹窗引导。

补丁方式是等长替换前端过滤表达式，避免依赖 `npx asar` 或其他外部工具。每次修补前会重新备份（删旧→建新），保证备份始终对应当前 Codex 版本。

补丁与代理完全解耦：关闭代理不会还原补丁，关闭补丁也不会影响代理配置。

## 许可证

MIT
