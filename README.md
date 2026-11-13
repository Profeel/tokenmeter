# ⚡ TokenMeter

**原生 macOS 菜单栏 AI Coding 消耗仪表盘 + 终端 CLI**（KeepLid 姊妹项目）。

零侵入、纯本地、无需额外依赖——自动聚合本机所有 AI Coding Agent 的真实 Token 消耗、缓存命中率、估算费用，并实时探测上游中转站 / 本地推理端点的可用性、延迟与 429 限流状态。

---

## ✨ 核心特性

1. **跨 Agent 本地账本（100% 离线只读解析，零隐私上传）**
   - **Hermes Agent**（`~/.hermes/state.db` 与多 Profile `~/.hermes/profiles/*/state.db`）
   - **Codex CLI**（`~/.codex/sessions/**/*.jsonl` 与 `archived_sessions`，自动去重累计快照）
   - **Claude Code**（`~/.claude/projects/**/*.jsonl`，按 `message.id` 流式去重）
   - **Pi Agent**（`~/.pi/**/*.jsonl`）
   - **OpenCode**（`~/.local/share/opencode/opencode.db`）
2. **上游网关 & 本地模型健康探针**
   - 自动发现本机配置的网关与本地端点（OneAPI、NewAPI、本地代理端口、MTPLX、Ollama 等，**绝不读取或暴露 API Key**）
   - 实时监测 HTTP 状态、响应延迟（ms）、模型数量与 **429 限流告警**
   - 可选配置 OneAPI / NewAPI 账单 Token（`~/.tokenmeter/config.json`），直接在菜单栏显示剩余美元额度
3. **双形态原生体验**
   - **SwiftUI 菜单栏常驻 App (`TokenMeter.app`)**：状态栏实时显示 `⚡ 2.4M · $1.82`，左键弹出今日/7天/30天看板、趋势柱状图、模型与端点明细
   - **终端 CLI (`tokenmeter`)**：支持 `--json` 输出，方便接入脚本或其他 Agent 调用

---

## 🚀 安装与部署

### 方式一：源码一键编译安装（推荐）

```bash
git clone https://github.com/Profeel/tokenmeter.git ~/tokenmeter
cd ~/tokenmeter
./scripts/install.sh
```

### 方式二：下载 Release 预编译包

前往 [Releases](https://github.com/Profeel/tokenmeter/releases) 下载 `TokenMeter-v1.0.0-macos-arm64.zip`，解压后将 `TokenMeter.app` 拖入 `/Applications/`，`tokenmeter` 放入 `~/.local/bin/`。

安装完成后：
- **菜单栏应用**：`open /Applications/TokenMeter.app`（或在 Spotlight 搜索 `TokenMeter`）
- **命令行工具**：
  ```bash
  tokenmeter status          # 今日消耗汇总 + 上游端点健康探针
  tokenmeter week            # 最近 7 天消耗与模型排行
  tokenmeter models 30d      # 最近 30 天 Top 模型明细
  tokenmeter probe           # 探测所有自动发现端点的延迟与 429 状态
  tokenmeter status --json   # JSON 输出供脚本或 Agent 消费
  tokenmeter watch           # 终端实时刷新监控看板
  tokenmeter init-config     # 生成 ~/.tokenmeter/config.json
  ```

---

## ⚙️ 可选配置 (`~/.tokenmeter/config.json`)

```json
{
  "dailyBudgetUSD": 20.0,
  "budgetAlertRatio": 0.8,
  "oneAPIAccounts": [
    {
      "name": "OneAPI 主站",
      "baseURL": "https://ai.example.com",
      "accessToken": "your-read-only-system-token",
      "userId": 1
    }
  ]
}
```
