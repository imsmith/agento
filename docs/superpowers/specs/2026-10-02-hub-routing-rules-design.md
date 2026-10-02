# The hub's routing as rule files

**Date:** 2026-10-02 · **Branch:** `hub-rules` · item 5 of the Anemos program

## What

`Agento.Hub.Router.route/3` asks the rules first. Every turn is dispatched
into the `:agento` runtime as `HUB_ROUTE`, context path `hub.route`, with
facts `?client`, `?requested_model`, `?serving_host`, `?default_host`,
`?hosts`, `?models`. A rule answers through `HUB`, bound in the runtime
from the start (`Agento.Hub.RouteVerb`): `[HUB::route :host|:model|:ad_id
...]` or `[HUB::refuse :because "..."]`. The first answer wins; a refusal
is a 403 to the client, recorded like any refused turn.

No answer — no rule, no match, or the runtime silent for a second — and
the built-in choice stands, unchanged: the host serving the model, else
the default host, else 404. `priv/rules/hub-routing.rule` says that choice
in rules; the installer writes it to `~/.config/agento/rules/` once and
never again.

## What the review added

- Answers are tagged as `HUB`'s; a tool's result shaped like one is not an
  answer. A refusal beats a route. Among routes the runtime's order
  decides — the most recently loaded policy first, and within a policy
  the later rule — which the README, the rule file and the router say
  plainly, with the advice to write rules whose conditions exclude each
  other.
- The shipped rule routes by `:model ?requested_model`, not by host: one
  host serving two models would otherwise get the wrong one.
- The installer writes `:rules {:dir ...}` into the generated hub.edn, so
  a non-home `--prefix` watches where it installed the rule.
- The shipped-rule test checks the trace: the rule fired and answered,
  not merely that the built-in choice would have agreed.
- Not changed: a `HUB_ROUTE` rule that calls a tool makes every turn wait
  for it, up to the second; the rule file says not to.

## Rulings

1. **A rule chooses within the client's candidates, never beyond.** An
   answer naming a host or model the policy does not admit is logged and
   ignored. Reach is the hub configuration's; rules spend it.
2. **The built-in routing stays.** A machine with no rule files routes as
   before. The shipped file is a worked example, not a dependency.
3. **One second.** Routing waits that long for the rules; a wedged runtime
   costs a turn a second, not the turn.
4. **The hub asks, the rules answer; nothing is dispatched by the rules
   into the turn.** `HUB_ROUTE` carries facts, not the request body.
