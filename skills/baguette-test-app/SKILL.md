---
name: baguette-test-app
description: |
  Test an iOS app the way a person uses it: read the simulator's screen, decide
  what's next, click, and check what happened, with the `baguette` CLI. Use when
  asked to test, QA, verify or walk through an app or a user flow on a simulator,
  check that a change works on screen, or complete a task inside an app ("book a
  flight", "sign up and check the receipt"). For the commands themselves, or for
  driving a simulator without testing anything, use the `baguette` skill.
---

# Test an app with baguette

The test is a loop you do yourself, not a script you write:

**read the screen → think what's next → click → check it worked.**

Your judgment is the point. A script can only find what it was told to look
for; you can notice that the price is wrong.

## Before you start

```bash
baguette list --json                                            # a booted UDID
baguette boot --udid <X>                                        # if none is running
xcrun simctl install <X> path/to/App.app                        # if it isn't installed
```

If the user wants to watch, start `baguette serve` and give them
`http://localhost:8421/simulators/<X>`.

Write down what success looks like before the first click, in the user's words.
"Booked" isn't enough: "the fastest flight, a window seat near the front, the
saved card".

## The loop

**1. Open the app and read the screen, in one call.**

```bash
baguette launch --udid <X> --bundle-id <id> --relaunch --then-describe-ui
```

It waits for the first real screen, usually 4 to 5 seconds. To read at any
other time, use `baguette describe-ui --udid <X>`.

**2. Think.** Which element does the task need next? Read the values, don't
assume: the first row is rarely the fastest, and `Search flights` may be disabled.

**3. Tap by name.** Every answer is short, and says what you can do next and what
the screen says:

```json
{"ok":true,"changed":true,"tapped":"Search flights","screen":{"width":402,"height":874},
 "affordances":{
   "home":"baguette press --udid X --button home",
   "screenshot":"baguette screenshot --udid X --output /tmp/baguette-screen.jpg",
   "tap":"baguette tap --udid X --label \"<name>\" --then-describe-ui",
   "tap_names":["Back","Orbit 3, 10h 10m, $1,240"],
   "disabled":["Pay $1,240"],"covered":["Seat 15A"],"off_screen":["Seat 20A"]},
 "text":["SFO to HND"],"values":{"Explore":"1"}}
```

Run the `tap` command with one of the `tap_names`. baguette finds the element, waits
for it, picks where to tap, and waits for the screen to settle, so don't add a `sleep`.

- **`disabled`** can't be tapped yet. **`covered`** and **`off_screen`** need a scroll
  first, with `swipe`.
- **`text`** can be tapped by name too, when it looks tappable, like `See all`.
- **The full tree** is one `baguette describe-ui --udid <X>` away, if you need frames.

If the name is wrong or matches several, nothing is tapped, and the answer says why
and lists `visible` or `matches`.

**4. Check it worked.** Is this the screen you expected? Then go back to step 2.

**Several clicks you're already sure of** go in one call. Each waits for its element,
so you can name what the next screen will show, if the task already tells you:

```bash
baguette input --udid <X> 2>/dev/null <<'EOF' | tail -1
{"type":"tap","label":"To, Where to?","then_describe_ui":true}
{"type":"tap","label":"Tokyo Haneda","then_describe_ui":true}
{"type":"tap","label":"Search flights","then_describe_ui":true}
EOF
```

Stop wherever the next choice depends on what appears. A failed click doesn't stop
the ones after it, so put anything you can't undo, like `Pay`, in its own call.

## When a tap does nothing

`ok:true` means the touch was sent. `"changed":false` means the app's own tree
didn't change, and the answer says what's there in `hint`. If baguette would tap that
element somewhere else, `try` has the command: run it rather than repeating the point
or re-reading the screen.

1. **Look.** With no `try`, take a screenshot and read it: `baguette screenshot --udid <X> --output /tmp/s.jpg`.
2. **Tap what's drawn.** If `try` didn't help, a screenshot shows where the text
   is: tap there by coordinates, with the `screen` size from the answer.
3. **Check it's enabled**, and whether something covers it. A hit-test
   (`describe-ui --x --y`) names the element at a point, but it can't tell you
   the app will respond there.
4. **Check the input surface.** If nothing responds anywhere, run
   `baguette heal --udid <X>`. It restarts SpringBoard and running apps die.

Web content isn't in the tree `changed` watches. A link that loads a page still
shows up, but a change inside a page may not, so take a screenshot before deciding
a tap there failed.

## Finding what's there

- **Roles don't decide what's tappable.** A link may report `StaticText`, and a
  button `Image`. Read the label, and look at a screenshot if it's unclear.
- **Not everything is in the tree.** A control with no accessibility element
  needs a screenshot and a tap at its position in points:
  `points = image pixels × screen.width ÷ image width`. Use the image's own width
  (1206 on a 402-point phone), and if your viewer shrinks it, the width you see.
- **Off screen isn't on screen.** A frame beyond `screen.height` needs a scroll
  first. One wholly off the sides, like `x = -105`, may be a page that's leaving, so
  don't treat it as available.
- **Covered isn't flagged.** A floating bar can sit over an element with no sign in
  the tree: compare their frames, and scroll first if they overlap.
- **Selected isn't always shown.** Check the effect instead: a button's new label,
  or `Pay` becoming enabled.
- **If the tree and a screenshot disagree, believe the screenshot.**
- **Text.** `type` is US-ASCII only; anything else goes through `paste`.

## Reporting

Finish with what you verified against the success you wrote down, from what's on
the final screen rather than from what you meant to do:

- **Result:** pass or fail, with the final screen's values.
- **Problems:** anything wrong or odd, even if the flow got through it. Say what
  you saw and where.
- **Not tested:** what you skipped, so nobody assumes it was covered.

Never report a pass because taps returned `ok:true`.

## Practice

`examples/Skylark` in the baguette repo is a flight-booking app built for this,
with a task and a known right answer.
