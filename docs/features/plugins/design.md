---
description: Why baguette's plugin system is shaped as it is — subprocess-only plugins, per-invocation capability tokens, a browser that can install but not trust, and host-drawn controls instead of glyphs.
---

# Plugins & bakeries — design

## Path

- The rail and `baguette plugin run` → `POST /plugins/:id/commands/:cmd` →
  `PluginDispatch` spawns the manifest's `run` argv (cwd = the plugin
  directory) with a fresh per-invocation grant → the command prints one JSON
  object.
- Every route the command calls back passes `PluginGrantMiddleware`, which
  checks the grant's capability set against the route before any handler
  runs.
- `baguette bakery add` / `plugin install` / `POST /bakeries/install` →
  a shallow, pinned git checkout into `~/.baguette/` and a copy of the plugin
  directory. No code runs.

## Why a token per invocation

Each command invocation is handed its **own** token carrying exactly that
plugin's declared set, revoked the moment the command exits. The check runs
in front of every route, not inside the handful that remember to ask, so a
plugin without `input` gets a `403` even though its token is otherwise valid.
A shared session secret couldn't do any of this: every plugin would present
the same credential, so the server could never tell who was calling.

The capability token is revoked the moment the command ends, however it
ended. A child that outlived its parent's request has no credentials.

## Why the capabilities split where they do

`apps` and `media` are deliberately separate: one puts a picture in the
photo library, the other puts an executable on the device.

`open-url` sits apart from `apps` for the same reason in the other
direction — it only launches software that is already there. Reading and
opening are one capability rather than two, on the `interface`
precedent: a plugin that can open *any* URL isn't meaningfully
restrained by hiding the list of which ones an app registered.

The browser's drag-and-drop endpoint, `POST /simulators/:udid/files`,
takes either and works out which from the file — convenient for a person
who picked the file, useless as a boundary. It is reachable by **no**
capability, so plugins use the two routes above and say which power they
mean.

Unknown capabilities are a parse error so typos surface at
`baguette plugin validate` rather than as a confusing runtime `403`.

## Why the browser can install but not trust

Installing writes files into a directory baguette later executes from,
and the only thing in front of a browser route is a set of origin
heuristics — well tested, but heuristics. So the install route names a
bakery by its **recorded id**, never a URL or a git ref. A request can
only reach a source already in `bakeries.json`, at the commit pinned
there, and a name that bakery's own menu lists. If an origin check is
ever wrong, the blast radius is "installs a plugin from a repo you
already vetted" rather than "clones anything and writes it to your
disk". A refusal never echoes the id it was given back into the page.

Trusting a *new* source stays a terminal act, because a modal button
isn't real consent — the page sets the flag it then checks — and
because trust is the decision that actually matters. Typing the command
carries context a web page can't.

The decision is `InstallDecision` in `Plugins/Bakery/`, and every
refusal path is unit-tested; installing still only copies files, so
nothing runs until you open the plugin's panel.

## Why ticks aren't glyphs

A settings list needs rows that are *on* or *off*. Before this, a plugin
wrote that into the row title — `display.py` shipped `"● Light"` /
`"○ Dark"` — which is a plugin drawing a control glyph inside a string,
in a page whose whole premise is that the host owns every pixel. Escaping
made it safe, not right: the host couldn't style it, a screen reader read
a bullet, and "which one is on" was legible only to a human eye.

So the row says what's on, and the manifest says what on looks like
(`body.control`). An unknown `control.kind` is a parse error rather than a
fallback — unlike an unknown `icon`, which draws `puzzle` — because a checkbox
silently drawn as a switch would misrepresent whether ticking two at once is
allowed: a lie about behaviour, not a substituted picture.

## Why additions don't bump `apiVersion`

`prompt` and `control` are additive: a baguette that predates them ignores the
key and renders the plain list, so `apiVersion` stays 1. baguette refuses a
*newer* `apiVersion` outright rather than guessing at shapes it can't
interpret, and an omitted one means 1 permanently — that's what manifests
written before the field existed meant.
