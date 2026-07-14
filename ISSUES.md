# ISSUES

Running list of friction, footguns, and small fixes surfaced during agento work. Newest at the top. Mark resolved with `~~strikethrough~~` and a one-line note.

---

## 2026-07-14 — PRD compliance audit (PRD-PHOENIX-UI.md)

Audited the codebase against PRD-PHOENIX-UI.md: **28 of 39 requirements MET, 11 PARTIAL, 0 fully MISSING.** Every requirement group is functional end-to-end; the partials below are refinements plus one deliberate deviation. Priority order top to bottom.

### R6.3 — Manual tool invocation is completely ungated (security)

`/tools` renders a form that JSON-decodes args and calls `module.perform(action, args)` on any registered tool, for any visitor, with no gate (`lib/agento_web/live/tools_live.ex:63-87,158-193`). The PRD explicitly requires gating this debug write-path behind a config flag or admin role. Auth is out of scope for v1, so the intended fix is a flag.

**DEFER** -- we can defer this and accept the security risk while we develop the features between what we have now and when we have auth by simply gating release on auth functionality.

**Planned Fix:** Implement users, authentication, and authorization.  Use `Application.compile_env(:agento, :enable_tool_invocation, false)`; hide the invocation card and reject the `invoke_tool` event unless enabled if required to move forward without auth.

### R2.1 / R2.3 / VA3 — `llm_client` and `memory` dimension is unwired

One root cause, three symptoms:

- **R2.1** — start-agent form has no `llm_client` (default OpenAI) or `memory` (default ETS) dropdown; `start_agent` opts never pass them (`lib/agento_web/live/chat_live.ex:155-160,500-538`).
- **R2.3** — config view omits `llm_client` and `memory` modules (`lib/agento_web/live/chat_live.ex:471-498`). Blocked upstream: `LLMAgent.AgentSupervisor.list_agents_with_state/0` (`llmagent/lib/llmagent/agent_supervisor.ex:81-88`) returns only name/role/model/api_host/history_length.
- **VA3** — `AgentoWeb.Discovery.Behaviours.llm_clients/0` and `memory_backends/0` already scan for implementations (`lib/agento_web/discovery/behaviours.ex:12-25`) but are never consumed.

**Fix:** wire the existing discovery funcs into the form; extend `list_agents_with_state/0` upstream (or read `:sys.get_state`) to surface the two modules for R2.3.

### R1.5 — Tool-dispatch visibility: stale skipped test, heuristic correlation, unsanitized args

- The R1.5 integration test is `@tag :skip` with a comment citing a `get_in(@event, [:data, :tool])` Access bug that **no longer exists** — the render uses direct `@event.data[:tool]` access (`lib/agento_web/live/chat_live.ex:427`). The skip is stale; re-enable/rewrite the test (`test/agento_web/live/chat_live_test.exs:7,136-153`).
- Tool events carry no `agent_id`, so they are attributed to the selected agent by a `thinking`-state heuristic (`chat_live.ex:569,581`) rather than a true per-agent filter.
- PRD says "args (sanitized)"; args are rendered via raw `inspect(@event.data)`.

**FIX:** re-enable the test, add `agent_id` and Comn.Context to tool events, and sanitize args before rendering.

### R7.2 / R3.2 / R4.3 — Views only know about *running* agents, not history

Agents that ran and stopped are invisible in three places:

- **R7.2** — DurableLog agent selector derives only from `Agents.list()` (`lib/agento_web/live/system_live.ex:829-834`); should enumerate agent_ids from the DETS log.
- **R3.2** — event-explorer agent-ID dropdown uses only agent_ids *seen in events* (`lib/agento_web/discovery/events.ex:75-81`), never merged with running agents.
- **R4.3** — supervision tree labels agent children `"undefined"` because agents run unregistered under the DynamicSupervisor; the PRD wants the name "extracted from state" via `:sys.get_state(pid).name` (`lib/agento_web/live/system_live.ex:686,709-718`).

**Fix:** merge running and historical agent_ids in all three places; use `:sys.get_state` to label supervision tree children.

### R3.1 — Event stream: non-functional auto-scroll, no per-row collapsible payload

`lib/agento_web/live/events_live.ex`: the auto-scroll toggle flips `@auto_scroll` and restyles the button but drives no scroll behavior (`:307-316,77-79`; the `#event-stream` div has no `phx-hook`). The `data` map is only reachable via the detail sidebar — no per-row collapse (`:340`). Also EventLog-tab rows have no `phx-click`, so the R3.5 detail view is unreachable from that tab (`:485-491`).

**Fix:** add a `phx-hook` to scroll the div when `@auto_scroll` is true; add a per-row collapse toggle and detail view link.

### R3.2 — Event filters: time-range picker missing

No date-time field in the filter form and no time filtering in `filtered_events/4` (`lib/agento_web/live/events_live.ex:278-302,530-564`).

**Fix:** add a date-time picker to the form and filter events by timestamp.

### R5.3 — Error catalog listed flat, not grouped by category

Per-event category labels are computed via `Comn.Errors.categorize/1` (`lib/agento_web/live/system_live.ex:800-806`) and rendered as a flat list (`:426-439`). PRD wants events *grouped/aggregated by category* with per-category counts.

**Fix:** group by category and render counts.

### VA2 — Topic discovery is static for `agent.*` / `web.*`

`event_bus_bridge.ex:21-34` and `discovery/events.ex:11-17` hold hardcoded topic seed lists. Only `tool.*` topics are discovered dynamically (`event_bus_bridge.ex:100-107`). `LLMAgent.EventBus.subscribe/1` takes exact topics (no wildcard), so a newly emitted `agent.*`/`web.*` type not in the seed is never subscribed. Meets the spirit for tools; falls short of "does not maintain a static list."

**Fix:** add a `:topic` field to the `event` struct and subscribe to all topics; filter in the event stream.

### R2.1 deviation — endpoint dropdown replaced model/api_host text fields (intentional)

PRD R2.1 lists `model` and `api_host` as text fields; they were replaced by the mDNS-discovered endpoint dropdown plus a `local` fallback (`lib/agento_web/live/chat_live.ex:519-530`). This supplies both values and is a UX improvement, but removes free-form entry. Decision needed: keep the dropdown and optionally add a manual-override option.

**Fix** add a "manual entry" option to the dropdown that reveals the text fields.
---

## 2026-06-14 things I noticed while working on the PRD audit

### make sure we're tracking the changes upstream in 'comn' and 'busybody' and integrating them into agento as appropriate.

### update the readme to reflect that busybody is a dependency and that can eliminate the need for env vars for the most part.

### we aren't passing any context to the llm, so it doesn't know about tools or the system prompt.  We should be passing the context to the llm so it can make better decisions about what to do.


## 2026-05-03

### ~~`LLMAGENT_ROLE` defaults to `sysadmin`, which is the most rigid role~~

**Resolved** — `config/runtime.exs:27` now defaults to `default` (commit `865e38c`).

`llmagent_web/config/runtime.exs:27` sets the default role to `sysadmin`. That role's prompt (`llmagent/lib/prompts/sysadmin.ex:30`) ends with `Return only valid JSON. Do not explain.` — so small models like `llama3.2` reply to chitchat ("hello?") with hallucinated tool-call JSON or fake error envelopes. Counter-intuitive: the name suggests "general-purpose default."

**Fix candidates:**

- Change runtime default to `default`.
- Better: surface role descriptions in the new-agent form (per PRD R2.1, dropdown from `LLMAgent.RolePrompt` introspection).

### Sysadmin role prompt has no escape hatch for prose

`llmagent/lib/prompts/sysadmin.ex` instructs JSON-only output with no rule for "if no tool needed, reply in prose." Even a capable model will hallucinate tool calls for conversational input.

**Fix:** add a clause like `When no tool is needed (greetings, clarifications, self-questions), reply in plain prose.` Lives in the `llmagent` repo, not agento.

### ~~New-agent form takes role as free-form text~~

**Resolved** — role is now a dropdown introspected from `LLMAgent.RolePrompt.roles/0` (`lib/agento_web/live/chat_live.ex:511-518,666-672`).

`llmagent_web/lib/llmagent_web_web/live/chat_live.ex` `start_agent` form has a text input for `role`. PRD R2.1 calls for a dropdown introspected from `LLMAgent.RolePrompt`. Currently you have to know role atoms exist and spell them right.
