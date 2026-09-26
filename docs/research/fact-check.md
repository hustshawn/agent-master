FACT-CHECK: Muse agent research claims (re-verified 2026-09-26 with curl, the GitHub API and PyPI; the WebFetch/WebSearch tools were not used)

Which Muse
1. There are two Meta Muse products: the consumer personal agent "Muse" (launched 2026-09-08, codename "Hatch") and the terminal coding agent "Muse Code" (beta 2026-08-05, powered by Muse Spark 1.2). → CONFIRMED.
   Sources: https://research.meta.ai/blog/introducing-muse-code-and-muse-spark-1-2 (dated Aug 5, 2026, "terminal coding agent powered by Muse Spark 1.2"); https://research.meta.ai/blog/security-and-safety-for-ai-agents-our-approach-with-muse ("Hatch is our internal name for Muse in the codebase"); https://techcrunch.com/2026/09/23/everything-new-coming-to-metas-ai-agent-muse/
   Your local superpowers 6.4.1 plugin targets Muse Code. Checked in /Users/shawn/.claude/plugins/cache/claude-plugins-official/superpowers/6.4.1/: `.muse-plugin/plugin.json` (schemaVersion 1, compat {source: native, manifestDir: .muse-plugin}), `references/muse-tools.md` (the tool mapping matches the findings) and `hooks/session-start` (MUSE_PLUGIN_ROOT, nested output "for Muse Spark"). → CONFIRMED.
   If "trending" means the consumer app, the answer is consumer Muse. If it means coding agents, it is Muse Code. The researchers mixed the two in places; see the contradictions at the end.

Muse Code: stack and distribution
2. Native Rust binary built in Meta's fbcode, internal codename "tbh". → CONFIRMED from the binary strings in /tmp/muse/strings.txt: "1.98.1" is present, `.rs` paths appear, `fbcode/musecode` has 123 hits, `tbh_agent` 25, crossterm 3, ratatui 0, V8 symbols 251.
   - The "clones" report said the language was unverified, which is now resolved.
   - "Custom renderer on crossterm, not ratatui" is still speculation.
3. Stable channel version 1.4.0-R4161.1, manifest served from lookaside.facebook.com. → CONFIRMED by a live GET of https://api.meta.ai/muse-code/channels/muse-stable.
   Install one-liners `curl -fsSL https://dev.meta.ai/install.sh | sh` and `irm https://dev.meta.ai/install.ps1 | iex`, including Windows support. → CONFIRMED at https://dev.meta.ai/docs/muse-code. The awesome-list claim of "no Windows" is out of date.
4. SDK and protocol. → CONFIRMED except the Python package name.
   - github.com/meta-models/muse-code-sdk is MIT-licensed.
   - npm `@muse-code/sdk` latest is 1.3.0.
   - The repo has `schema/msp/msp.d.ts` (134 KB), `stable/msp.schema.json` and 52 ndjson conformance transcripts.
   - Python name `muse_code` → REFUTED: it returns 404 on PyPI. The real packages are `muse-code-sdk` and `muse-code-msp`.
5. MSP wire types. → CONFIRMED by grepping msp.d.ts for:
   - ItemKind = userMessage | agentMessage | reasoning | toolCall | userShell | subagent | workflow | reminderChild | compaction
   - ApprovalMode values promptUnmatched and denyUnmatched
   - ifBusy with "replace"; turn/steer, turn/unqueue
   - subagent/followupTask, workflow/childControl, view/gap, userInput/clarify
   - llmJudge, judgeEscalated, protectedWrite, localPersistent, fallbackText, patchSummary, "ultra", sessionDurability, jsonrpc
6. Model API. → CONFIRMED at https://dev.meta.ai/docs/coding-agents:
   - Responses and Chat Completions at https://api.meta.ai/v1; Anthropic Messages at https://api.meta.ai
   - context 1048576
   - reasoningSummary "auto", include ["reasoning.encrypted_content"]
   Pricing $1.25 in / $4.25 out, contributor tier $0.10 / $0.20. → CONFIRMED at https://simonwillison.net/2026/Aug/5/muse-code-and-muse-spark-12/
   - "Output up to 256K" → REFUTED. The docs say output 131072 (128K), which is what the clones report had.
   - Muse Glimmer 30B → CONFIRMED on dev.meta.ai/docs/muse-glimmer: open weights, dense multimodal, 128K default context, trained from Muse Spark's outputs. The Apache-2.0 license was not checked.

Muse Code: agent mechanics
7. Main loop plus persistent background agents; an append-only event log that makes sessions replay-exact and restart-safe; co-trained on "rejection sampled harness trajectories". → CONFIRMED in the research blog.
   The four observers (memory recall, skill recall, goal tracking, verification) and the "proposes, reconciler decides" flow → CONFIRMED in the docs subpages, though not in the blog itself.
   How they are implemented as `plugin:tbh-reminders:{skill,goal,verify,scope}-reminder` agents calling `submit_reminder_decision` → CONFIRMED as names: the string has 75 hits in the binary.
   - The role-by-role prompt contents come from a third-party fixture (xhluca/session-migrate, Muse Code 0.2.1). I did not re-read them.
   - "scope-reminder" is a fifth reminder that is not among the four documented observers.
8. Subagents: 8 per tree by default, `agents.execution_capacity` 1–64, and "an unconfigured ultra root uses 64". → CONFIRMED in the docs.
9. Sandbox and permissions. → CONFIRMED in the docs:
   - Seatbelt on macOS, bundled bubblewrap on Linux, Windows sandbox with a UAC prompt.
   - Workspace and temp are writable; `.git`, `.muse` and `.agents` are read-only.
   - `--sandbox-network proxy-only` (the default) approves each new destination.
   - Auto-review is the default profile.
   - Deny overrides allow; interpreter prefixes (python, bash, node) can't be saved as a broad allow.
   - An `untrusted` approval mode exists.
   Nuance the reports flattened: `--disable-approval` keeps the sandbox on, while `--yolo` disables both approval and the sandbox and also trusts the workspace.
10. Hooks. → CONFIRMED with one contradiction.
    - The documented list has 15 events, including PreLLMCall and PostLLMCall; hooks live in `.muse/hooks.json`, user settings, or `managed_hooks_path`.
    - The "agent" report's PostToolBatch and StopFailure are not on the doc page I fetched, but they are in the binary (24 and 20 hits). The accurate statement is "15 documented events plus 2 in the binary, likely newer or undocumented" → UNCERTAIN.
11. Files and context. → CONFIRMED in the docs:
    - `settings.json` must contain "schema_version": 1
    - memory lives in `.agents/memory/MEMORY.md` plus one file per topic
    - skills are also read from `~/.claude/skills` and `$CODEX_HOME/skills` (falling back to `~/.codex/skills`)
    Session path contradiction:
    - The arch report says `~/.muse/sessions/...`.
    - The session-migrate docs say `$XDG_DATA_HOME/muse/sessions/YYYY/MM/DD/<uuid>/session.jsonl`, which is `~/.local/share` by default.
    - The official docs don't say → UNCERTAIN; the XDG location is more likely.
12. System prompt opens "You are Muse Code, an agentic coding CLI … powered by Muse Spark, a large language model trained by Meta MSL". → CONFIRMED in the binary strings and in /Users/shawn/Documents/workdir/muse-research/sysprompt.txt.
    - That contradicts the "agent" report's claim that the prompt "has not leaked". It is sanitized in the fixture but can be read from the binary.
    - The sizes "about 25 KB" and "about 32 KB" come from different versions/sources and weren't reconciled.
    Gateway paths `/muse-code/{key,models,search,browser_open,feedback}`, OAuth client_id 1031625952748946 and the `x-meta-ai-gateway-session-id` header → CONFIRMED in the binary strings.

Muse Code: TUI (terminal UI)
13. Dark palette → CONFIRMED from the truecolor escape codes in /tmp/muse/cap_*.ansi (34 captures). Top colors: #676c74, #ccd3db, #8a9098, #5aa0ff, #8abeb7, #a6e3a1, #cdd6f4, #b5bd68, #263854 (background), #f38ba8.
    Glyphs ❯, ◆ and ⟩ and the cell text "◆ Edited app.py (+1 −1)" → CONFIRMED in the captures.
    - Caveat: these were rendered against a mock backend in Docker, so they are the Default dark theme only.
    - Light-theme hexes, the gold max-effort animation and the /workflows control room are from docs or unverified.
14. Interaction rules → CONFIRMED in the docs:
    - Enter steers the running turn, Alt+Enter queues for the next turn, Esc interrupts.
    - Alt+V is voice input; pasted images get `[Image #N]` labels.
    - `/side` with `/btw` as an alias.
    - Clarifying questions come as "one to three" with number keys, Space toggles multi-select, Tab adds a note.
    - A live one-line reasoning summary shows in the status row (on by default); the theme is set by `tui.terminal_background` / `/theme`.
    - Todo status: the captured tool schema uses `in_progress`, but the agent report's "inProgress" also appears. The model-facing tool uses `in_progress`; MSP may use camelCase → UNCERTAIN.

Consumer Muse
15. Security architecture → CONFIRMED in the security blog: systemd-nspawn cell with root mapped to an unprivileged host user, no io_uring, no CAP_SYS_PTRACE or CAP_NET_ADMIN; Unix sockets with SO_PEERCRED and peer ACLs; Sentinel; hatch-authd surrogate tokens; "tainted egress"; browser subagent sees an accessibility-tree snapshot, not the DOM; Stripe Link single-use cards; Confidential VM "coming soon".
    - The security blog says Shop Pay was "coming soon" at launch. TechCrunch on Sep 23 says it is now added, so the two sources are consistent.
16. Consumer UI tokens → CONFIRMED only in the marketing page CSS at introducing.muse.ai, not the app: #0064d4, #1793ff, #fcfcfc, #111112, #181819, #00040996, #0000001a, 999px, font "Optimistic".
    - The page names Veda and the author Sarantakos. "Jolly" comes from TechCrunch quoting Zuckerberg, not the design page.
    - Connect announcements (the "centerpiece" quote, 1,500+ connector applications, Muse Realtime Avatar, PayPal, computer-use on Mac "in the coming months") → CONFIRMED on TechCrunch.

Third-party repos (GitHub API)
- CONFIRMED to exist: helicon (60 stars, MIT, TS), BrokkAi/muse-acp (Rust), bex-co/muse-code-acp (TS), ibchouti9/openmuse, xhluca/muse-code-openrouter, luckeyfaraday/muse-shim, session-migrate (114 stars), and wch887292/feihong-code (describes itself as "对标 Muse Code", i.e. modelled on Muse Code).
- xai-org/grok-build (27,104 stars, Rust, Apache-2.0) and openai/codex (126,509 stars) → CONFIRMED.
- guac-build as "the closest thing to a replica" → misleading. It has 1 star and describes itself as a "Muse Spark 1.1 coding agent forked from Grok Build", so it is a model swap, not a Muse Code clone.
- rome-os/rome as an "open alternative to Muse" → UNCERTAIN. Its description mentions "Grok Bot" and the rest was truncated.
- Muse Code borrowing from Codex's design is speculation.

Unverified or open
- Consumer pricing tiers and the "100M tokens/week" figure (third-party site only).
- Muse Code subscription prices.
- Full tool JSON schemas: /tmp/muse/tools.txt exists but the schemas are truncated.
- The workflow-engine JavaScript API.
- Whether the consumer app uses the same tokens as the marketing page.

Useful local artifacts: /tmp/muse/strings.txt, /tmp/muse/cap_*.ansi, /Users/shawn/Documents/workdir/muse-research/sysprompt.txt, and /tmp/msp.d.ts (freshly downloaded). Everything in /tmp is temporary, so copy what you want to keep.