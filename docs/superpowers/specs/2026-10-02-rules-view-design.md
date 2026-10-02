# The rules view

**Date:** 2026-10-02 · **Branch:** `rules-view` · item 4 of the Anemos program

## What

Agento runs one `Anemos.Runtime`, `:agento`, watching
`:rules {:dir ...}` from the hub configuration (default
`~/.config/agento/rules`), with `LLMAgent.Anemos` attached under a policy
whose allow list is `:rules {:tools [...]}` (default empty: a rule can call
no tool). `Agento.Rules` is the module; `AgentoWeb.RulesLive` at `/rules` is
the view.

The view shows, refreshed every two seconds: the policies loaded and
whether each came from a file (and whether that file is currently broken),
every rule with the events it listens for, its context and its `set` and
dwell state, conditions with their values, schedules with when they last
fired, the tools a rule may call, and the last fifty dispatches with the
rules each reached and what came of it. It deploys a policy typed into it,
unloads one, and explains what an event with a context path would reach
without dispatching it.

## Rulings

1. **Tool rights are opt-in, in the hub configuration**, by coordinate
   pattern, like a client's reach. The default is none.
2. **Polling, two seconds.** The trace lives in an ETS ring the view reads;
   a push on every event would be a push on every event.
3. **The form deploys under a policy name like a file would**, and a file
   of the same name replaces it on its next save. The view says so.
4. **Nothing in the view needs a login**, like the rest of the UI. It shows
   rule text's effects, never the turn bodies; a `log` statement's text is
   shown, since the author chose to log it.
