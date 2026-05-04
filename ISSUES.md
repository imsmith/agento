# ISSUES

Running list of friction, footguns, and small fixes surfaced during agento work. Newest at the top. Mark resolved with `~~strikethrough~~` and a one-line note.

---

## 2026-05-03

### `LLMAGENT_ROLE` defaults to `sysadmin`, which is the most rigid role

`llmagent_web/config/runtime.exs:27` sets the default role to `sysadmin`. That role's prompt (`llmagent/lib/prompts/sysadmin.ex:30`) ends with `Return only valid JSON. Do not explain.` — so small models like `llama3.2` reply to chitchat ("hello?") with hallucinated tool-call JSON or fake error envelopes. Counter-intuitive: the name suggests "general-purpose default."

**Fix candidates:**

- Change runtime default to `default`.
- Better: surface role descriptions in the new-agent form (per PRD R2.1, dropdown from `LLMAgent.RolePrompt` introspection).

### Sysadmin role prompt has no escape hatch for prose

`llmagent/lib/prompts/sysadmin.ex` instructs JSON-only output with no rule for "if no tool needed, reply in prose." Even a capable model will hallucinate tool calls for conversational input.

**Fix:** add a clause like `When no tool is needed (greetings, clarifications, self-questions), reply in plain prose.` Lives in the `llmagent` repo, not agento.

### New-agent form takes role as free-form text

`llmagent_web/lib/llmagent_web_web/live/chat_live.ex` `start_agent` form has a text input for `role`. PRD R2.1 calls for a dropdown introspected from `LLMAgent.RolePrompt`. Currently you have to know role atoms exist and spell them right.
