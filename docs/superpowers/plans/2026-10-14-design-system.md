# Design System Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-skin agento's six LiveViews and home page to the GRID·OPS design system through gos-ui, removing daisyUI and heroicons, with no behavior change and the web test suite green at every commit.

**Architecture:** Three repos in dependency order. design-system gains nine UI marks; gos-ui re-syncs and is pinned by commit; agento swaps its root layout and app shell to gos-ui, remaps Tailwind 4 to design-system tokens as a layout-only utility layer, then migrates one view per commit with both stylesheets coexisting until the final removal commit.

**Tech Stack:** Elixir 1.20 / Phoenix 1.8 / LiveView 1.1, Tailwind 4.1 (utilities only, no preflight), gos-ui 0.1 (GitHub dep), design-system tokens (edn → CSS custom properties), Tcl generators in design-system.

**Spec:** `docs/superpowers/specs/2026-10-14-design-system-design.md`

## Global Constraints

- Work on branches: design-system `marks-agento`, gos-ui `sync-marks`, agento `design-system`. Never push. Never rewrite history. Never `git stash` bare.
- agento is built and tested in `/home/imsmith/github/agento` directly, not a worktree (its `../llmagent` path dep).
- agento tests run serially (shared DETS). Always `mix test ... > /tmp/agento-test.log 2>&1; tail -5 /tmp/agento-test.log`. Never pipe `mix test` into `tail` or `head`.
- Every `mix test` for agento uses `MIX_ENV=test`. Run `mix assets.build` before any test that renders CSS-dependent markup is eyeballed; tests themselves do not need built assets.
- Theme default: `tron` dark. localStorage keys: `gos:theme`, `gos:mode`. Attributes: `data-theme`, `data-mode` on `<html>`.
- Status lexicon for display words: critical→DOWN, high→ALERT, medium→WARN, low→OK, unknown→UNK.
- Copy shape for alerts and errors: what happened · why (if known) · what to do.
- Tailwind spacing base becomes `--spacing: 0.5rem` (was 0.25rem). **Every numeric spacing utility halves when a template is migrated**: `p-4`→`p-2`, `p-3`→`p-1.5`, `p-2`→`p-1`, `gap-2`→`gap-1`, `gap-4`→`gap-2`, `mb-2`→`mb-1`, `mb-1`→`mb-0.5`, `space-y-2`→`space-y-1`, `w-64`→`w-32`, `w-72`→`w-36`, `w-96`→`w-48`, `w-44`→`w-22`, `max-w-32`→`max-w-16`, `size-12`→`size-6`.
- Color utilities after remap: `bg-bg`, `bg-surface`, `bg-surface-raised`, `text-text`, `text-muted`, `text-accent`, `border-border`, `text-status-critical` etc. Nothing else exists.
- Text size utilities after remap: `text-micro`, `text-caption`, `text-small`, `text-body`, `text-lead`, `text-h3`, `text-h2`, `text-h1`. Weight: `font-regular`, `font-medium`, `font-bold`.
- Radius: `rounded-sm` (2px), `rounded-md` (4px), `rounded-lg` (6px). Nothing rounder.
- Forbidden in `lib/agento_web` after Task 15: any daisyUI class, `hero-`, `bg-base-`, `text-base-content`, `text-xs`, `text-sm`, `text-lg`, `text-xl`, `font-semibold`, `rounded-full`, `opacity-`.
- Mark ids are the only icon vocabulary. New marks: `m-chat m-event m-system m-tool m-hub m-agent m-run m-send m-external`.
- gos-ui's `select` takes `options` as a list of strings or `{label, value}` tuples; a prompt option goes in its inner block. `input`, `select`, `textarea` pass `name` through, so existing test selectors by `name` keep working.
- gos-ui `card` body is the default slot, title via `title=` attr, actions via `<:actions>`.
- Phoenix tests select by `phx-click`/`phx-submit`/`name`/`id`, never by class. Keep every `phx-*` attribute and every `id` exactly as it is today.

## Review Focus

1. **Theme persistence across live navigation.** A user picks compaq/light, clicks Events in the nav. Expect: page stays compaq/light and both selects show compaq/light. Pinned by Task 5 step 8.
2. **Flash after the toast swap.** A failed agent start puts an `:error` flash. Expect: a visible critical toast that persists until dismissed, with the message text. Pinned by Task 5 step 6.
3. **Form field names after wrapping in gos-ui controls.** `form("form[phx-submit=start_agent]", %{"endpoint" => "manual"})` must still find `select[name=endpoint]`. Pinned by the unchanged chat tests in Task 9 and the assertion in Task 9 step 5.
4. **Rows without `:id` in gos-ui `table`.** Hub turns and rules trace rows have no `:id` key; gos-ui's default `row_id` reads `r[:id]` and returns nil, which is fine without `on_select` but must not raise for structs. Pinned by Task 7 step 4 (turns are maps) and Task 8 step 4.
5. **Dark glow on light mode.** `data-mode="light"` must suppress text-shadow on the brand. This is enforced by the design-system stylesheet, not agento; visually confirmed in Task 5 step 9. No agento test.

---

### Task 1: Nine UI marks in design-system

**Files:**
- Modify: `/home/imsmith/github/design-system/tokens/marks.edn` (the `:ui` vector, after the `m-bell` entry)
- Modify: `/home/imsmith/github/design-system/assets/marks/sprite.svg` (before the closing `</svg>`)
- Modify: `/home/imsmith/github/design-system/manual/04-marks-iconography.md` (section 4)

**Interfaces:**
- Produces: sprite symbol ids `m-chat m-event m-system m-tool m-hub m-agent m-run m-send m-external`, consumed by gos-ui `<.mark name=...>` after Task 2.

- [ ] **Step 1: Branch**

```bash
cd /home/imsmith/github/design-system && git status --short && git checkout -b marks-agento
```

Expected: clean tree, new branch.

- [ ] **Step 2: Write the failing check**

The registry and the sprite must agree. Add this to `tools/check.tcl` just before the final exit, so it becomes a permanent check (there is none today):

```tcl
# 4. every :id in marks.edn has a <symbol id=...> in the sprite, and vice versa
set edn [read [open tokens/marks.edn]]
set ids [lsort [lmap {_ id} [regexp -all -inline {:id\s+"(m-[a-z0-9-]+)"} $edn] {set id}]]
set svg [read [open assets/marks/sprite.svg]]
set syms [lsort [lmap {_ id} [regexp -all -inline {<symbol id="(m-[a-z0-9-]+)"} $svg] {set id}]]
if {$ids ne $syms} {
    puts "marks: registry/sprite mismatch\n  edn only: [lmap i $ids {expr {$i in $syms ? [continue] : $i}}]\n  svg only: [lmap s $syms {expr {$s in $ids ? [continue] : $s}}]"
    set failed 1
}
puts "marks: [llength $ids] registered, [llength $syms] in sprite"
```

Read the top of `tools/check.tcl` first to find the failure variable it already uses (it exits non-zero on any failure) and use that name instead of `failed` if it differs.

- [ ] **Step 3: Add the nine entries to marks.edn**

Append inside the `:ui` vector, after the `m-bell` line and before the closing `]}`:

```clojure
  {:id "m-chat"     :group :nav     :unicode nil       :ascii "chat" :nerd "f086" :nerd-name "nf-fa-comments"}
  {:id "m-event"    :group :nav     :unicode nil       :ascii "ev"   :nerd "f0e7" :nerd-name "nf-fa-bolt"}
  {:id "m-system"   :group :nav     :unicode nil       :ascii "sys"  :nerd "f233" :nerd-name "nf-fa-server"}
  {:id "m-tool"     :group :object  :unicode nil       :ascii "tool" :nerd "f0ad" :nerd-name "nf-fa-wrench"}
  {:id "m-hub"      :group :nav     :unicode "⇄" :ascii "<->"  :nerd "f0ec" :nerd-name "nf-fa-exchange"}
  {:id "m-agent"    :group :object  :unicode nil       :ascii "agt"  :nerd "f2db" :nerd-name "nf-fa-microchip"}
  {:id "m-run"      :group :action  :unicode "▶" :ascii ">"    :nerd "f04b" :nerd-name "nf-fa-play"}
  {:id "m-send"     :group :action  :unicode "➤" :ascii "->"   :nerd "f1d8" :nerd-name "nf-fa-paper_plane"}
  {:id "m-external" :group :action  :unicode "↗" :ascii "^"    :nerd "f08e" :nerd-name "nf-fa-external_link"}
```

- [ ] **Step 4: Run the check, expect the mismatch**

```bash
cd /home/imsmith/github/design-system && make tcl-check
```

Expected: non-zero, `marks: registry/sprite mismatch` listing the nine as `edn only`.

- [ ] **Step 5: Add the nine symbols to sprite.svg**

Insert before `</svg>`. All 24x24, stroke 2, round caps and joins, `currentColor`, no fills, none using octagon/triangle/diamond/circle/square as the primary silhouette:

```svg
  <symbol id="m-chat" viewBox="0 0 24 24"><g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 5h16v11H9l-5 4z"/><line x1="8" y1="9" x2="16" y2="9"/><line x1="8" y1="12.5" x2="13" y2="12.5"/></g></symbol>
  <symbol id="m-event" viewBox="0 0 24 24"><g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="13,2 5,14 11,14 10,22 19,9 13,9 13,2"/></g></symbol>
  <symbol id="m-system" viewBox="0 0 24 24"><g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="6" rx="1"/><rect x="3" y="14" width="18" height="6" rx="1"/><line x1="7" y1="7" x2="7.01" y2="7"/><line x1="7" y1="17" x2="7.01" y2="17"/></g></symbol>
  <symbol id="m-tool" viewBox="0 0 24 24"><g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14.5 6.5a4 4 0 0 0 4.9 4.9L21 13l-6 6-1.6-1.6a4 4 0 0 0-4.9-4.9L4 8l4-4z"/><line x1="12" y1="12" x2="19" y2="19"/></g></symbol>
  <symbol id="m-hub" viewBox="0 0 24 24"><g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="7,4 3,8 7,12"/><line x1="3" y1="8" x2="21" y2="8"/><polyline points="17,12 21,16 17,20"/><line x1="21" y1="16" x2="3" y2="16"/></g></symbol>
  <symbol id="m-agent" viewBox="0 0 24 24"><g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="6" y="6" width="12" height="12" rx="1"/><rect x="10" y="10" width="4" height="4"/><line x1="9" y1="2" x2="9" y2="6"/><line x1="15" y1="2" x2="15" y2="6"/><line x1="9" y1="18" x2="9" y2="22"/><line x1="15" y1="18" x2="15" y2="22"/><line x1="2" y1="9" x2="6" y2="9"/><line x1="2" y1="15" x2="6" y2="15"/><line x1="18" y1="9" x2="22" y2="9"/><line x1="18" y1="15" x2="22" y2="15"/></g></symbol>
  <symbol id="m-run" viewBox="0 0 24 24"><g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="7,4 19,12 7,20"/></g></symbol>
  <symbol id="m-send" viewBox="0 0 24 24"><g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="3,4 21,12 3,20 6,12"/><line x1="6" y1="12" x2="21" y2="12"/></g></symbol>
  <symbol id="m-external" viewBox="0 0 24 24"><g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M18 13v6a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h6"/><polyline points="15,3 21,3 21,9"/><line x1="10" y1="14" x2="21" y2="3"/></g></symbol>
```

- [ ] **Step 6: Update the chapter**

In `manual/04-marks-iconography.md` section 4, change "Nineteen everyday marks" to "Twenty-eight everyday marks" and replace the three bullets with:

```markdown
- **Nav/control:** `m-close`, `m-menu`, `m-chevron`, `m-more`, `m-chat`, `m-event`,
  `m-system`, `m-hub`
- **Actions:** `m-search`, `m-add`, `m-remove`, `m-edit`, `m-delete`,
  `m-refresh`, `m-filter`, `m-download`, `m-upload`, `m-run`, `m-send`, `m-external`
- **Objects:** `m-settings`, `m-info`, `m-help`, `m-user`, `m-lock`, `m-bell`,
  `m-tool`, `m-agent`
```

In the sentence that begins "What it deliberately omits (copy, save, external-link, calendar, etc.)", remove "external-link, ".

- [ ] **Step 7: Run every host check and the specimen**

```bash
cd /home/imsmith/github/design-system && make tcl-check && make gen-fresh && make specimen && git status --short
```

Expected: `marks: 36 registered, 36 in sprite`, all checks pass, `specimen.html` modified. Open `specimen.html` in a browser and confirm the nine new symbols render in the marks block at the same weight as their neighbours.

- [ ] **Step 8: Distrobox checks**

```bash
cd /home/imsmith/github/design-system && make lint
```

Expected: markdownlint clean (the distrobox `design-system` exists). APCA is unaffected by marks; skip `make apca`.

- [ ] **Step 9: Commit**

```bash
cd /home/imsmith/github/design-system && git add tokens/marks.edn assets/marks/sprite.svg manual/04-marks-iconography.md specimen.html tools/check.tcl && git commit -m "marks: nine UI marks for agento nav and actions; check registry/sprite agreement"
```

---

### Task 2: Sync gos-ui and pin

**Files:**
- Modify: `/home/imsmith/github/gos-ui/priv/static/gos-ui/assets/marks/sprite.svg` (by `make sync`)
- Modify: `/home/imsmith/github/gos-ui/priv/design-system.rev`
- Modify: `/home/imsmith/github/gos-ui/test/gos_ui_test.exs`

**Interfaces:**
- Produces: a gos-ui commit SHA, referred to below as `GOS_UI_SHA`, consumed by agento's mix.exs in Task 3.

- [ ] **Step 1: Branch and write the failing test**

```bash
cd /home/imsmith/github/gos-ui && git checkout -b sync-marks
```

In `test/gos_ui_test.exs`, inside the existing `test "sprite inlines the mark symbols hidden"`, add after its existing assertions:

```elixir
    for id <- ~w(m-chat m-event m-system m-tool m-hub m-agent m-run m-send m-external) do
      assert html =~ ~s(<symbol id="#{id}"), "sprite lacks #{id}"
    end
```

Read that test first to learn the variable that holds the rendered sprite and use it instead of `html` if it differs.

- [ ] **Step 2: Run, expect failure**

```bash
cd /home/imsmith/github/gos-ui && mix test test/gos_ui_test.exs > /tmp/gos-ui-test.log 2>&1; tail -8 /tmp/gos-ui-test.log
```

Expected: 1 failure, `sprite lacks m-chat`.

- [ ] **Step 3: Sync**

```bash
cd /home/imsmith/github/gos-ui && make sync && cat priv/design-system.rev && git status --short
```

Expected: rev equals `git -C ../design-system rev-parse HEAD`; only `sprite.svg`, `design-system.rev` changed (tokens unchanged).

- [ ] **Step 4: Full check**

```bash
cd /home/imsmith/github/gos-ui && make check > /tmp/gos-ui-check.log 2>&1; tail -5 /tmp/gos-ui-check.log
```

Expected: formatted, no warnings, all tests pass.

- [ ] **Step 5: Commit and record the SHA**

```bash
cd /home/imsmith/github/gos-ui && git add -A && git commit -m "sync design-system $(cat priv/design-system.rev | cut -c1-7): nine UI marks" && git rev-parse HEAD
```

Record the printed SHA as `GOS_UI_SHA` for Task 3.

---

### Task 3: agento foundation: dep, static, root layout, Tailwind remap, JS

**Files:**
- Modify: `/home/imsmith/github/agento/mix.exs` (deps)
- Modify: `/home/imsmith/github/agento/lib/agento_web/endpoint.ex` (static plugs)
- Modify: `/home/imsmith/github/agento/lib/agento_web/components/layouts/root.html.heex`
- Modify: `/home/imsmith/github/agento/assets/css/app.css`
- Modify: `/home/imsmith/github/agento/assets/js/app.js`
- Modify: `/home/imsmith/github/agento/lib/agento_web.ex` (`html_helpers`)
- Create: `/home/imsmith/github/agento/test/agento_web/design_system_test.exs`

**Interfaces:**
- Produces: every view module and `Layouts` has `GosUi.Components` imported (via `use GosUi` in `html_helpers`); `/gos-ui/styles.css` served; `<html data-theme>` set pre-paint; window hooks `GosUiHooks` and `ThemeSwitch` registered.

- [ ] **Step 1: Write the failing test**

Create `test/agento_web/design_system_test.exs`:

```elixir
defmodule AgentoWeb.DesignSystemTest do
  @moduledoc "The web tier consumes imsmith/design-system through gos-ui and nothing else."
  use AgentoWeb.ConnCase

  test "root layout links the design-system stylesheet and carries a theme", %{conn: conn} do
    html = conn |> get("/chat") |> html_response(200)
    assert html =~ ~s(href="/gos-ui/styles.css")
    assert html =~ ~s(<html lang="en" data-theme="tron")
    assert html =~ ~s(<symbol id="m-agent")
  end

  test "the design-system static root is served", %{conn: conn} do
    assert conn |> get("/gos-ui/styles.css") |> response(200) =~ "@import"
  end
end
```

- [ ] **Step 2: Run, expect failure**

```bash
cd /home/imsmith/github/agento && MIX_ENV=test mix test test/agento_web/design_system_test.exs > /tmp/agento-test.log 2>&1; tail -12 /tmp/agento-test.log
```

Expected: 2 failures (no stylesheet link; 404 on `/gos-ui/styles.css`).

- [ ] **Step 3: Add the dep and static plug**

In `mix.exs` deps, after `{:bandit, "~> 1.5"}`, add:

```elixir
      {:gos_ui, github: "imsmith/gos-ui", ref: "GOS_UI_SHA"},
```

with the SHA from Task 2. Then:

```bash
cd /home/imsmith/github/agento && mix deps.get > /tmp/agento-deps.log 2>&1; tail -3 /tmp/agento-deps.log
```

In `lib/agento_web/endpoint.ex`, directly above the existing `plug Plug.Static,` block, add:

```elixir
  # The design system's stylesheet, fonts, tokens and mark sprite, vendored
  # by gos-ui. Served before the app's own static root so nothing shadows it.
  plug Plug.Static, at: "/gos-ui", from: {:gos_ui, "priv/static/gos-ui"}, gzip: false
```

- [ ] **Step 4: Import gos-ui everywhere templates are written**

In `lib/agento_web.ex`, inside `html_helpers`, directly after `import AgentoWeb.CoreComponents`, add:

```elixir
      # Design-system components (imsmith/gos-ui)
      use GosUi
```

- [ ] **Step 5: Root layout**

Replace `lib/agento_web/components/layouts/root.html.heex` entirely:

```heex
<!DOCTYPE html>
<html lang="en" data-theme="tron">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <meta name="csrf-token" content={get_csrf_token()} />
    <.live_title default="LLMAgent" suffix=" · Web UI">
      {assigns[:page_title]}
    </.live_title>
    <link rel="stylesheet" href={~p"/gos-ui/styles.css"} />
    <link phx-track-static rel="stylesheet" href={~p"/assets/css/app.css"} />
    <script defer phx-track-static type="text/javascript" src={~p"/assets/js/app.js"}>
    </script>
    <script>
      // Theme before first paint. Keys: gos:theme (tron|matrix|compaq), gos:mode (dark|light).
      (() => {
        const html = document.documentElement;
        const theme = localStorage.getItem("gos:theme");
        const mode = localStorage.getItem("gos:mode");
        if (theme) html.setAttribute("data-theme", theme);
        if (mode === "light") html.setAttribute("data-mode", "light");
      })();
    </script>
  </head>
  <body class="h-screen flex flex-col">
    <.sprite />
    {@inner_content}
  </body>
</html>
```

- [ ] **Step 6: Tailwind remap (transitional form)**

Replace `assets/css/app.css` entirely. daisyUI stays for now so unmigrated views still render; the `--*: initial` wipe is **not** in this task.

```css
/* Tailwind 4 as a layout-only utility layer over imsmith/design-system.
   No preflight: the design system's base.css owns element defaults.
   No @layer: gos-ui/styles.css is unlayered, and unlayered CSS outranks any
   layer, so layered utilities could never override a component padding or a
   base heading size. Unlayered, this file loads after styles.css and wins on
   source order at equal specificity, which is the override we want.
   TRANSITIONAL: daisyUI is still loaded for views not yet migrated. */
@import "tailwindcss/theme.css";
@import "tailwindcss/utilities.css" source(none);
@source "../css";
@source "../js";
@source "../../lib/agento_web";

@plugin "../vendor/heroicons";
@plugin "../vendor/daisyui" { themes: false; }
@plugin "../vendor/daisyui-theme" {
  name: "dark";
  default: true;
  prefersdark: true;
  color-scheme: "dark";
  --color-base-100: oklch(30.33% 0.016 252.42);
  --color-base-200: oklch(25.26% 0.014 253.1);
  --color-base-300: oklch(20.15% 0.012 254.09);
  --color-base-content: oklch(97.807% 0.029 256.847);
  --color-primary: oklch(58% 0.233 277.117);
  --color-primary-content: oklch(96% 0.018 272.314);
  --color-secondary: oklch(58% 0.233 277.117);
  --color-secondary-content: oklch(96% 0.018 272.314);
  --color-accent: oklch(60% 0.25 292.717);
  --color-accent-content: oklch(96% 0.016 293.756);
  --color-neutral: oklch(37% 0.044 257.287);
  --color-neutral-content: oklch(98% 0.003 247.858);
  --color-info: oklch(58% 0.158 241.966);
  --color-info-content: oklch(97% 0.013 236.62);
  --color-success: oklch(60% 0.118 184.704);
  --color-success-content: oklch(98% 0.014 180.72);
  --color-warning: oklch(66% 0.179 58.318);
  --color-warning-content: oklch(98% 0.022 95.277);
  --color-error: oklch(58% 0.253 17.585);
  --color-error-content: oklch(96% 0.015 12.422);
  --radius-selector: 0.25rem; --radius-field: 0.25rem; --radius-box: 0.5rem;
  --size-selector: 0.21875rem; --size-field: 0.21875rem;
  --border: 1.5px; --depth: 1; --noise: 0;
}

@theme {
  --spacing: 0.5rem; /* p-1 = 8px, p-0.5 = 4px: the design-system scale */
  --breakpoint-sm: 640px;
  --breakpoint-md: 768px;
  --breakpoint-lg: 1024px;
  --breakpoint-xl: 1280px;
  --breakpoint-2xl: 1536px;
  --font-weight-regular: 400;
  --font-weight-medium: 500;
  --font-weight-bold: 700;
}

@theme inline {
  --color-bg: var(--bg);
  --color-surface: var(--surface);
  --color-surface-raised: var(--surface-raised);
  --color-text: var(--text);
  --color-muted: var(--muted);
  --color-border: var(--border);
  --color-accent: var(--accent);
  --color-on-accent: var(--on-accent);
  --color-status-critical: var(--status-critical);
  --color-status-high: var(--status-high);
  --color-status-medium: var(--status-medium);
  --color-status-low: var(--status-low);
  --color-status-unknown: var(--status-unknown);
  --font-mono: var(--font-mono);
  --font-prose: var(--font-prose);
  --text-micro: var(--text-micro);
  --text-caption: var(--text-caption);
  --text-small: var(--text-small);
  --text-body: var(--text-body);
  --text-lead: var(--text-lead);
  --text-h3: var(--text-h3);
  --text-h2: var(--text-h2);
  --text-h1: var(--text-h1);
  --text-display: var(--text-display);
  --radius-sm: var(--radius-sm);
  --radius-md: var(--radius-md);
  --radius-lg: var(--radius-lg);
  --leading-tight: var(--leading-tight);
  --leading-snug: var(--leading-snug);
  --leading-normal: var(--leading-normal);
  --tracking-label: var(--tracking-label);
}

@custom-variant phx-click-loading (.phx-click-loading&, .phx-click-loading &);
@custom-variant phx-submit-loading (.phx-submit-loading&, .phx-submit-loading &);
@custom-variant phx-change-loading (.phx-change-loading&, .phx-change-loading &);

[data-phx-session], [data-phx-teleported-src] { display: contents }
```

Note: the old `dark` custom variant keyed on `data-theme=dark` is gone; the design system keys mode on `data-mode`.

- [ ] **Step 7: JS hooks**

In `assets/js/app.js`, after `import topbar from "../vendor/topbar"`, add:

```javascript
import {GosUiHooks} from "../../deps/gos_ui/priv/static/gos-ui/gos-ui.js"
```

After the `Hooks.AutoScroll = {...}` block, add:

```javascript
// ThemeSwitch: the gos-ui theme_switch form, driven client-side. Theme and
// mode live in localStorage and on <html>; the server never learns them.
Hooks.ThemeSwitch = {
  mounted() {
    const html = document.documentElement
    const theme = this.el.querySelector("select[name=theme]")
    const mode = this.el.querySelector("select[name=mode]")
    theme.value = localStorage.getItem("gos:theme") || "tron"
    mode.value = localStorage.getItem("gos:mode") || "dark"
    this.el.addEventListener("change", () => {
      localStorage.setItem("gos:theme", theme.value)
      localStorage.setItem("gos:mode", mode.value)
      html.setAttribute("data-theme", theme.value)
      if (mode.value === "light") html.setAttribute("data-mode", "light")
      else html.removeAttribute("data-mode")
    })
  },
}
```

Change the LiveSocket hooks line to:

```javascript
  hooks: {...colocatedHooks, ...GosUiHooks, ...Hooks},
```

Change the topbar color to the accent token so the progress bar is on-system:

```javascript
topbar.config({barColors: {0: "var(--accent)"}, shadowColor: "rgba(0, 0, 0, .3)"})
```

- [ ] **Step 8: Build assets and run the new test**

```bash
cd /home/imsmith/github/agento && mix assets.build > /tmp/agento-assets.log 2>&1; tail -3 /tmp/agento-assets.log && MIX_ENV=test mix test test/agento_web/design_system_test.exs > /tmp/agento-test.log 2>&1; tail -5 /tmp/agento-test.log
```

Expected: assets build without error; 2 tests pass.

- [ ] **Step 9: Full web suite**

```bash
cd /home/imsmith/github/agento && MIX_ENV=test mix test test/agento_web > /tmp/agento-test.log 2>&1; tail -5 /tmp/agento-test.log
```

Expected: all pass. The old views still render on daisyUI.

- [ ] **Step 10: Commit**

```bash
cd /home/imsmith/github/agento && git add mix.exs mix.lock lib/agento_web.ex lib/agento_web/endpoint.ex lib/agento_web/components/layouts/root.html.heex assets/css/app.css assets/js/app.js test/agento_web/design_system_test.exs && git commit -m "web: gos-ui foundation; design-system stylesheet, theme pre-paint, Tailwind remapped to tokens"
```

---

### Task 4: Shared helpers for severity and copy

**Files:**
- Create: `/home/imsmith/github/agento/lib/agento_web/components/ds.ex`
- Create: `/home/imsmith/github/agento/test/agento_web/components/ds_test.exs`

**Interfaces:**
- Produces: `AgentoWeb.DS.step(term) :: :critical | :high | :medium | :low | :unknown` and `AgentoWeb.DS.chevron(expanded? :: boolean) :: %{name: "m-chevron", rotate: 0 | 90}`; the component `<.disclosure summary=... open?=...>` for the two collapse sites; `<.empty>` for the "nothing here" sentences; `<.pre>` for inspected payloads. Imported in `html_helpers`.

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule AgentoWeb.DSTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias AgentoWeb.DS

  test "outcome and status words map to alert-ramp steps" do
    assert DS.step("ok") == :low
    assert DS.step(:ok) == :low
    assert DS.step("aborted") == :medium
    assert DS.step({:partial, [1]}) == :medium
    assert DS.step({:error, :x}) == :critical
    assert DS.step("boom") == :critical
    assert DS.step(nil) == :unknown
    assert DS.step(true) == :low
    assert DS.step(false) == :critical
  end

  test "disclosure renders a native details element with the chevron" do
    html = render_component(&DS.disclosure/1, summary: "Tool: x / y", inner_block: [%{inner_block: fn _, _ -> "body" end}])
    assert html =~ "<details"
    assert html =~ "<summary"
    assert html =~ ~s(href="#m-chevron")
    assert html =~ "body"
  end

  test "pre inspects its value" do
    html = render_component(&DS.pre/1, value: %{a: 1})
    assert html =~ "a: 1"
    assert html =~ ~s(class="ds-data)
  end
end
```

- [ ] **Step 2: Run, expect failure**

```bash
cd /home/imsmith/github/agento && MIX_ENV=test mix test test/agento_web/components/ds_test.exs > /tmp/agento-test.log 2>&1; tail -5 /tmp/agento-test.log
```

Expected: compile error, `AgentoWeb.DS` undefined.

- [ ] **Step 3: Implement**

Create `lib/agento_web/components/ds.ex`:

```elixir
defmodule AgentoWeb.DS do
  @moduledoc """
  The few things agento adds on top of gos-ui: a mapping from this app's
  outcome and status terms to the alert ramp, a native disclosure for
  collapsible payloads (the design system has no accordion), and the
  empty-state and inspected-payload sentences every view repeats.
  """
  use Phoenix.Component
  import GosUi.Components, only: [mark: 1]

  @doc "An outcome, status or truthiness as an alert-ramp step."
  def step(v) when v in ["ok", :ok, true], do: :low
  def step(v) when v in ["aborted", :aborted], do: :medium
  def step({:partial, _}), do: :medium
  def step({:error, _}), do: :critical
  def step(nil), do: :unknown
  def step(false), do: :critical
  def step(v) when is_binary(v), do: :critical
  def step(_), do: :unknown

  attr :summary, :string, required: true
  attr :step, :atom, default: nil, doc: "optional ramp step that colors the summary rule"
  attr :icon, :string, default: nil
  attr :class, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  @doc "A collapsible block on the native details element, chevron rotating on open."
  def disclosure(assigns) do
    ~H"""
    <details class={["border border-border rounded-lg my-0.5 bg-surface", @class]} data-step={@step} style={@step && "border-left: 3px solid var(--status-#{@step})"} {@rest}>
      <summary class="flex items-center gap-1 p-1 text-small cursor-pointer select-none">
        <.mark name="m-chevron" size={12} class="ds-chevron" />
        <.mark :if={@icon} name={@icon} size={14} />
        <span>{@summary}</span>
      </summary>
      <div class="p-1 pt-0">{render_slot(@inner_block)}</div>
    </details>
    """
  end

  attr :value, :any, required: true
  attr :class, :string, default: nil

  @doc "An inspected Elixir term as data text."
  def pre(assigns) do
    ~H"""
    <pre class={["ds-data text-caption whitespace-pre-wrap overflow-x-auto p-1 rounded-md bg-surface-raised", @class]}>{inspect(@value, pretty: true)}</pre>
    """
  end

  attr :class, :string, default: nil
  slot :inner_block, required: true

  @doc "A one-sentence empty state in muted text."
  def empty(assigns) do
    ~H"""
    <p class={["text-small text-muted p-1", @class]}>{render_slot(@inner_block)}</p>
    """
  end
end
```

Add to `assets/css/app.css`, above the `[data-phx-session]` line:

```css
/* details/summary chevron: points right closed, down open (motion: fast) */
details > summary { list-style: none; }
details > summary::-webkit-details-marker { display: none; }
details .ds-chevron { transition: transform 120ms cubic-bezier(0.2, 0, 0, 1); }
details[open] > summary .ds-chevron { transform: rotate(90deg); }
```

In `lib/agento_web.ex` `html_helpers`, after `use GosUi`, add `import AgentoWeb.DS`.

- [ ] **Step 4: Run, expect pass**

```bash
cd /home/imsmith/github/agento && MIX_ENV=test mix test test/agento_web/components/ds_test.exs > /tmp/agento-test.log 2>&1; tail -5 /tmp/agento-test.log
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /home/imsmith/github/agento && git add lib/agento_web/components/ds.ex lib/agento_web.ex assets/css/app.css test/agento_web/components/ds_test.exs && git commit -m "web: DS helpers; ramp-step mapping, native disclosure, empty and pre"
```

---

### Task 5: App shell

**Files:**
- Modify: `/home/imsmith/github/agento/lib/agento_web/components/layouts.ex` (whole file)
- Modify: `/home/imsmith/github/agento/test/agento_web/design_system_test.exs`

**Interfaces:**
- Consumes: `Hooks.ThemeSwitch` (Task 3), `GosUi.Components.app_shell/menu/theme_switch/flash_toasts/toast/mark`.
- Produces: `Layouts.app/1` with the same attrs as today (`flash`, `active_nav`, `inner_block`); the inner block is rendered inside `.ds-shell__main`, which scrolls. Views that want a full-height two-pane layout use `class="h-full"` on their wrapper; the main already pads `--space-3`, so views drop their outer `p-4`.

- [ ] **Step 1: Write the failing tests**

Append to `test/agento_web/design_system_test.exs`:

```elixir
  test "the shell carries the sidebar nav, the brand mark and the theme switch", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/chat")
    assert html =~ ~s(class="ds-shell)
    assert html =~ ~s(href="#m-agent")
    for path <- ~w(/chat /events /system /tools /hub /rules), do: assert(html =~ ~s(href="#{path}"))
    assert html =~ ~s(aria-current="page")
    assert html =~ ~s(phx-hook="ThemeSwitch")
    assert html =~ ~s(select id="ds-theme")
  end

  test "an error flash is a persistent critical toast", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/chat?agent=no_such_agent_xyz")
    html = render(view)
    assert html =~ ~s(class="ds-toast")
    assert html =~ ~s(data-severity="critical")
    assert html =~ ~s(data-duration="0")
    assert html =~ "no_such_agent_xyz"
  end
```

- [ ] **Step 2: Run, expect failure**

```bash
cd /home/imsmith/github/agento && MIX_ENV=test mix test test/agento_web/design_system_test.exs > /tmp/agento-test.log 2>&1; tail -8 /tmp/agento-test.log
```

Expected: 2 new failures.

- [ ] **Step 3: Rewrite layouts.ex**

Replace the whole file:

```elixir
defmodule AgentoWeb.Layouts do
  @moduledoc """
  The app shell: brand, sidebar navigation, theme switch, flash toasts.
  All of it is the design system's `app_shell`; this module only names the
  six views and wires the flash map.
  """
  use AgentoWeb, :html

  embed_templates "layouts/*"

  @nav [
    %{id: :chat, label: "CHAT", icon: "m-chat", navigate: "/chat"},
    %{id: :events, label: "EVENTS", icon: "m-event", navigate: "/events"},
    %{id: :system, label: "SYSTEM", icon: "m-system", navigate: "/system"},
    %{id: :tools, label: "TOOLS", icon: "m-tool", navigate: "/tools"},
    %{id: :hub, label: "HUB", icon: "m-hub", navigate: "/hub"},
    %{id: :rules, label: "RULES", icon: "m-event", navigate: "/rules"}
  ]

  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current_scope, :map, default: nil
  attr :active_nav, :atom, default: :chat, doc: "the currently active navigation section"
  slot :inner_block, required: true

  def app(assigns) do
    assigns = assign(assigns, :nav, @nav)

    ~H"""
    <.app_shell nav_width="160px" class="flex-1 min-h-0">
      <:brand><a href="/" class="flex items-center gap-1"><.mark name="m-agent" size={18} /> LLMAgent</a></:brand>
      <:actions>
        <div id="theme-switch" phx-hook="ThemeSwitch" phx-update="ignore">
          <.theme_switch theme={:tron} mode={:dark} on_change={JS.dispatch("gos:theme")} />
        </div>
      </:actions>
      <:nav><.menu variant={:sidebar} label="Views" items={@nav} selected={@active_nav} /></:nav>
      {render_slot(@inner_block)}
    </.app_shell>

    <.flash_toasts flash={@flash} />
    <.toast_stack id="connection-toasts">
      <.toast
        id="client-error"
        severity={:critical}
        title="Connection lost."
        hidden
        phx-disconnected={JS.show(to: "#client-error")}
        phx-connected={JS.hide(to: "#client-error")}
      >
        The browser cannot reach the server. Reconnecting; nothing to do.
      </.toast>
      <.toast
        id="server-error"
        severity={:critical}
        title="Server error."
        hidden
        phx-disconnected={JS.show(to: "#server-error")}
        phx-connected={JS.hide(to: "#server-error")}
      >
        The view crashed and is restarting. If it repeats, check the server log.
      </.toast>
    </.toast_stack>
    """
  end
end
```

Note on `toast`: it uses `phx-hook="GosUiToast"` and `data-duration`; critical is 0 so the connection toasts never auto-dismiss. The `hidden` attribute reaches the element through `:rest`.

- [ ] **Step 4: Compile and run the shell tests**

```bash
cd /home/imsmith/github/agento && MIX_ENV=test mix compile --warnings-as-errors > /tmp/agento-compile.log 2>&1; tail -5 /tmp/agento-compile.log; MIX_ENV=test mix test test/agento_web/design_system_test.exs > /tmp/agento-test.log 2>&1; tail -5 /tmp/agento-test.log
```

Expected: compiles; 4 tests pass. If `theme_switch`'s select ids differ from `ds-theme`, read gos-ui `field_id/2` (labels "Theme" and "Mode" give `ds-theme` and `ds-mode`) and fix the assertion, not the component.

- [ ] **Step 5: Remove the old flash components from CoreComponents**

In `lib/agento_web/components/core_components.ex` delete `flash/1` (and its attrs/doc), `show/2`, `hide/2`. Keep `icon/1`, `input/1`, `header/1`, `table/1`, `list/1`, `button/1` until Task 15. Compile with warnings as errors again.

- [ ] **Step 6: Full web suite**

```bash
cd /home/imsmith/github/agento && MIX_ENV=test mix test test/agento_web > /tmp/agento-test.log 2>&1; tail -5 /tmp/agento-test.log
```

Expected: all pass. Any test that asserted on the old `#flash-group` or `toast` markup is updated to assert on `ds-toast` text content.

- [ ] **Step 7: Visual check**

```bash
cd /home/imsmith/github/agento && mix assets.build > /tmp/agento-assets.log 2>&1 && (mix phx.server > /tmp/agento-server.log 2>&1 &) && sleep 8 && grep -m1 -oE 'http://[^ ]+' /tmp/agento-server.log
```

Open the URL. Confirm: sidebar on the left with six uppercase labels and marks, current page highlighted; brand in accent with ambient glow; theme switch top-right; switch to compaq/light and confirm the page repaints and the brand glow disappears; reload and confirm it persists; navigate between views and confirm it persists and the selects still show compaq/light. Stop the server: `pkill -f "phx.server"`.

- [ ] **Step 8: Pin theme persistence with a hook test**

Append to `test/agento_web/design_system_test.exs`:

```elixir
  test "the theme switch is ignored by LiveView patches so the client owns it", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/chat")
    assert html =~ ~s(id="theme-switch" phx-hook="ThemeSwitch" phx-update="ignore")
  end
```

Run the file; expect pass.

- [ ] **Step 9: Commit**

```bash
cd /home/imsmith/github/agento && git add lib/agento_web/components/layouts.ex lib/agento_web/components/core_components.ex test/agento_web/design_system_test.exs && git commit -m "web: app shell on gos-ui; sidebar nav, theme switch, flash toasts"
```

---

### Task 6: Tools view

**Files:**
- Modify: `/home/imsmith/github/agento/lib/agento_web/live/tools_live.ex:90-207` (render only)
- Test: `/home/imsmith/github/agento/test/agento_web/live/tools_live_test.exs`

**Interfaces:**
- Consumes: `card`, `button`, `input`, `textarea`, `state_panel`, `alert`, `DS.pre`, `DS.empty`.
- Produces: nothing new. Events `refresh_tools`, `select_tool`, `update_invoke`, `invoke_tool` and field names `action`, `args` unchanged.

- [ ] **Step 1: Confirm the existing tests are the net**

```bash
cd /home/imsmith/github/agento && MIX_ENV=test mix test test/agento_web/live/tools_live_test.exs > /tmp/agento-test.log 2>&1; tail -3 /tmp/agento-test.log
```

Expected: pass (baseline).

- [ ] **Step 2: Add one assertion for the result and error treatment**

In `tools_live_test.exs`, find the test that invokes a tool and asserts on its result; after its result assertion add:

```elixir
    assert has_element?(view, "[data-severity=low]")
```

and in the test that triggers invalid JSON (or add one if none exists):

```elixir
  test "invalid args JSON is a critical alert with what to do", %{conn: conn} do
    {:ok, view, _} = live(conn, "/tools")
    view |> element("[phx-click=select_tool]") |> render_click()
    view |> form("form[phx-submit=invoke_tool]", %{"action" => "x", "args" => "{nope"}) |> render_submit()
    assert has_element?(view, "[data-severity=critical]", "Args are not JSON")
  end
```

Run; expect the new assertions to fail.

- [ ] **Step 3: Replace render/1**

```elixir
  @impl true
  def render(assigns) do
    ~H"""
    <.app flash={@flash} active_nav={:tools}>
      <div class="flex h-full gap-2">
        <%!-- Tool list --%>
        <.card title={"Registered tools (#{length(@tools)})"} density={:compact} flush class="w-36 flex flex-col min-h-0">
          <:actions>
            <.button size={:sm} icon="m-refresh" phx-click="refresh_tools" title="Refresh">Refresh</.button>
          </:actions>
          <div class="overflow-y-auto">
            <.empty :if={@tools == []}>No tools registered.</.empty>
            <div
              :for={{name, module} <- @tools}
              phx-click="select_tool"
              phx-value-name={name}
              phx-value-module={module}
              class={[
                "p-1 cursor-pointer border-b border-border hover:bg-surface-raised",
                @selected_tool == to_string(name) && "bg-surface-raised"
              ]}
              aria-current={@selected_tool == to_string(name) && "true"}
            >
              <div class="font-medium text-small">{name}</div>
              <div class="text-caption text-muted truncate">{module}</div>
            </div>
          </div>
        </.card>

        <%!-- Tool detail --%>
        <div class="flex-1 overflow-y-auto space-y-2">
          <%= if @selected_module do %>
            <h2 class="text-h3">{@selected_tool}</h2>
            <p class="text-small text-muted">{@selected_module}</p>

            <.card :if={assigns[:tool_description]} title="Description" density={:compact}>
              <p class="text-small whitespace-pre-wrap">{@tool_description}</p>
            </.card>

            <.card :if={@tool_introspection} title="Comn introspection" density={:compact}>
              <.key_value>
                <:item key="look/0">{@tool_introspection.look}</:item>
                <:item key="recon/0"><.pre value={@tool_introspection.recon} /></:item>
                <:item key="choices/0"><.pre value={@tool_introspection.choices} /></:item>
              </.key_value>
            </.card>

            <.card title="Manual invocation" density={:compact}>
              <form phx-submit="invoke_tool" phx-change="update_invoke" class="space-y-1">
                <.input name="action" value={@invoke_action} placeholder="Action" />
                <.textarea name="args" value={@invoke_args} rows={4} placeholder={~s|{"key": "value"}|} />
                <.button type="submit" variant={:primary} size={:sm} icon="m-run">Invoke</.button>
              </form>

              <.alert :if={@invoke_result} severity={:low} title="Invoked." class="mt-1">
                <.pre value={@invoke_result} />
              </.alert>

              <.alert :if={@invoke_error} severity={:critical} title={error_title(@invoke_error)} class="mt-1">
                <pre class="ds-data text-caption whitespace-pre-wrap">{@invoke_error}</pre>
              </.alert>
            </.card>
          <% else %>
            <.state_panel mode={:empty} mark="m-tool" title="No tool selected.">
              Pick a tool on the left to see its description, introspection and invoke it.
            </.state_panel>
          <% end %>
        </div>
      </div>
    </.app>
    """
  end

  # what happened · what to do, per the voice chapter
  defp error_title("Invalid JSON in args field"), do: "Args are not JSON. Fix the text and invoke again."
  defp error_title(_), do: "The tool returned an error."
```

Note `key_value` items: gos-ui's `key_value` has an `:item` slot with required `key` attr (see its attrs at `lib/gos_ui/components.ex:1271`).

- [ ] **Step 4: Run the view tests**

```bash
cd /home/imsmith/github/agento && MIX_ENV=test mix test test/agento_web/live/tools_live_test.exs > /tmp/agento-test.log 2>&1; tail -5 /tmp/agento-test.log
```

Expected: pass, including the two new assertions.

- [ ] **Step 5: Visual check**

Start the server as in Task 5 step 7, open `/tools`, select a tool, invoke with `{nope`. Confirm: left list is a compact card, selected row tinted; invoke button primary with the run mark; the error alert shows the critical octagon, title and the raw message; focus ring visible when tabbing through the form. Check in compaq/light too. Stop the server.

- [ ] **Step 6: Commit**

```bash
cd /home/imsmith/github/agento && git add lib/agento_web/live/tools_live.ex test/agento_web/live/tools_live_test.exs && git commit -m "web: tools view on gos-ui"
```

---

### Task 7: Hub view

**Files:**
- Modify: `/home/imsmith/github/agento/lib/agento_web/live/hub_live.ex:275-441` (helpers `outcome_class` and render)
- Test: `/home/imsmith/github/agento/test/agento_web/live/hub_live_test.exs`

**Interfaces:**
- Consumes: `card`, `table` (with `:col` slots), `status_badge`, `tag`, `alert`, `key_value`, `DS.step/1`, `DS.empty`.
- Produces: nothing new. Keeps `#performer-*`, `#client-*` ids and the `#turns` tbody id (tests select `#turns tr:first-child`).

- [ ] **Step 1: Baseline**

```bash
cd /home/imsmith/github/agento && MIX_ENV=test mix test test/agento_web/live/hub_live_test.exs > /tmp/agento-test.log 2>&1; tail -3 /tmp/agento-test.log
```

- [ ] **Step 2: Add assertions**

In `hub_live_test.exs`, in the test that renders a turn with outcome `"ok"` (line ~136 area), add:

```elixir
    assert view |> element("#turns tr:first-child [data-step=low]", "OK") |> has_element?()
```

In the test covering a missing default host (or add one):

```elixir
    assert has_element?(view, "[data-severity=medium]", "No default host is configured")
```

Run; expect the new assertions to fail.

- [ ] **Step 3: Replace `outcome_class/1` and render/1**

Delete `outcome_class/1`. Replace render:

```elixir
  @impl true
  def render(assigns) do
    ~H"""
    <.app flash={@flash} active_nav={:hub}>
      <div class="space-y-2">
        <div class="flex items-baseline justify-between">
          <h1 class="text-h2">Private LLM hub</h1>
          <span class="text-small text-muted">
            <%= if @status.listening do %>
              listening on <span class="ds-data">{@status.listening}</span>,
            <% else %>
              not serving HTTP,
            <% end %>
            registered with busybody as <span class="ds-data">{@status.busybody_name}</span>
          </span>
        </div>

        <.alert :if={@status.default_host && !@status.default_reachable} severity={:medium} title={"The default host #{@status.default_host} is not advertising."}>
          Requests for a model no host serves, which is every request a coding client makes, get a 404. Start that host or change the default.
        </.alert>

        <.alert :if={is_nil(@status.default_host)} severity={:medium} title="No default host is configured.">
          Only requests naming a model a host serves will route. Set one in the hub configuration.
        </.alert>

        <div class="grid grid-cols-1 lg:grid-cols-3 gap-2">
          <.card title={"Performers (#{length(@status.performers)})"} density={:compact} class="lg:col-span-2">
            <.empty :if={@status.performers == []}>No performers are advertising on the network.</.empty>
            <.table :if={@status.performers != []} rows={@status.performers} row_id={&dom_id("performer", &1.host || &1.id)} density={:compact}>
              <:col :let={p} label="Host">
                <span class="ds-data">{p.host}</span>
                <.tag :if={p.default} accent class="ml-0.5">default</.tag>
                <div class="text-caption text-muted ds-data">{p.address}</div>
              </:col>
              <:col :let={p} label="Serving"><span class="ds-data text-caption">{p.model}</span></:col>
              <:col :let={p} label="Context" num>{p.context}</:col>
              <:col :let={p} label="Slots" num>{p.slots}</:col>
              <:col :let={p} label="Found by"><span class="text-caption">{p.source}</span></:col>
              <:col :let={p} label="Lease" num><span class="text-caption">{p.lease}</span></:col>
            </.table>
          </.card>

          <div class="space-y-2">
            <.card title={"Clients (#{length(@status.clients)})"} density={:compact}>
              <.empty :if={@status.clients == []}>
                No clients are configured, so every request is refused. Add one to <span class="ds-data">{@status.config_path}</span>.
              </.empty>
              <ul :if={@status.clients != []} class="text-small space-y-0.5">
                <li :for={c <- @status.clients} id={dom_id("client", c.name)} class="flex justify-between">
                  <span class="ds-data">{c.name}</span>
                  <span class="text-caption text-muted">{c.reach}</span>
                </li>
              </ul>
            </.card>

            <.card title="Settings" density={:compact}>
              <.key_value density={:dense}>
                <:item key="Default host">{@status.default_host || "none"}</:item>
                <:item key="Performer timeout" num>{@status.performer_timeout_s} s</:item>
                <:item key="Turn log kept" num>{@status.retention_days} days</:item>
                <:item key="Config"><span class="break-all">{@status.config_path}</span></:item>
              </.key_value>
            </.card>
          </div>
        </div>

        <.card title="Point a client at it" density={:compact}>
          <pre class="ds-data text-caption bg-surface-raised p-1 rounded-md whitespace-pre-wrap">export ANTHROPIC_BASE_URL=$(tclsh scripts/hub-url.tcl)
    export ANTHROPIC_AUTH_TOKEN=&lt;the client's token from the hub config&gt;</pre>
          <p class="text-caption text-muted mt-1">
            The hub takes a free port each time it starts. The script asks busybody where it is now.
          </p>
        </.card>

        <.card title={"Recent turns (#{length(@turns)})"} density={:compact}>
          <.empty :if={@turns == []}>No turns yet.</.empty>
          <table :if={@turns != []} class="ds-table ds-table--dense">
            <thead>
              <tr>
                <th class="ds-table__th">Time (UTC)</th>
                <th class="ds-table__th">Client</th>
                <th class="ds-table__th">Asked for</th>
                <th class="ds-table__th">Served by</th>
                <th class="ds-table__th">Outcome</th>
                <th class="ds-table__th ds-table__th--num">Tokens in</th>
                <th class="ds-table__th ds-table__th--num">Tokens out</th>
                <th class="ds-table__th ds-table__th--num">Took</th>
              </tr>
            </thead>
            <tbody id="turns">
              <tr :for={t <- @turns} class="ds-table__row">
                <td class="ds-table__td">{clock(t.at)}</td>
                <td class="ds-table__td">{t.client}</td>
                <td class="ds-table__td">{t.requested_model}</td>
                <td class="ds-table__td">{t.performer_model}</td>
                <td class="ds-table__td">
                  <.status_badge step={DS.step(t.outcome)} label={outcome_word(t.outcome)} size={12} />
                  <span :if={t.stop_reason} class="text-caption text-muted ml-0.5">{t.stop_reason}</span>
                  <div :if={t.error} class="text-caption text-status-critical">{t.error}</div>
                </td>
                <td class="ds-table__td ds-table__td--num">{t.input_tokens}</td>
                <td class="ds-table__td ds-table__td--num">{t.output_tokens}</td>
                <td class="ds-table__td ds-table__td--num">{duration(t.duration_ms)}</td>
              </tr>
            </tbody>
          </table>
        </.card>
      </div>
    </.app>
    """
  end

  # The lexicon word is the chrome; the hub's own outcome string stays visible as a label
  # only where it adds information beyond the step.
  defp outcome_word("ok"), do: "OK"
  defp outcome_word("aborted"), do: "ABORTED"
  defp outcome_word(_error), do: "DOWN"
```

Add `alias AgentoWeb.DS` near the other aliases. The turns table is hand-written because the test selects `#turns tr:first-child` by the tbody id, and gos-ui's `table` has no tbody id attr; the class names are the design system's own.

- [ ] **Step 4: Run the view tests**

```bash
cd /home/imsmith/github/agento && MIX_ENV=test mix test test/agento_web/live/hub_live_test.exs > /tmp/agento-test.log 2>&1; tail -5 /tmp/agento-test.log
```

Expected: pass. If `row_id` on the performers table raises on a map without `:host`, that is a data bug to surface, not to paper over: the existing `dom_id("performer", p.host || p.id)` already assumes one of them.

- [ ] **Step 5: Visual check** as before on `/hub`. Confirm the medium alert carries the diamond, the OK badge the circle, numeric columns right-aligned.

- [ ] **Step 6: Commit**

```bash
cd /home/imsmith/github/agento && git add lib/agento_web/live/hub_live.ex test/agento_web/live/hub_live_test.exs && git commit -m "web: hub view on gos-ui"
```

---

### Task 8: Rules view

**Files:**
- Modify: `/home/imsmith/github/agento/lib/agento_web/live/rules_live.ex:103-375` (`status_class/1`, render)
- Test: `/home/imsmith/github/agento/test/agento_web/live/rules_live_test.exs`

**Interfaces:**
- Consumes: `card`, `alert`, `status_badge`, `input`, `textarea`, `button`, `DS.step/1`, `DS.empty`.
- Produces: unchanged ids `runtime-unavailable`, `ui-deploy-off`, `explanation`, `policy-*`, `rule-*`, `condition-*`, `schedule-*`; unchanged forms `load`, `explain`; unchanged `button[phx-click=unload]` with `data-confirm`.

- [ ] **Step 1: Baseline, then add assertions**

Run the file for a baseline. In the test that loads a policy successfully (around line 68-76), add:

```elixir
    assert view |> element("[id^=policy-live-test-rule] [data-step=unknown]", "loaded here") |> has_element?()
```

Run; expect failure.

- [ ] **Step 2: Replace `status_class/1` with a step mapping and rewrite render**

Replace `status_class/1` with:

```elixir
  # nil means deployed from this UI: not a file, so no file state; the ramp's
  # "unknown" is the honest step. :ok is a healthy file; anything else is degraded.
  defp status_step(nil), do: :unknown
  defp status_step(:ok), do: :low
  defp status_step(_), do: :medium
```

Replace render:

```elixir
  @impl true
  def render(assigns) do
    ~H"""
    <.app flash={@flash} active_nav={:rules}>
      <div class="space-y-2">
        <div class="flex items-baseline justify-between">
          <h1 class="text-h2">Rules</h1>
          <span class="text-small text-muted">watching <span class="ds-data">{@snapshot.dir}</span></span>
        </div>

        <.alert :if={!@snapshot.available} severity={:medium} title="The rules runtime is not answering." id="runtime-unavailable">
          It is restarting, or a rule is not finishing. What is shown is the last trace; the rest fills in when it answers.
        </.alert>

        <div class="grid grid-cols-1 lg:grid-cols-3 gap-2">
          <.card title={"Policies (#{length(@snapshot.policies)})"} density={:compact} class="lg:col-span-2 space-y-1">
            <.empty :if={@snapshot.policies == []}>
              Nothing is loaded. Save a <span class="ds-data">.rule</span> file in the directory above, or deploy one below.
            </.empty>
            <table :if={@snapshot.policies != []} class="ds-table ds-table--compact">
              <thead>
                <tr>
                  <th class="ds-table__th">Policy</th>
                  <th class="ds-table__th">Rules</th>
                  <th class="ds-table__th">Conditions</th>
                  <th class="ds-table__th">Schedules</th>
                  <th class="ds-table__th">Status</th>
                  <th class="ds-table__th"></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={p <- @snapshot.policies} id={dom_id("policy", p.id || "anonymous")} class="ds-table__row">
                  <td class="ds-table__td">{p.id || "(anonymous)"}</td>
                  <td class="ds-table__td text-caption">{Enum.join(p.rules, ", ")}</td>
                  <td class="ds-table__td text-caption">{Enum.join(p.conditions, ", ")}</td>
                  <td class="ds-table__td text-caption">{Enum.join(p.schedules, ", ")}</td>
                  <td class="ds-table__td"><.status_badge step={status_step(p.status)} label={status_text(p.status)} size={12} /></td>
                  <td class="ds-table__td text-right">
                    <.button :if={p.id && @snapshot.ui_deploy} size={:sm} phx-click="unload" phx-value-id={p.id} data-confirm={"Unload #{p.id}?"}>unload</.button>
                  </td>
                </tr>
              </tbody>
            </table>

            <p :if={!@snapshot.ui_deploy} class="text-caption text-muted" id="ui-deploy-off">
              Deploying from here is off: this UI has no login. Policies come from files in the
              directory above. To deploy and unload from here, set
              <span class="ds-data">{":rules {:ui-deploy true}"}</span>
              in the hub configuration.
            </p>
            <form :if={@snapshot.ui_deploy} phx-submit="load" class="space-y-1">
              <h3 class="ds-label">Deploy a policy</h3>
              <.input name="policy" value={@load_id} placeholder="policy name, e.g. garage.rule" required />
              <.textarea name="source" rows={6} value={@load_source} placeholder={~s|rule greet { when HUB_REQUEST { log ?client } }|} required />
              <.button type="submit" variant={:primary} size={:sm}>Deploy</.button>
            </form>
          </.card>

          <div class="space-y-2">
            <.card title="What would an event do?" density={:compact}>
              <form phx-submit="explain" class="space-y-1">
                <.input name="event" value={@explain_event} placeholder="HUB_REQUEST" />
                <.input name="path" value={@explain_path} placeholder="context path (optional)" />
                <.button type="submit" size={:sm}>Explain</.button>
              </form>
              <div :if={@explanation} id="explanation" class="text-caption space-y-0.5 mt-1">
                <p :if={@explanation[:unavailable]}>The runtime is not answering.</p>
                <p :if={!@explanation[:unavailable] and @explanation.rules == [] and @explanation.conditions == []}>
                  Nothing listens for <span class="ds-data">{@explanation.event}</span>.
                </p>
                <p :for={r <- @explanation.rules}>
                  <span class="ds-data">{r.rule}</span> ({r.policy || "anonymous"}): {outcome_text(r.outcome)}
                </p>
                <p :for={c <- @explanation.conditions}>condition <span class="ds-data">{c}</span> evaluates</p>
              </div>
            </.card>

            <.card title="Tools a rule may call" density={:compact}>
              <p :if={@snapshot.tools == []} class="text-caption text-muted">
                None: <span class="ds-data">{":rules {:tools [...]}"}</span>
                in the hub configuration is empty. {length(@snapshot.verbs)} verbs are discoverable.
              </p>
              <div :if={@snapshot.tools != []} class="text-caption">
                <p class="ds-data">{Enum.join(@snapshot.tools, " ")}</p>
                <p class="text-muted mt-0.5">
                  {length(@snapshot.verbs)} verbs discoverable, as <span class="ds-data">[MODULE::verb :key value]</span>.
                </p>
              </div>
            </.card>
          </div>
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-2 gap-2">
          <.card title={"Rules (#{length(@snapshot.rules)})"} density={:compact}>
            <.empty :if={@snapshot.rules == []}>No rules loaded.</.empty>
            <table :if={@snapshot.rules != []} class="ds-table ds-table--compact">
              <thead>
                <tr>
                  <th class="ds-table__th">Rule</th>
                  <th class="ds-table__th">Listens for</th>
                  <th class="ds-table__th">Context</th>
                  <th class="ds-table__th">State</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={r <- @snapshot.rules} id={dom_id("rule", r.name)} class="ds-table__row">
                  <td class="ds-table__td">
                    <span class="ds-data">{r.name}</span>
                    <div class="text-caption text-muted">{r.policy || "anonymous"}</div>
                  </td>
                  <td class="ds-table__td text-caption">{Enum.join(r.events, ", ")}</td>
                  <td class="ds-table__td text-caption">{r.context}</td>
                  <td class="ds-table__td text-caption">
                    <div :for={{k, v} <- r.bindings}>${k} = {inspect(v)}</div>
                    <div :for={d <- r.dwell}>dwell {d.event}: {d.state}</div>
                  </td>
                </tr>
              </tbody>
            </table>

            <h3 :if={@snapshot.conditions != []} class="ds-label mt-2 mb-1">Conditions</h3>
            <ul :if={@snapshot.conditions != []} class="text-caption space-y-0.5">
              <li :for={c <- @snapshot.conditions} id={dom_id("condition", c.name)}>
                <span class="ds-data">{c.name}</span> is <span class="ds-data">{c.value}</span>
                after <span class="ds-data">{Enum.join(c.events, ", ")}</span>
              </li>
            </ul>

            <h3 :if={@snapshot.schedules != []} class="ds-label mt-2 mb-1">Schedules</h3>
            <ul :if={@snapshot.schedules != []} class="text-caption space-y-0.5">
              <li :for={s <- @snapshot.schedules} id={dom_id("schedule", s.event)}>
                <span class="ds-data">{s.event}</span>
                <span :if={s.fired_at} class="text-muted">last fired {clock(s.fired_at)} UTC</span>
              </li>
            </ul>
          </.card>

          <.card title={"Trace (#{length(@snapshot.trace)})"} density={:compact}>
            <.empty :if={@snapshot.trace == []}>No event has reached a rule yet.</.empty>
            <table :if={@snapshot.trace != []} class="ds-table ds-table--dense">
              <thead>
                <tr>
                  <th class="ds-table__th">Time (UTC)</th>
                  <th class="ds-table__th">Event</th>
                  <th class="ds-table__th">Context</th>
                  <th class="ds-table__th">Rules</th>
                  <th class="ds-table__th">Results</th>
                  <th class="ds-table__th ds-table__th--num">Took</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={t <- @snapshot.trace} class="ds-table__row">
                  <td class="ds-table__td">{clock(t.at)}</td>
                  <td class="ds-table__td">{t.event}</td>
                  <td class="ds-table__td text-muted">{t.context_path}</td>
                  <td class="ds-table__td">
                    <div :for={s <- t.steps}>{step_text(s)}</div>
                    <div :for={c <- t.conditions}>condition {c} became true</div>
                  </td>
                  <td class="ds-table__td"><div :for={r <- t.results}>{result_text(r)}</div></td>
                  <td class="ds-table__td ds-table__td--num">{div(t.duration_us, 1000)} ms</td>
                </tr>
              </tbody>
            </table>
          </.card>
        </div>
      </div>
    </.app>
    """
  end
```

The `.ds-label` class exists in components.css (uppercase mono caption with label tracking). Tables are hand-written with `ds-table__*` classes because each row carries its own test-visible `id`.

- [ ] **Step 3: Run the view tests**

```bash
cd /home/imsmith/github/agento && MIX_ENV=test mix test test/agento_web/live/rules_live_test.exs > /tmp/agento-test.log 2>&1; tail -5 /tmp/agento-test.log
```

Expected: pass.

- [ ] **Step 4: Visual check** on `/rules` (deploy a policy if `ui_deploy` is on in the dev config; else confirm the `ui-deploy-off` sentence). Confirm the trace table reads at dense density.

- [ ] **Step 5: Commit**

```bash
cd /home/imsmith/github/agento && git add lib/agento_web/live/rules_live.ex test/agento_web/live/rules_live_test.exs && git commit -m "web: rules view on gos-ui"
```

---

### Task 9: Chat view

**Files:**
- Modify: `/home/imsmith/github/agento/lib/agento_web/live/chat_live.ex:262-597` (render and subcomponents) and `:664-669` (`role_alignment`, `role_bubble_class`)
- Modify: `/home/imsmith/github/agento/assets/css/app.css` (chat bubble rules)
- Test: `/home/imsmith/github/agento/test/agento_web/live/chat_live_test.exs`

**Interfaces:**
- Consumes: `card`, `button`, `input`, `select`, `state_panel`, `alert`, `key_value`, `DS.disclosure`, `DS.pre`, `DS.empty`.
- Produces: unchanged events and names. `#chat-messages` with `phx-hook="ScrollBottom"` unchanged.

- [ ] **Step 1: Baseline and add assertions**

Run the file. In the test that starts an agent through the form with `"endpoint" => "manual"` (line ~220), the existing `assert has_element?(view, "input[name=model]")` already pins Review Focus 3. Add to the test that sends a prompt (line ~107 area), after the submit:

```elixir
    assert has_element?(view, "#chat-messages .chat-msg--user", "hello world")
```

Run; expect failure.

- [ ] **Step 2: Chat bubble CSS**

The design system has no chat bubble. Add to `assets/css/app.css` above the `[data-phx-session]` line. Values are tokens only:

```css
/* chat messages: a bordered surface, user messages on the accent tint */
.chat-msg { max-width: 72ch; padding: var(--space-1) var(--space-2); border: var(--border-width) solid var(--border); border-radius: var(--radius-lg); background: var(--surface); white-space: pre-wrap; }
.chat-msg--user { margin-left: auto; border-color: var(--accent); background: color-mix(in srgb, var(--accent) calc(var(--accent-tint) * 100%), transparent); }
.chat-msg--system { color: var(--muted); }
.chat-role { font-size: var(--text-caption); color: var(--muted); text-transform: uppercase; letter-spacing: var(--tracking-label); margin-bottom: var(--space-half); }
```

Confirm `--accent-tint` is exported by `tokens/colors.css` (`grep accent-tint deps/gos_ui/priv/static/gos-ui/tokens/colors.css`). If it is a bare number, the `calc(... * 100%)` form above is right; if it is already a percentage, drop the `calc`.

- [ ] **Step 3: Replace render/1 and the subcomponents**

```elixir
  @impl true
  def render(assigns) do
    ~H"""
    <.app flash={@flash} active_nav={:chat}>
      <div class="flex h-full gap-2">
        <%!-- Agent sidebar --%>
        <.card title="Agents" density={:compact} flush class="w-32 flex flex-col min-h-0">
          <:actions>
            <.button size={:sm} icon="m-refresh" phx-click="refresh_agents" title="Refresh">Refresh</.button>
            <.button size={:sm} icon="m-add" phx-click="toggle_new_agent_form" title="New agent">New</.button>
          </:actions>

          <div :if={@show_new_agent_form} class="p-1 border-b border-border">
            <.new_agent_form form={@new_agent_form} endpoint_options={@endpoint_options} />
          </div>

          <div class="flex-1 overflow-y-auto">
            <.empty :if={@agents == []}>No agents running.</.empty>
            <div
              :for={agent <- @agents}
              phx-click="select_agent"
              phx-value-name={agent.name}
              class={[
                "p-1 cursor-pointer border-b border-border hover:bg-surface-raised",
                @selected_agent && @selected_agent.name == agent.name && "bg-surface-raised"
              ]}
              aria-current={@selected_agent && @selected_agent.name == agent.name && "true"}
            >
              <div class="font-medium text-small">{agent.name}</div>
              <div class="text-caption text-muted">{agent.role} / {agent.model}</div>
              <%= if to_string(agent.name) == @confirm_stop do %>
                <div class="mt-0.5 flex gap-0.5">
                  <.button size={:sm} variant={:danger} phx-click="stop_agent" phx-value-name={agent.name}>Stop {agent.name}</.button>
                  <.button size={:sm} phx-click="cancel_stop">Cancel</.button>
                </div>
              <% else %>
                <.button size={:sm} class="mt-0.5" phx-click="confirm_stop" phx-value-name={agent.name}>Stop</.button>
              <% end %>
            </div>
          </div>
        </.card>

        <%!-- Chat panel --%>
        <div class="flex-1 flex flex-col min-h-0">
          <%= if @selected_agent do %>
            <div class="p-1 border-b border-border flex items-center justify-between">
              <div>
                <span class="font-bold">{@selected_agent.name}</span>
                <span class="text-small text-muted ml-1">{@selected_agent.role} / {@selected_agent.model}</span>
              </div>
              <div class="flex gap-0.5">
                <.button size={:sm} icon="m-settings" phx-click="show_config">Config</.button>
                <%= if @confirm_clear do %>
                  <.button size={:sm} variant={:danger} phx-click="clear_history">Clear history for {@selected_agent.name}</.button>
                  <.button size={:sm} phx-click="cancel_clear">Cancel</.button>
                <% else %>
                  <.button size={:sm} icon="m-delete" phx-click="confirm_clear">Clear</.button>
                <% end %>
              </div>
            </div>

            <div :if={@show_agent_config} class="p-1 border-b border-border bg-surface">
              <.agent_config agent={@selected_agent} />
            </div>

            <div class="flex-1 overflow-y-auto p-2 space-y-1.5" id="chat-messages" phx-hook="ScrollBottom">
              <%= for item <- interleave_messages_and_events(@messages, @events_inline) do %>
                <%= case item do %>
                  <% {:message, msg} -> %>
                    <.chat_message message={msg} />
                  <% {:tool_dispatch, evt} -> %>
                    <.tool_dispatch_block event={evt} />
                  <% {:tool_result, evt} -> %>
                    <.tool_result_block event={evt} />
                  <% {:error, evt} -> %>
                    <.error_block event={evt} />
                <% end %>
              <% end %>

              <div :if={@thinking} class="chat-msg" aria-busy="true">
                <.mark name="m-refresh" size={14} class="ds-btn__spin" label="thinking" /> thinking
              </div>
            </div>

            <form phx-submit="send_prompt" class="p-1 border-t border-border">
              <div class="flex gap-1">
                <.input name="prompt" value={@prompt_text} phx-change="update_prompt" placeholder="Type a message..." autocomplete="off" class="flex-1" />
                <.button type="submit" variant={:primary} icon="m-send" disabled={@prompt_text == ""}>Send</.button>
              </div>
            </form>
          <% else %>
            <.state_panel mode={:empty} mark="m-chat" title="No agent selected.">
              Pick an agent on the left to begin chatting.
            </.state_panel>
          <% end %>
        </div>
      </div>
    </.app>
    """
  end

  # -- Subcomponents --

  defp chat_message(assigns) do
    ~H"""
    <div class={["chat-msg", role_class(@message.role)]}>
      <div class="chat-role">{@message.role}</div>
      <div>{@message.content}</div>
    </div>
    """
  end

  defp tool_dispatch_block(assigns) do
    ~H"""
    <.disclosure
      icon="m-tool"
      summary={"Tool: #{@event.data[:tool] || @event.data["tool"]} / #{@event.data[:action] || @event.data["action"]}"}
    >
      <.pre value={sanitize_event_data(@event.data)} />
    </.disclosure>
    """
  end

  defp tool_result_block(assigns) do
    dur = assigns.event.data[:duration_ms] || assigns.event.data["duration_ms"]
    assigns = assign(assigns, :dur, dur)

    ~H"""
    <.disclosure
      icon="m-low"
      step={:low}
      summary={"Tool result: #{@event.data[:result] || @event.data["result"]}#{if @dur, do: " (#{@dur} ms)", else: ""}"}
    >
      <.pre value={sanitize_event_data(@event.data)} />
    </.disclosure>
    """
  end

  defp error_block(assigns) do
    ~H"""
    <.alert severity={:critical} title={"Error: #{@event.data[:reason] || @event.data["reason"]}"} class="my-0.5">
      Source: {@event.data[:source] || @event.data["source"]}
    </.alert>
    """
  end

  defp agent_config(assigns) do
    ~H"""
    <.key_value density={:dense} columns={2}>
      <:item key="Name">{@agent.name}</:item>
      <:item key="Role">{@agent.role}</:item>
      <:item key="Model">{@agent.model}</:item>
      <:item key="API host">{@agent.api_host}</:item>
      <:item key="LLM client">{inspect(@agent.llm_client)}</:item>
      <:item key="Memory">{inspect(@agent.memory)}</:item>
      <:item key="History length" num>{@agent.history_length}</:item>
    </.key_value>
    """
  end

  defp new_agent_form(assigns) do
    ~H"""
    <form phx-submit="start_agent" phx-change="update_new_agent" class="space-y-1">
      <.input name="name" value={@form.name} placeholder="Agent name (atom)" required />
      <.select name="role" options={available_roles()} value={@form.role} />
      <.select name="endpoint" options={Enum.map(@endpoint_options, &{&1.label, &1.id})} value={@form.endpoint_id} />
      <%= if @form.endpoint_id == "manual" do %>
        <.input name="model" value={@form.model} placeholder="Model (e.g. llama3.2)" />
        <.input name="api_host" value={@form.api_host} placeholder="API host (e.g. http://localhost:11434/v1)" />
      <% end %>
      <.select name="llm_client" options={llm_client_options()} value={@form.llm_client} />
      <.select name="memory" options={memory_options()} value={@form.memory} />
      <div class="flex gap-0.5">
        <.button type="submit" variant={:primary} size={:sm} class="flex-1">Start</.button>
        <.button type="button" size={:sm} phx-click="toggle_new_agent_form">Cancel</.button>
      </div>
    </form>
    """
  end
```

Replace `role_alignment/1` and `role_bubble_class/1` with:

```elixir
  defp role_class(role) when role in ["user", :user], do: "chat-msg--user"
  defp role_class(role) when role in ["system", :system], do: "chat-msg--system"
  defp role_class(_), do: nil
```

The `.ds-btn__spin` class animates `m-refresh` (defined in components.css for loading buttons); reusing it for the thinking indicator keeps motion on one token.

- [ ] **Step 4: Run the view tests plus routing and architectural tests that drive chat**

```bash
cd /home/imsmith/github/agento && MIX_ENV=test mix test test/agento_web/live/chat_live_test.exs test/agento_web/live/prompt_routing_test.exs test/agento_web/live/endpoint_discovery_refresh_test.exs test/agento_web/architectural_test.exs > /tmp/agento-test.log 2>&1; tail -5 /tmp/agento-test.log
```

Expected: pass.

- [ ] **Step 5: Pin the select names**

Add to `chat_live_test.exs` near the test at line ~206:

```elixir
    for name <- ~w(role endpoint llm_client memory), do: assert(has_element?(view, "select[name=#{name}]"))
```

Run the file; expect pass.

- [ ] **Step 6: Visual check** on `/chat`: start an agent, send a prompt, confirm the user bubble right-aligned on the accent tint, the thinking spinner, tool disclosures open and close with the chevron rotation, and the danger buttons name their target. Both modes.

- [ ] **Step 7: Commit**

```bash
cd /home/imsmith/github/agento && git add lib/agento_web/live/chat_live.ex assets/css/app.css test/agento_web/live/chat_live_test.exs && git commit -m "web: chat view on gos-ui"
```

---

### Task 10: Events view

**Files:**
- Modify: `/home/imsmith/github/agento/lib/agento_web/live/events_live.ex:228-652` (render and subcomponents)
- Test: `/home/imsmith/github/agento/test/agento_web/live/events_live_test.exs`

**Interfaces:**
- Consumes: `tabs`, `select` (with prompt option in inner block), `input`, `button`, `card`, `key_value`, `freshness`, `DS.pre`, `DS.empty`.
- Produces: unchanged: `form[phx-change=update_filter]`, `select[name=topic|type|agent_id]`, `input[type=datetime-local][name=from|to]`, `#event-stream[data-auto-scroll]` with `phx-hook="AutoScroll"`, `[phx-click=set_tab][phx-value-tab=...]`, `[phx-click=toggle_row][phx-value-index]`, `[phx-click=toggle_auto_scroll]`, forms `query_durable_log` and `query_event_log`.

- [ ] **Step 1: Baseline and add one assertion**

Run the file. In the test at line ~107 (auto-scroll), add after the first assertion:

```elixir
    assert has_element?(view, ".ds-fresh--live", "LIVE")
    view |> element("[phx-click=toggle_auto_scroll]") |> render_click()
    assert has_element?(view, ".ds-fresh--paused", "PAUSED")
```

(Keep the existing `data-auto-scroll=false` assertion after it.) Run; expect failure.

- [ ] **Step 2: Rewrite render/1 and the panels**

gos-ui `tabs` renders `<button role="tab" phx-click={@select} phx-value-id={t.id}>`. The tests select `[phx-click=set_tab][phx-value-tab=...]`, so the tab bar stays hand-written with the design system's `ds-tabs`/`ds-tab` classes and `aria-selected`.

```elixir
  @impl true
  def render(assigns) do
    ~H"""
    <.app flash={@flash} active_nav={:events}>
      <div class="flex flex-col h-full">
        <div class="ds-tabs">
          <div class="ds-tabs__list" role="tablist">
            <button :for={{id, label} <- tabs()} type="button" role="tab" class="ds-tab" aria-selected={to_string(@active_tab == id)} phx-click="set_tab" phx-value-tab={id}>
              <span>{label}</span>
            </button>
          </div>
        </div>

        <div class="flex-1 overflow-hidden flex gap-2 pt-1">
          <div class="flex-1 flex flex-col overflow-hidden">
            <%= case @active_tab do %>
              <% :live -> %>
                <.live_stream_panel
                  events={filtered_events(@live_events, @filter_topic, @filter_type, @filter_agent_id, @filter_from, @filter_to)}
                  auto_scroll={@auto_scroll}
                  expanded_rows={@expanded_rows}
                  filter_topic={@filter_topic}
                  filter_type={@filter_type}
                  filter_agent_id={@filter_agent_id}
                  filter_from={@filter_from}
                  filter_to={@filter_to}
                  known_topics={@known_topics}
                  known_types={@known_types}
                  known_agents={@known_agents}
                />
              <% :durable_log -> %>
                <.durable_log_panel query_agent_id={@query_agent_id} query_since={@query_since} query_results={@query_results} known_agents={@known_agents} />
              <% :event_log -> %>
                <.event_log_panel mode={@eventlog_mode} filter={@eventlog_filter} results={@eventlog_results} />
            <% end %>
          </div>

          <.card :if={@selected_event} title="Event detail" density={:compact} class="w-48 overflow-y-auto">
            <:actions><.button size={:sm} icon="m-close" phx-click="close_event_detail" title="Close">Close</.button></:actions>
            <.event_detail event={@selected_event} />
          </.card>
        </div>
      </div>
    </.app>
    """
  end

  defp tabs, do: [live: "Live stream", durable_log: "DurableLog query", event_log: "EventLog query"]

  # -- Subcomponents --

  defp live_stream_panel(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <form phx-change="update_filter" class="flex gap-1 items-end flex-wrap p-1 border-b border-border">
        <.select name="topic" label="Topic" options={@known_topics} value={@filter_topic}>
          <option value="">All topics</option>
        </.select>
        <.select name="type" label="Type" options={Enum.map(@known_types, &to_string/1)} value={@filter_type}>
          <option value="">All types</option>
        </.select>
        <.select name="agent_id" label="Agent" options={Enum.map(@known_agents, &to_string/1)} value={@filter_agent_id}>
          <option value="">All agents</option>
        </.select>
        <.input type="datetime-local" name="from" label="From" value={@filter_from} />
        <.input type="datetime-local" name="to" label="To" value={@filter_to} />
        <.button type="button" size={:sm} phx-click="clear_filters">Clear</.button>
        <div class="flex-1"></div>
        <.freshness state={if @auto_scroll, do: :live, else: :paused} />
        <.button type="button" size={:sm} variant={if @auto_scroll, do: :primary, else: :ghost} phx-click="toggle_auto_scroll">Auto-scroll</.button>
        <.button type="button" size={:sm} phx-click="clear_stream">Clear stream</.button>
      </form>

      <div class="flex-1 overflow-y-auto" id="event-stream" phx-hook="AutoScroll" data-auto-scroll={to_string(@auto_scroll)}>
        <.empty :if={@events == []}>No events yet. Waiting for activity.</.empty>
        <table :if={@events != []} class="ds-table ds-table--dense w-full">
          <thead class="sticky top-0 bg-surface">
            <tr>
              <th class="ds-table__th w-22">Timestamp</th>
              <th class="ds-table__th">Topic</th>
              <th class="ds-table__th">Type</th>
              <th class="ds-table__th">Source</th>
              <th class="ds-table__th w-4"></th>
              <th class="ds-table__th w-4"></th>
            </tr>
          </thead>
          <tbody>
            <%= for {{topic, event}, idx} <- Enum.with_index(@events) do %>
              <tr class="ds-table__row ds-table__row--interactive">
                <td class="ds-table__td cursor-pointer" phx-click="show_event" phx-value-index={idx}>{Map.get(event, :timestamp, "")}</td>
                <td class="ds-table__td cursor-pointer" phx-click="show_event" phx-value-index={idx}>{topic}</td>
                <td class="ds-table__td">{Map.get(event, :type, "")}</td>
                <td class="ds-table__td truncate max-w-16">{source_text(Map.get(event, :source, ""))}</td>
                <td class="ds-table__td">
                  <.button type="button" size={:sm} variant={:text} phx-click="toggle_row" phx-value-index={idx} title="Expand payload" aria-expanded={to_string(MapSet.member?(@expanded_rows, idx))}>
                    <.mark name="m-chevron" size={12} class={MapSet.member?(@expanded_rows, idx) && "rotate-90"} />
                  </.button>
                </td>
                <td class="ds-table__td">
                  <.button type="button" size={:sm} variant={:text} icon="m-external" phx-click="show_event" phx-value-index={idx} title="Open detail">Open</.button>
                </td>
              </tr>
              <tr :if={MapSet.member?(@expanded_rows, idx)}>
                <td colspan="6" class="ds-table__td p-0"><.pre value={Map.get(event, :data, %{})} class="m-1" /></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp durable_log_panel(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <div class="p-1 border-b border-border">
        <h3 class="ds-label mb-1">DurableLog query</h3>
        <form phx-submit="query_durable_log" phx-change="update_durable_query" class="flex gap-1 items-end">
          <.input name="agent_id" label="Agent ID" value={@query_agent_id} placeholder="agent_name" />
          <.input name="since" label="Since (ISO 8601, optional)" value={@query_since} placeholder="2026-02-24T00:00:00Z" />
          <.button type="submit" variant={:primary} size={:sm}>Query</.button>
        </form>
      </div>
      <div class="flex-1 overflow-y-auto">
        <.empty :if={@query_results == []}>No results. Run a query above.</.empty>
        <table :if={@query_results != []} class="ds-table ds-table--dense w-full">
          <thead class="sticky top-0 bg-surface">
            <tr><th class="ds-table__th w-22">Timestamp</th><th class="ds-table__th">Topic</th><th class="ds-table__th">Type</th><th class="ds-table__th">Source</th><th class="ds-table__th w-4"></th></tr>
          </thead>
          <tbody>
            <tr :for={{event, idx} <- Enum.with_index(@query_results)} class="ds-table__row ds-table__row--interactive cursor-pointer" phx-click="show_query_event" phx-value-index={idx} tabindex="0">
              <td class="ds-table__td">{Map.get(event, :timestamp, "")}</td>
              <td class="ds-table__td">{Map.get(event, :topic, "")}</td>
              <td class="ds-table__td">{Map.get(event, :type, "")}</td>
              <td class="ds-table__td truncate max-w-16">{source_text(Map.get(event, :source, ""))}</td>
              <td class="ds-table__td"><.mark name="m-chevron" size={12} /></td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
```

The result tables stay hand-written: gos-ui's `table` sends `phx-value-id` on select, and these events read `"index"`. The event-log panel is the same shape without the chevron column:

```elixir
  defp event_log_panel(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <div class="p-1 border-b border-border">
        <h3 class="ds-label mb-1">EventLog query (in-memory)</h3>
        <form phx-submit="query_event_log" phx-change="update_eventlog_query" class="flex gap-1 items-end">
          <.select name="mode" label="Mode" options={[{"all()", "all"}, {"for_topic/1", "for_topic"}, {"for_type/1", "for_type"}, {"since/1", "since"}]} value={@mode} />
          <.input :if={@mode != "all"} name="filter" label={filter_label(@mode)} value={@filter} />
          <.button type="submit" variant={:primary} size={:sm}>Query</.button>
        </form>
      </div>
      <div class="flex-1 overflow-y-auto">
        <.empty :if={@results == []}>No results. Run a query above.</.empty>
        <table :if={@results != []} class="ds-table ds-table--dense w-full">
          <thead class="sticky top-0 bg-surface">
            <tr><th class="ds-table__th w-22">Timestamp</th><th class="ds-table__th">Topic</th><th class="ds-table__th">Type</th><th class="ds-table__th">Source</th></tr>
          </thead>
          <tbody>
            <tr :for={{event, idx} <- Enum.with_index(@results)} class="ds-table__row ds-table__row--interactive cursor-pointer" phx-click="show_eventlog_event" phx-value-index={idx} tabindex="0">
              <td class="ds-table__td">{Map.get(event, :timestamp, "")}</td>
              <td class="ds-table__td">{Map.get(event, :topic, "")}</td>
              <td class="ds-table__td">{Map.get(event, :type, "")}</td>
              <td class="ds-table__td truncate max-w-16">{source_text(Map.get(event, :source, ""))}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp filter_label("for_topic"), do: "Topic"
  defp filter_label("for_type"), do: "Type (atom)"
  defp filter_label("since"), do: "Timestamp (ISO 8601)"
  defp filter_label(_), do: "Filter"

  defp event_detail(assigns) do
    ~H"""
    <.key_value density={:dense}>
      <:item key="Timestamp">{Map.get(@event, :timestamp, "N/A")}</:item>
      <:item key="Topic">{Map.get(@event, :topic, "N/A")}</:item>
      <:item key="Type">{Map.get(@event, :type, "N/A")}</:item>
      <:item key="Source">{source_text(Map.get(@event, :source, "N/A"))}</:item>
      <:item key="Data"><.pre value={Map.get(@event, :data, %{})} /></:item>
    </.key_value>
    """
  end
```

Selects: gos-ui's `select` renders `label` with `for` and derives the id from the label (`ds-topic`, `ds-type`, `ds-agent`, `ds-mode`). Two selects labelled "Type" would collide only within one form; the live panel and the eventlog panel never render together. The `input` with `label="From"` yields `id="ds-from"`.

`rotate-90` is a static Tailwind utility and survives the theme wipe.

- [ ] **Step 3: Run the view tests**

```bash
cd /home/imsmith/github/agento && MIX_ENV=test mix test test/agento_web/live/events_live_test.exs > /tmp/agento-test.log 2>&1; tail -5 /tmp/agento-test.log
```

Expected: pass. The datetime-local assertion `input[type=datetime-local][name=from]` holds because gos-ui `input` passes `type` and `name` through.

- [ ] **Step 4: Visual check** on `/events`: generate a few events (send a chat prompt in another tab), confirm the freshness pill flips LIVE/PAUSED, the chevron rotates on expand, the detail card opens on the right.

- [ ] **Step 5: Commit**

```bash
cd /home/imsmith/github/agento && git add lib/agento_web/live/events_live.ex test/agento_web/live/events_live_test.exs && git commit -m "web: events view on gos-ui"
```

---

### Task 11: System view

**Files:**
- Modify: `/home/imsmith/github/agento/lib/agento_web/live/system_live.ex:164-599` (render and panels)
- Test: `/home/imsmith/github/agento/test/agento_web/live/system_live_test.exs`

**Interfaces:**
- Consumes: `button`, `card`, `status_badge`, `tag`, `alert`, `key_value`, `stat_tile`, `DS.pre`, `DS.empty`.
- Produces: unchanged `button[phx-click=refresh]`, `[phx-click=set_tab][phx-value-tab=...]`, `[phx-click=select_ets_table][phx-value-name=...]`, `[phx-click=select_durable_agent][phx-value-agent=...]`, `[phx-click=select_module]`, `[phx-click=toggle_auto_refresh]`, `data-category` on error groups, the two export links.

- [ ] **Step 1: Baseline and add assertions**

Run the file. In the durable_log test that selects an agent (line ~200 area), add after the selection:

```elixir
    assert has_element?(view, ".ds-stat__label", "EVENT COUNT") or has_element?(view, ".ds-stat__label", "Event count")
```

In the sup_tree test (line ~19 area) after refresh:

```elixir
    assert has_element?(view, "[data-step=low]", "OK")
```

Run; expect failures.

- [ ] **Step 2: Rewrite render/1 and the panels**

```elixir
  @impl true
  def render(assigns) do
    ~H"""
    <.app flash={@flash} active_nav={:system}>
      <div class="flex flex-col h-full">
        <div class="ds-tabs">
          <div class="ds-tabs__list" role="tablist">
            <button :for={{id, label} <- tabs()} type="button" role="tab" class="ds-tab" aria-selected={to_string(@active_tab == id)} phx-click="set_tab" phx-value-tab={id}>
              <span>{label}</span>
            </button>
          </div>
        </div>

        <div class="flex-1 overflow-y-auto pt-1 space-y-2">
          <div class="flex items-center justify-between">
            <.button size={:sm} icon="m-refresh" phx-click="refresh">Refresh</.button>
          </div>

          <%= case @active_tab do %>
            <% :sup_tree -> %>
              <.sup_tree_panel tree={@tree} auto_refresh={@auto_refresh} />
            <% :ets -> %>
              <.ets_panel tables={@ets_tables} selected={@selected_table} entries={@table_entries} />
            <% :contexts -> %>
              <.contexts_panel contexts={@agent_contexts} />
            <% :errors -> %>
              <.errors_panel categories={@error_categories} events={@error_events} />
            <% :modules -> %>
              <.modules_panel modules={@comn_modules} selected={@selected_module} introspection={@module_introspection} />
            <% :durable_log -> %>
              <.durable_log_panel status={@durable_status} agents={@durable_agents} selected={@durable_selected} info={@durable_info} />
          <% end %>
        </div>
      </div>
    </.app>
    """
  end

  defp tabs,
    do: [sup_tree: "Supervision tree", ets: "ETS tables", contexts: "Contexts", errors: "Error catalog", modules: "Modules", durable_log: "DurableLog"]

  # -- Sub-panels --

  defp sup_tree_panel(assigns) do
    ~H"""
    <div>
      <div class="flex items-center gap-1 mb-1.5">
        <h3 class="ds-label">LLMAgent supervision tree</h3>
        <.button size={:sm} variant={if @auto_refresh, do: :primary, else: :ghost} phx-click="toggle_auto_refresh">Auto-refresh</.button>
      </div>
      <.empty :if={@tree == []}>No supervision tree loaded. Click Refresh above.</.empty>
      <div :if={@tree != []} class="space-y-0.5">
        <.tree_node :for={node <- @tree} node={node} depth={0} />
      </div>
    </div>
    """
  end

  defp tree_node(assigns) do
    ~H"""
    <div style={"margin-left: #{@depth * 1.5}rem"}>
      <div class="flex items-center gap-1 p-1 rounded-md hover:bg-surface-raised text-small">
        <%= if @node[:children] && @node[:children] != [] do %>
          <.mark name="m-chevron" size={12} class="rotate-90" />
        <% else %>
          <span class="w-1.5"></span>
        <% end %>
        <span class="ds-data font-medium">{@node[:name] || @node[:module]}</span>
        <span class="text-caption text-muted">{@node[:module]}</span>
        <.status_badge step={if @node[:alive], do: :low, else: :critical} size={10} />
        <span :if={@node[:pid]} class="text-caption ds-data text-muted">{inspect(@node[:pid])}</span>
        <span :if={@node[:message_queue_len]} class="text-caption text-muted">mq: {@node[:message_queue_len]}</span>
      </div>
      <%= if @node[:children] do %>
        <.tree_node :for={child <- @node[:children]} node={child} depth={@depth + 1} />
      <% end %>
    </div>
    """
  end

  defp ets_panel(assigns) do
    ~H"""
    <div>
      <h3 class="ds-label mb-1.5">ETS tables</h3>
      <div class="flex gap-2">
        <div class="w-32 space-y-0.5">
          <.empty :if={@tables == []}>No llmagent memory tables found.</.empty>
          <div
            :for={table <- @tables}
            phx-click="select_ets_table"
            phx-value-name={table.name}
            class={["p-1 rounded-md cursor-pointer hover:bg-surface-raised text-small", @selected == to_string(table.name) && "bg-surface-raised"]}
            aria-current={@selected == to_string(table.name) && "true"}
          >
            <div class="ds-data font-medium">{table.name}</div>
            <div class="text-caption text-muted">Size: {table.size} | Mem: {table.memory} words</div>
          </div>
        </div>
        <div :if={@selected} class="flex-1">
          <h4 class="ds-data mb-1">{@selected}</h4>
          <.empty :if={@entries == []}>Table is empty.</.empty>
          <div :if={@entries != []} class="space-y-1">
            <.pre :for={entry <- @entries} value={entry} />
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp contexts_panel(assigns) do
    ~H"""
    <div>
      <h3 class="ds-label mb-0.5">Agent contexts</h3>
      <p class="text-caption text-muted mb-1.5">Point-in-time snapshot. Context data is ephemeral and only set during prompt handling.</p>
      <.empty :if={@contexts == []}>No agent contexts found.</.empty>
      <div :if={@contexts != []} class="space-y-1.5">
        <.card :for={ctx <- @contexts} title={to_string(ctx.agent_name)} density={:compact}>
          <.key_value :if={ctx.context} density={:dense}>
            <:item :for={{key, val} <- Map.from_struct(ctx.context)} key={to_string(key)}>{inspect(val)}</:item>
          </.key_value>
          <.empty :if={!ctx.context}>No context set.</.empty>
        </.card>
      </div>
    </div>
    """
  end

  defp errors_panel(assigns) do
    ~H"""
    <div>
      <h3 class="ds-label mb-1.5">Error catalog</h3>
      <div class="mb-2">
        <h4 class="ds-label mb-0.5">Categories</h4>
        <div class="flex gap-1 flex-wrap"><.tag :for={cat <- @categories}>{cat}</.tag></div>
      </div>
      <div>
        <h4 class="ds-label mb-0.5">Error events by category</h4>
        <.empty :if={@events == []}>No error events recorded.</.empty>
        <div :if={@events != []} class="space-y-2">
          <div :for={{category, evts} <- group_errors_by_category(@events)} data-category={category}>
            <div class="flex items-center gap-1 mb-0.5">
              <.tag accent>{category}</.tag>
              <span class="text-caption text-muted">{length(evts)}</span>
            </div>
            <div class="space-y-1">
              <.alert :for={evt <- evts} severity={:critical} title={to_string(evt.data[:reason] || evt.data["reason"] || "unknown")}>
                Source: {evt.data[:source] || evt.data["source"] || "unknown"}
              </.alert>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp modules_panel(assigns) do
    ~H"""
    <div>
      <h3 class="ds-label mb-1.5">Comn modules</h3>
      <div class="flex gap-2">
        <div class="w-36 space-y-0.5">
          <.empty :if={@modules == []}>No Comn behaviour modules found.</.empty>
          <div
            :for={mod <- @modules}
            phx-click="select_module"
            phx-value-module={mod}
            class={["p-1 rounded-md cursor-pointer hover:bg-surface-raised text-small ds-data", @selected == to_string(mod) && "bg-surface-raised"]}
            aria-current={@selected == to_string(mod) && "true"}
          >
            {mod}
          </div>
        </div>
        <div :if={@introspection} class="flex-1">
          <.card density={:compact}>
            <.key_value>
              <:item key="look/0">{@introspection.look}</:item>
              <:item key="recon/0"><.pre value={@introspection.recon} /></:item>
              <:item key="choices/0"><.pre value={@introspection.choices} /></:item>
            </.key_value>
          </.card>
        </div>
      </div>
    </div>
    """
  end

  defp durable_log_panel(assigns) do
    ~H"""
    <div>
      <h3 class="ds-label mb-1.5">DurableLog inspector</h3>

      <div :if={@status} class="grid grid-cols-3 gap-1 mb-2">
        <.stat_tile label="Record count" value={@status[:record_count]} />
        <.stat_tile label="File size" value={@status[:file_size]} unit="bytes" />
        <.stat_tile label="DETS file" value={@status[:file_path]} class="col-span-1 overflow-hidden" />
      </div>

      <div class="flex gap-2">
        <div class="w-32">
          <h4 class="ds-label mb-1">Agents</h4>
          <.empty :if={@agents == []}>No agents found.</.empty>
          <div :if={@agents != []} class="space-y-0.5">
            <div
              :for={agent <- @agents}
              phx-click="select_durable_agent"
              phx-value-agent={agent}
              class={["p-1 rounded-md cursor-pointer hover:bg-surface-raised text-small ds-data", @selected == to_string(agent) && "bg-surface-raised"]}
              aria-current={@selected == to_string(agent) && "true"}
            >
              {agent}
            </div>
          </div>
        </div>

        <div :if={@info} class="flex-1">
          <.card title={to_string(@info.agent)} density={:compact}>
            <div class="grid grid-cols-2 gap-1 mb-1">
              <.stat_tile label="Event count" value={@info.event_count} />
              <.stat_tile label="Message count" value={@info.message_count} />
            </div>
            <.key_value density={:dense}>
              <:item key="First timestamp">{@info.first_timestamp || "N/A"}</:item>
              <:item key="Last timestamp">{@info.last_timestamp || "N/A"}</:item>
            </.key_value>
            <:footer>
              <a href={~p"/export/#{@info.agent}?kind=events"} class="ds-btn ds-btn--primary ds-btn--sm" download>
                <.mark name="m-download" size={14} /> Events JSON
              </a>
              <a href={~p"/export/#{@info.agent}?kind=messages"} class="ds-btn ds-btn--primary ds-btn--sm" download>
                <.mark name="m-download" size={14} /> Messages JSON
              </a>
            </:footer>
          </.card>
        </div>
      </div>
    </div>
    """
  end
```

The export links stay anchors (they download), styled with the design system's own button classes since gos-ui's `button` only renders `<button>`. The DETS file path in a stat tile is long; `overflow-hidden` plus the tile's `min-width:0` truncates it, and the full path is still in the DOM.

- [ ] **Step 3: Run the view tests**

```bash
cd /home/imsmith/github/agento && MIX_ENV=test mix test test/agento_web/live/system_live_test.exs > /tmp/agento-test.log 2>&1; tail -5 /tmp/agento-test.log
```

Expected: pass. The stat label is rendered uppercase by CSS only, so the DOM text is "Event count"; keep whichever branch of the `or` assertion in step 1 is true and delete the other.

- [ ] **Step 4: Visual check** on `/system`: walk all six tabs, confirm alive/dead badges on the tree, the stat tiles on DurableLog, the error alerts under their category tags.

- [ ] **Step 5: Commit**

```bash
cd /home/imsmith/github/agento && git add lib/agento_web/live/system_live.ex test/agento_web/live/system_live_test.exs && git commit -m "web: system view on gos-ui"
```

---

### Task 12: Home page

**Files:**
- Modify: `/home/imsmith/github/agento/lib/agento_web/controllers/page_html/home.html.heex` (whole file)
- Modify: `/home/imsmith/github/agento/lib/agento_web/controllers/page_controller.ex` (only if it does not already pass `flash`)
- Test: `/home/imsmith/github/agento/test/agento_web/controllers/page_controller_test.exs` (exists? if not, create)

**Interfaces:**
- Consumes: `Layouts.app`, `card`, `button` as link styling, `mark`.

- [ ] **Step 1: Write the failing test**

Create or extend `test/agento_web/controllers/page_controller_test.exs`:

```elixir
defmodule AgentoWeb.PageControllerTest do
  use AgentoWeb.ConnCase

  test "GET / is the shell with a view index", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)
    assert html =~ ~s(class="ds-shell)
    for path <- ~w(/chat /events /system /tools /hub /rules), do: assert(html =~ ~s(href="#{path}"))
    refute html =~ "Phoenix Framework"
  end
end
```

Run; expect failure (the Phoenix splash is still there).

- [ ] **Step 2: Replace home.html.heex**

The Phoenix splash page is replaced by a short index of the six views. Nothing else was on it.

```heex
<Layouts.app flash={@flash} active_nav={:home}>
  <div class="max-w-[72ch] space-y-2">
    <h1 class="text-h1">LLMAgent</h1>
    <p class="ds-prose">
      Agents, their events, the runtime underneath, the tools they may call, the hub that serves private
      LLMs to coding clients, and the rules this machine runs. Pick a view.
    </p>
    <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-2">
      <.card :for={{path, mark, title, blurb} <- views()} title={title} density={:compact} interactive phx-click={JS.navigate(path)}>
        <div class="flex items-start gap-1">
          <.mark name={mark} size={20} />
          <p class="text-small text-muted">{blurb}</p>
        </div>
        <:footer><a href={path} class="ds-btn ds-btn--text ds-btn--sm">Open <.mark name="m-chevron" size={12} /></a></:footer>
      </.card>
    </div>
  </div>
</Layouts.app>
```

`active_nav: :home` matches no menu id, so nothing is highlighted. In `page_html.ex`, add the `views/0` helper the template calls:

```elixir
  def views do
    [
      {"/chat", "m-chat", "Chat", "Talk to a running agent; start and stop agents."},
      {"/events", "m-event", "Events", "The live event stream, and the durable and in-memory logs."},
      {"/system", "m-system", "System", "Supervision tree, ETS, contexts, errors, modules, DurableLog."},
      {"/tools", "m-tool", "Tools", "The tool registry; describe and invoke a tool by hand."},
      {"/hub", "m-hub", "Hub", "The private LLM hub: performers, clients, recent turns."},
      {"/rules", "m-event", "Rules", "Loaded policies, what an event would do, the trace."}
    ]
  end
```

If `page_html.ex` does not already `use AgentoWeb, :html` with `embed_templates`, read it first; the helper goes in that module.

- [ ] **Step 3: Run**

```bash
cd /home/imsmith/github/agento && MIX_ENV=test mix test test/agento_web/controllers > /tmp/agento-test.log 2>&1; tail -5 /tmp/agento-test.log
```

Expected: pass. If `Layouts.app` complains about `active_nav: :home` not being an atom in some list, it is declared `:atom` with no `values:`; it accepts it.

- [ ] **Step 4: Commit**

```bash
cd /home/imsmith/github/agento && git add lib/agento_web/controllers/page_html/home.html.heex lib/agento_web/controllers/page_html.ex test/agento_web/controllers/page_controller_test.exs && git commit -m "web: home page is a view index on gos-ui"
```

---

### Task 13: Removal: daisyUI, heroicons, old core components, theme wipe, vocabulary lint

**Files:**
- Modify: `/home/imsmith/github/agento/assets/css/app.css` (drop plugins, add `--*: initial`)
- Delete: `/home/imsmith/github/agento/assets/vendor/daisyui.js`, `/home/imsmith/github/agento/assets/vendor/daisyui-theme.js`, `/home/imsmith/github/agento/assets/vendor/heroicons.js`
- Modify: `/home/imsmith/github/agento/mix.exs` (drop `heroicons`)
- Modify: `/home/imsmith/github/agento/lib/agento_web/components/core_components.ex` (keep only `translate_error/1`, `translate_errors/2`)
- Modify: `/home/imsmith/github/agento/test/agento_web/design_system_test.exs` (vocabulary lint)

**Interfaces:**
- Produces: the drift guard. After this task no off-system class can enter `lib/agento_web` without a failing test.

- [ ] **Step 1: Write the failing lint test**

Append to `test/agento_web/design_system_test.exs`:

```elixir
  @forbidden ~w(
    btn card badge alert navbar collapse loading toast tabs tab-active menu-item
    table-zebra table-xs table-sm input-bordered select-bordered textarea-bordered
    fieldset label chat chat-bubble
    hero- bg-base- text-base-content text-xs text-sm text-lg text-xl text-2xl
    font-semibold rounded-full rounded-box opacity-
  )

  # Every class attribute, single-line (class="...") or multi-line (class={[ ... ]}),
  # read from the whole file so continuation lines are not missed.
  @class_attr ~r/class=(?:"([^"]*)"|\{\s*\[(.*?)\]\s*\})/s

  test "no off-system class vocabulary survives in the web tier" do
    offenders =
      for path <- Path.wildcard("lib/agento_web/**/*.{ex,heex}"),
          source = File.read!(path),
          [_whole | groups] <- Regex.scan(@class_attr, source),
          word <- String.split(Enum.join(groups, " "), ~r/[\s"\[\],&|?:(){}=!]+/, trim: true),
          Enum.any?(@forbidden, &(word == &1 or (String.ends_with?(&1, "-") and String.starts_with?(word, &1)))),
          uniq: true,
          do: "#{path}: #{word}"

    assert offenders == [], Enum.join(["off-system classes:" | offenders], "\n  ")
  end
```

Run; expect failure listing anything missed in Tasks 5 to 12 (the `chat` words in chat_live are now `chat-msg`, which is not in the list; `ds-tab` is not `tab-active`).

- [ ] **Step 2: Fix every offender the test lists**

Each line is a template site still using the old vocabulary. Convert it per the mapping table in the spec and the halving rule in Global Constraints. Re-run until the list is empty.

- [ ] **Step 3: Remove the plugins and wipe the default theme**

In `assets/css/app.css` delete the three `@plugin` blocks and the TRANSITIONAL comment line, and add `--*: initial;` as the first line inside `@theme { ... }` so the block begins:

```css
@theme {
  --*: initial;
  --spacing: 0.5rem; /* p-1 = 8px, p-0.5 = 4px: the design-system scale */
```

Delete the vendor files:

```bash
cd /home/imsmith/github/agento && git rm assets/vendor/daisyui.js assets/vendor/daisyui-theme.js assets/vendor/heroicons.js
```

In `mix.exs` remove the `{:heroicons, ...}` entry, then `mix deps.unlock --unused`.

- [ ] **Step 4: Gut CoreComponents**

Replace `lib/agento_web/components/core_components.ex` with:

```elixir
defmodule AgentoWeb.CoreComponents do
  @moduledoc """
  What is left after the design system: error translation for forms.
  Components come from `GosUi.Components` and `AgentoWeb.DS`.
  """
  use Phoenix.Component

  @doc "Translates an error message using gettext."
  def translate_error({msg, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(AgentoWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(AgentoWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc "Translates the errors for a field from a keyword list of errors."
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
```

- [ ] **Step 5: Build, compile strictly, run everything**

```bash
cd /home/imsmith/github/agento && mix assets.build > /tmp/agento-assets.log 2>&1; tail -3 /tmp/agento-assets.log && MIX_ENV=test mix compile --warnings-as-errors > /tmp/agento-compile.log 2>&1; tail -3 /tmp/agento-compile.log && MIX_ENV=test mix test > /tmp/agento-test.log 2>&1; tail -6 /tmp/agento-test.log
```

Expected: assets build; no warnings; full suite green including the lint test. Check `priv/static/assets/css/app.css` size dropped substantially (daisyUI gone):

```bash
wc -c priv/static/assets/css/app.css
```

- [ ] **Step 6: Final visual pass**

Start the server, walk all seven pages in tron dark, matrix dark, compaq light. Look for: unstyled elements (a missed utility renders as nothing, so a missing padding or border is the symptom), focus rings on every control, every badge with a mark, no glow in light mode, nothing rounder than 6px.

- [ ] **Step 7: Commit**

```bash
cd /home/imsmith/github/agento && git add -A && git commit -m "web: remove daisyUI and heroicons; Tailwind theme wiped to tokens; vocabulary lint"
```

---

### Task 14: Branch wrap-up

- [ ] **Step 1: Precommit alias**

```bash
cd /home/imsmith/github/agento && mix precommit > /tmp/agento-precommit.log 2>&1; tail -8 /tmp/agento-precommit.log
```

Expected: compile clean, nothing unused in the lock, formatted, tests green. If `mix format` changed files, commit them: `git commit -am "style: mix format"`.

- [ ] **Step 2: Report**

Leave the three branches unpushed and unmerged. Report to the user: the design-system commit, the gos-ui commit SHA agento pins, the agento commit list, the full-suite result line, and anything skipped with the reason.
