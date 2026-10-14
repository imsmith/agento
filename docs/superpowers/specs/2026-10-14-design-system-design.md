# Applying the GRID·OPS design system to agento

Date: 2026-10-14. Status: approved in conversation, pending written review.

## Intent

Re-skin agento's web tier (six LiveViews and the home page) to the
[imsmith/design-system](https://github.com/imsmith/design-system) through
[imsmith/gos-ui](https://github.com/imsmith/gos-ui). No functional behavior
changes in any view. The existing web test suite stays green throughout.

## Decisions

- **daisyUI and heroicons go.** Tailwind 4 stays as a layout-only utility
  layer with its default theme wiped and rebuilt from design-system tokens, so
  no utility can emit an off-system value.
- **Theme is browser-persisted.** Default `tron` dark. Two localStorage keys,
  `gos:theme` and `gos:mode`, applied to `<html>` before first paint. All three
  anchors and both modes switchable through gos-ui's `theme_switch`, driven by
  a client hook with no server round-trip.
- **Missing marks are authored upstream first.** Nine UI marks added to
  design-system, synced into gos-ui, then consumed. No second icon grammar.
- **Sequencing is shell first, then one view per commit, removal last.** Both
  stylesheets coexist for the middle of the branch; the app runs at every
  commit.
- **Work lands on a branch in the agento checkout**, not a worktree, because
  agento's path dependency on `../llmagent` does not resolve from a worktree.
  gos-ui is a GitHub dependency pinned to a commit.

## 1. Upstream marks (design-system, branch `marks-agento`)

Nine marks, each authored in `tokens/marks.edn`, `assets/marks/sprite.svg`,
and the marks chapter table. 24x24, 2px monoline, round caps and joins,
`currentColor`. None reuses a reserved status silhouette.

| Mark | Replaces heroicon | Used for | Group | Unicode / ASCII | Nerd |
| --- | --- | --- | --- | --- | --- |
| `m-chat` | chat-bubble-left-right | Chat nav | nav | nil / `chat` | f086 `nf-fa-comments` |
| `m-event` | bolt | Events and Rules nav | nav | nil / `ev` | f0e7 `nf-fa-bolt` |
| `m-system` | server-stack | System nav | nav | nil / `sys` | f233 `nf-fa-server` |
| `m-tool` | wrench-screwdriver | Tools nav, tool blocks | object | nil / `tool` | f0ad `nf-fa-wrench` |
| `m-hub` | arrows-right-left | Hub nav | nav | `⇄` / `<->` | f0ec `nf-fa-exchange` |
| `m-agent` | cpu-chip | Brand, agent rows | object | nil / `agt` | f2db `nf-fa-microchip` |
| `m-run` | play | Run and start actions | action | `▶` / `>` | f04b `nf-fa-play` |
| `m-send` | paper-airplane | Send message | action | `➤` / `->` | f1d8 `nf-fa-paper_plane` |
| `m-external` | arrow-top-right-on-square | Open in new tab | action | `↗` / `^` | f08e `nf-fa-external_link` |

Existing marks cover the rest: `m-refresh` (arrow-path), `m-close` (x-mark),
`m-delete` (trash), `m-download` (arrow-down-tray), `m-add` (plus),
`m-settings` (cog), `m-info` (information-circle), `m-chevron` rotated
(chevron-right, chevron-down), and the status shapes where check-circle and
the exclamation icons signal severity. Sun, moon and desktop vanish with the
old toggle.

Verification: `make tcl-check`, `make gen-fresh`, `make specimen`, then
inspect the new symbols in `specimen.html`. APCA and markdownlint in the
`design-system` distrobox if present. One commit.

Then in gos-ui, branch `sync-marks`: `make sync` against that checkout,
`make check`, one commit. Its SHA is what agento pins.

## 2. Tailwind remap and root layout (agento)

### `assets/css/app.css`

Preflight is dropped; design-system `base.css` owns element defaults.

```css
@layer theme, base, components, utilities;
@import "tailwindcss/theme.css" layer(theme);
@import "tailwindcss/utilities.css" layer(utilities) source(none);
@source "../../lib/agento_web";

@theme {
  --*: initial;
  --spacing: 0.5rem;              /* p-1 = 8px, p-0.5 = 4px half-step */
  --breakpoint-sm: 640px; --breakpoint-md: 768px; --breakpoint-lg: 1024px;
  --breakpoint-xl: 1280px; --breakpoint-2xl: 1536px;
  --font-weight-regular: 400; --font-weight-medium: 500; --font-weight-bold: 700;
}

@theme inline {
  --color-bg: var(--bg); --color-surface: var(--surface);
  --color-surface-raised: var(--surface-raised); --color-text: var(--text);
  --color-muted: var(--muted); --color-border: var(--border);
  --color-accent: var(--accent); --color-on-accent: var(--on-accent);
  --color-status-critical: var(--status-critical);
  --color-status-high: var(--status-high);
  --color-status-medium: var(--status-medium);
  --color-status-low: var(--status-low);
  --color-status-unknown: var(--status-unknown);
  --font-mono: var(--font-mono); --font-prose: var(--font-prose);
  --text-micro: var(--text-micro); --text-caption: var(--text-caption);
  --text-small: var(--text-small); --text-body: var(--text-body);
  --text-lead: var(--text-lead); --text-h3: var(--text-h3);
  --text-h2: var(--text-h2); --text-h1: var(--text-h1);
  --text-display: var(--text-display);
  --radius-sm: var(--radius-sm); --radius-md: var(--radius-md); --radius-lg: var(--radius-lg);
  --leading-tight: var(--leading-tight); --leading-snug: var(--leading-snug);
  --leading-normal: var(--leading-normal);
  --tracking-label: var(--tracking-label);
}

[data-phx-session], [data-phx-teleported-src] { display: contents }
```

Breakpoints are from `space.edn`. `--*: initial` lands in the removal commit
(section 4, step 10); until then the daisyUI plugin lines remain so views
ahead of the cursor still render.

### `root.html.heex`

Links `/gos-ui/styles.css` before `app.css`. `<html data-theme="tron">` as
the no-script default. A pre-paint script reads `gos:theme` and `gos:mode`
and writes `data-theme` and `data-mode`. `<.sprite />` once inside body.
Body keeps `h-screen flex flex-col` as utilities.

### `endpoint.ex`

`plug Plug.Static, at: "/gos-ui", from: {:gos_ui, "priv/static/gos-ui"}, gzip: false`
ahead of the app static plug.

### `assets/js/app.js`

Spread `GosUiHooks` into the hooks map. Add one hook, `ThemeSwitch`, attached
to the `theme_switch` form: on change, write the two keys, set the attributes
on `<html>`, do not send to the server. Delete the `phx:set-theme` listener
and the `phx:theme` key.

### `mix.exs`

Add `{:gos_ui, github: "imsmith/gos-ui", ref: "<sha>"}`. In the removal
commit drop `heroicons`.

## 3. Component mapping

Every daisyUI class maps to one gos-ui component or one native element. No
adapter. `core_components.ex` keeps only view-specific blocks; its generic
`flash`, `input`, `header`, `table`, `list`, `icon` are deleted.

| daisyUI today | Becomes | Notes |
| --- | --- | --- |
| `navbar` + nav links + `theme_toggle` | `app_shell` with `menu variant={:sidebar}` in nav slot, `theme_switch` in actions | Nav moves to the shell sidebar. Brand slot: `m-agent` + LLMAgent. |
| `btn*` | `button variant={:primary\|:ghost\|:danger} size={:sm}` | Warning buttons become ghost with a label. Icons via `icon` attr as mark ids. |
| `card` | `card` with head, body, foot slots | Dense panels use `compact` or `dense`. |
| `table*` | `table rows={...} density={:dense}` with column slots | Hand-built row loops rewrite to row data plus col slots. |
| `input*` | `input` | Errors via `error` attr (critical border + `m-critical` + message). |
| `select*` | `select options={...} value={...}` | |
| `textarea*` | `textarea` | |
| `label`, `fieldset`, `form-control` | `fieldset legend=...` | |
| `badge*` | `status_badge step={...}` when severity, else `tag` | Display word from the status lexicon: DOWN, ALERT, WARN, OK, UNK. |
| `alert*` | `alert severity={:medium\|:critical}` | Copy reshaped: what happened, why, what to do. |
| `toast`, `flash_group` | `flash_toasts flash={@flash}` | Auto-dismiss from `GosUiHooks`. |
| `tabs*` | `tabs tabs={...} active={...} select="event"` | |
| `collapse*` | native `<details>` / `<summary>` with `m-chevron` | No gos-ui equivalent; two sites; not worth an upstream component. |
| `loading*` | `button loading` or `state_panel mode={:loading}` | |
| `icon name="hero-*"` | `mark name="m-*"` | Per section 1. |
| `bg-base-*`, `text-base-content/*` | `bg-surface`, `bg-surface-raised`, `text-muted`, `border-border` | From the remapped palette. |
| `text-xs`, `text-sm`, `font-semibold`, `font-mono` | `text-caption`, `text-small`, `font-medium`, dropped | Mono is already the body voice. |

Semantic components taken where the data already exists, nowhere else:
`log_view` for the durable log and live stream panels (Events, System),
`key_value` for config and ETS detail blocks, `freshness` beside live streams,
`stat_tile` for System counters.

## 4. Branch and commit order

Nothing is pushed by the implementer.

1. design-system `marks-agento`: nine marks, regenerate, specimen, tcl-check.
2. gos-ui `sync-marks`: `make sync`, `make check`. SHA pinned by agento.
3. agento `design-system`, tests green after each commit:
   1. **Foundation.** gos-ui dep, static plug, root layout, Tailwind remap
      (without `--*: initial`), app.js hooks, theme pre-paint script. daisyUI
      plugin lines kept so old views render.
   2. **Shell.** `layouts.ex` to `app_shell` + sidebar menu + `theme_switch`.
      `theme_toggle` and `flash_group` deleted, `flash_toasts` in.
   3. **Tools view** (207 lines).
   4. **Hub view** (232).
   5. **Rules view** (374). First `key_value`.
   6. **Chat view** (776). Send, textarea, chat message, tool dispatch/result blocks.
   7. **Events view** (784). `log_view`, `freshness`, event detail, `<details>`.
   8. **System view** (904). `stat_tile`, tree node, ETS and modules panels.
   9. **Home page** (`home.html.heex`, 202).
   10. **Removal.** daisyUI vendor files, heroicons plugin and dep, generic
       core_components, old theme remnants, `--*: initial`, and the
       vocabulary lint test (section 5).

Each view commit carries its template, any assigns reshaping, and its test
updates together. Views ahead of the cursor keep rendering on daisyUI.

## 5. Testing and verification

Tailwind 4 silently ignores unknown classes; the build is not a checker.

- **Vocabulary lint test.** `test/agento_web/design_system_test.exs` reads
  every file under `lib/agento_web` and fails on any forbidden token: the
  daisyUI component vocabulary (`btn`, `card`, `badge`, `alert`, `navbar`,
  `collapse`, `loading`, `table-zebra`, `input-bordered`, `select-bordered`,
  and the rest), `hero-`, `bg-base-`, `text-base-content`, `text-xs`,
  `text-sm`, `font-semibold`, `rounded-full`. Also asserts the rendered root
  layout links `/gos-ui/styles.css` and carries `data-theme`. Lands in the
  removal commit and stays as the drift guard.
- **Existing suite.** About 2,500 lines of web tests are the behavioral net.
  Tests selecting on a daisyUI class are repointed at an id or `ds-` class in
  the same view commit. No test is deleted. agento's suite runs serially
  (shared DETS) with output redirected to a file, never piped.
- **Per-view visual check.** After each view commit, run the app, screenshot
  the view in tron dark and compaq light, compare against `specimen.html`.
  Look for: focus outline on every control, every status badge carrying its
  mark, no glow on light surfaces, nothing rounder than 6px, no body text in
  Grotesk.
- **Upstream checks.** design-system: `make tcl-check gen-fresh specimen`,
  plus APCA and markdownlint if the distrobox exists. gos-ui: `make check`.
- **Not covered.** No automated contrast check against agento's rendered
  pages. The design-system's APCA verification covers the token pairs agento
  consumes, so the guarantee is inherited, not re-measured.
