## Delegation mechanics (Codex)

The sub-agents are Codex custom agents defined in `~/.codex/agents`, one TOML file per agent. Delegate to one by asking for it by name, for example: "Use the jarvis-coder agent to implement ...". Each sub-agent runs with its own instructions, and the coding rules it needs are already inlined into them.

The rules are not loaded into your own context. When you edit code yourself, first read the rules from the index below that apply to the change.
