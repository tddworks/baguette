---
description: Proposed design for `baguette mcp`, one long-lived process that gives an agent the short read, fill and tap-by-name as MCP tools, with measured numbers for one-shot commands, a session and the HTTP API. Nothing here is built yet.
---

# `baguette mcp` — "one process per device, a few tools"

**Status:** DESIGN, not built, 2026-11-06. `baguette mcp` and `McpCommand` don't exist. Everything it would call does, at `e1b04257`. Not yet a decision to build it: see [Should it exist?](#should-it-exist).

This document owns **how an MCP server would reach baguette**. It adds no rules. Its neighbours own the rest:

| For | Read |
|---|---|
| The benchmark, and why reads and fills are shaped as they are | [agent performance](agent-performance.md) |
| The tree, the words, the laws and their owners | [CANONICAL_MODEL](../../CANONICAL_MODEL.md) |
| The JSON `baguette input` already speaks | [wire.md](../../wire.md) |

---

## The one sentence

**`baguette mcp` is a third way in, beside `baguette input` and `baguette serve`, that keeps one process alive so an agent stops paying startup on every call.**

```text
 MCP client ── stdio JSON-RPC ──> McpCommand (App: parses, calls, prints)
                                    ├ DescribeUIDispatch   read
                                    ├ LabelTap             tap by name
                                    ├ FillDispatch         fill
                                    └ GestureDispatcher    swipe, press, …
                                            │
                                  Domain, then Input → IndigoHIDInput
```

## What it would buy

The same sign-in on the [benchmark](agent-performance.md#results)'s form, iPhone 17 Pro, iOS 27.0, Device Hub open and healed, 14-core M4 Pro, median of 3:

| Way in | Sign-in | Tokens | `ok` means | Exists today |
|---|---|---|---|---|
| One command per step (`describe-ui --short`, `fill`, `tap`) | 5.14 s | 219 | the field shows the text; the tap's answer shows the new screen | yes |
| One `baguette input` session | 4.06 s | about 219 | the same | yes |
| HTTP API (`baguette serve`), as it is | 3.03 s of calls, plus 1.3 s of waits | **2,380** | sent, not landed | yes |
| `baguette mcp` | about 4 s (projected) | about 220 (projected) | the same as a session | no |
| simulator-use, published, on a 6-core virtual Mac | 3.50 s | 194 | what changed | |

### The HTTP API, measured

`GET /simulators/:udid/describe-ui.json` and `POST /simulators/:udid/input` signed in 3 of 3. They are the fastest calls, because they verify nothing:

| Step | Median |
|---|---|
| Read the whole tree | 790 ms |
| Tap at a point | 186–202 ms |
| Type email (16 characters) | 691 ms |
| Type password (7 characters) | 389 ms |
| Last read | 552 ms |

What that speed leaves to the caller:

- **Tokens:** only the full tree exists there: about 1,160 tokens per read. `?short=true` is ignored.
- **Finding things:** `{"type":"fill",…}` answers `unknown kind: fill`, `{"type":"tap","label":…}` answers `missing field: x`, and `describe_ui` answers `unknown kind`. So a caller reads frames and computes points.
- **Waiting:** nothing settles. The run above needed 1.3 s of guessed sleeps, 0.5 s before each typed field and 0.3 s after the tap, and those are in no tool's numbers.
- **Checking:** `ok` means sent. With Device Hub holding the input, every call would still say `ok`.

So the API isn't a faster way to do the same job. It does less of the job.

## Should it exist?

Not yet. A session already gets most of the gain, with no new code:

| Gap to simulator-use's 3.50 s | |
|---|---|
| One command per step | 1.64 s |
| One `baguette input` session | 0.56 s |

An MCP server's real advantages are installation and discovery, not speed: an agent gets the tools without a skill, and one that can't keep a subprocess open between calls gets a session anyway. Build it when agents need that. Measure first whether they find `baguette input` from the skill, with the with-skill and without-skill test on Skylark.

## 1 · Ubiquitous language

| Term | Meaning | Not to be confused with |
|---|---|---|
| **tool** | one MCP call an agent can make, named after the CLI verb | a gesture, which only reaches `Input` |
| **tool list** | what the server costs an agent's context before its first call | the answers it reads afterwards |

## 2 · Where it fits

No node is added to the [tree](../../CANONICAL_MODEL.md#1--the-tree), and no role. MCP is a transport, like the stream WebSocket: it parses, calls, and prints.

The existing dispatchers already take a line and answer a line, so a tool call becomes the envelope `baguette input` would have read. `McpCommand` shares that loop with `InputCommand`, and neither owns a rule.

## 3 · The tools

Few, because each costs every session. simulator-use's 12 tools cost 2,443 tokens; agent-device's 62 cost 47,406. Target: **under 1,500 tokens**.

| Tool | Becomes | Answers |
|---|---|---|
| `describe_ui` | `describe_ui`, short unless `full` is set | the short answer |
| `tap` | `tap` with `label`, `then_describe_ui` | what changed and what's next |
| `fill` | `fill` | what the field shows |
| `swipe` | `swipe`, `then_describe_ui` | whether it moved |
| `press` | `press` | `ok` |
| `launch` | `baguette launch --then-describe-ui` | the first screen |
| `screenshot` | `baguette screenshot` | an image |

Anything else stays on the CLI, reached through the shell. `tap` by point isn't a tool: an agent that needs it has the CLI.

## 4 · Invariants (each law, one owner)

| # | Law | Owner |
|---|---|---|
| 1 | stdout carries only the protocol; every log goes to stderr, and `trace` stays off | `McpCommand` |
| 2 | one process holds one device's `Input` for its life, so HID and accessibility warm up once | `McpCommand` |
| 3 | a tool's answer is the line the dispatcher answered, unchanged, so the CLI, a session and MCP can't drift | `McpCommand` |

Every other law stays with its owner: a fill's in `Fill`, a settled screen's in `AXSettle`.

## 5 · Build sequence (test-first, each slice green)

0. **A skill line first.** Point `skills/baguette` at `baguette input` for multi-step flows, and measure.
1. **The loop.** Lift `InputCommand`'s dispatch chain so both commands share it. *Pinned: `should answer a fill line the same way in either command`.*
2. **JSON-RPC.** `initialize`, `tools/list`, `tools/call`, by hand. *Pinned: `should list every tool`, `should keep the tool list under its budget`, `should answer an unknown tool as an error`.*
3. **Wiring.** `McpCommand`, `RootCommand`, parsing tests, an MCP client smoke test.
4. **Compare.** Add it to the harness as a real MCP adapter, and replace the projections above.

## 6 · Open questions

1. **Should the HTTP API also get `short`, `fill` and tap by name?** Recommendation: only if a consumer asks. A page already has the tree and computes points. The dispatchers would make it small: a route that runs the same chain.
2. **Does `Fill` run on the main actor from here?** `Fill.execute` is `@MainActor`, and it's the same hop `baguette input` already takes.
3. **One device per process, or a `udid` on every tool?** Recommendation: one, named by a `use_device` tool or a flag. A `udid` on every call costs tokens each time.
4. **Is a daemon better than stdio?** A shared daemon would also speed up one-shot commands, but it adds a lifecycle to manage: starting, stale processes, version mismatches. Recommendation: stdio first, since the client owns its lifetime.
5. **What about Device Hub opened mid-session?** The input is taken for that process too. `FillOutcome.inputTaken` already says so; a tap can't tell.
