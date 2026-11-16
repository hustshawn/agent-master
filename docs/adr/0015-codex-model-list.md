# 0015 Codex 和 Kiro 的默认模型从 CLI 自己的模型列表里选

- 日期：2026-11-16
- 状态：已接受（2026-11-16）
- 前置：ADR 0009（Codex）、0010（适配层）、0012（Kiro）

## 背景

ADR 0009 和 0012 里 Codex、Kiro 的 Default model 只有"跟随"和自定义，因为它们没有 Claude Code 那样固定的别名，能用哪些
模型看账号和 provider，写死一份列表一定会错。用户在 Settings 里看不到可选的模型，只能自己去查 id 再手填。

codex 0.166 的 `codex debug models` 会把当前 provider 的模型目录打印成 JSON，本地约 1 秒，不需要额外登录。每个模型有
`slug`（就是 `--model` 要的 id）、`display_name` 和 `visibility`，codex 自己的模型选择器只列 `visibility` 为 `list` 的。
在接 Bedrock 的配置上实测，列出 16 个模型，例如 `global.openai.gpt-6.1-sol`（GPT-6.1 Sol (Global)）。

kiro-cli 3.3 的 `kiro-cli chat --list-models --format json` 列出账号可用的模型，约 2 秒：每个有 `model_id`、`model_name`
（实测与 id 相同）、`description` 和计费倍率，另有 `default_model`（`auto`）。实测 22 个，`--v2` 和 `--v3` 列出的相同。
没登录时它在 stderr 提示 "Not logged in"，stdout 为空。

## 决策

- `AgentKind` 增加 `modelChoices(environment:)`：agent 的 CLI 列出的模型，默认 nil。`CodexAgent` 跑 `codex debug models`，
  取 `visibility` 为 `list` 的模型，显示名在前、id 作为 detail；`KiroAgent` 跑 `kiro-cli chat --list-models --format json`，
  id 在前、描述作为 detail。两者共用 `CommandOutput`（10 秒超时，退出码非 0 算失败）；跑不出来、读不懂或列表为空时返回 nil。
- `options(environment:models:)` 把这份列表换进默认模型的选项，仍然允许自定义；列表为 nil 时和原来一样只能手填。
  Settings、新建会话面板和 Web 版都经过它。
- 读一次、缓存到退出：Mac 版在拿到登录 shell 的环境、恢复完会话之后在后台读；服务器在启动时读，`Configuration`
  可以直接传入 `modelCatalog`，测试用它避免跑本机真的 codex。

## 后果

- 改了 `~/.codex/config.toml` 的 provider、登录或退出 Kiro，或者模型列表变了，要重启 AgentMaster 才会更新。
- `codex debug` 是调试命令，输出格式可能随版本变；变了就读不出列表，退回只能手填，启动会话不受影响。Kiro 没登录时同样退回手填。
- 列表只换模型的选项。Codex 各模型支持的 effort 和 speed（目录里的 `supported_reasoning_levels`、`service_tiers`）、
  Kiro 的计费倍率都没有用上。
