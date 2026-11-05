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
baguette list --json                         # a booted UDID
baguette boot --udid <X>                     # if none is running
xcrun simctl install <X> path/to/App.app     # if it isn't installed
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

It waits for the first real screen, usually 4 to 5 seconds.

**2. Read the answer and think.** It's short, and says what you can do:

```json
{"ok":true,"changed":true,
 "affordances":{"tap":["Back","Orbit 3, 10h 10m, $1,240","Lantern 9, 11h 15m, $820"]},
 "disabled":["Pay $1,240"],
 "text":["SFO to HND"],
 "values":{"Explore":"1"}}
```

- **`affordances.tap`:** the controls you can tap, by name.
- **`affordances.type`:** a focused text field you can type into.
- **`disabled`:** controls that can't be used yet. Do what they're waiting for first.
- **`text`:** what the screen says. Some of it can be tapped too, like a `See all` link.
- **`values`:** a control's value, like a switch's `1` or the selected tab's.

Read the values: the first row is rarely the fastest.

**3. Tap by name, and read, in one call.**

```bash
baguette tap --udid <X> --label 'Orbit 3' --then-describe-ui
```

Use single quotes, so a `$` in a name stays as it is. A name can be part of a label,
as long as it matches only one element. baguette waits for the element and for the
screen to settle, so don't add a `sleep`. The answer is the next screen, so go back
to step 2.

If the name is wrong or matches several, nothing is tapped, and the answer says why
and lists `visible` or `matches`.

**4. Check it worked.** Is this the screen you expected? Selections don't always show
in the answer, so look for their effect: a button that now says `Continue with 3F`,
or `Pay` leaving `disabled`.

**Scrolling isn't needed to tap.** A press reaches a control wherever it is. To read
more of a list, use `baguette swipe` with `--then-describe-ui`. `changed:false` means
nothing moved, which usually means you've reached the end. Long lists load rows as
they scroll, so the answer only lists what's loaded.

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

## A press isn't a finger

`--label` presses through accessibility, as VoiceOver does. So it can reach what a
finger can't, like a seat under the tab bar or a row off screen. That's right for
getting through a task, but it can hide a bug where users can't reach something.

**To test that a user can really tap something,** add `--touch`, which uses a real
touch at the element:

```bash
baguette tap --udid <X> --label 'Pay' --touch --then-describe-ui
```

It refuses an element off screen. A `changed:false` here can be a real finding, or
just a blank spot in a wide row: check with a screenshot.

## When a tap does nothing

`"changed":false` means the app's own tree didn't change, and the answer says what it
knows in `hint`. baguette never retries for you, because the app may have acted
anyway: check before tapping `Pay` a second time.

1. **Look.** `baguette screenshot --udid <X> --output /tmp/s.jpg`, then read it.
2. **Check it's the right element**, and that it isn't waiting on something else.
3. **Check the input surface.** If real touches do nothing anywhere, run
   `baguette heal --udid <X>`. It restarts SpringBoard and running apps die.

Web content isn't in the tree `changed` watches. A link that loads a page still shows
up, but a change inside a page may not.

## What the answer can't tell you

- **Not everything is a named control.** Text and images aren't listed under `tap`,
  because their role doesn't say they respond. Try them by name if they look tappable.
- **Not everything is in the tree.** For a control with no accessibility element, take
  a screenshot and tap by coordinates: `points = image pixels × screen.width ÷ image
  width`. `baguette describe-ui --udid <X>` has `screen`, every frame and the full tree.
- **If the answer and a screenshot disagree, believe the screenshot.**
- **Text input:** `type` is US-ASCII only; anything else goes through `paste`.

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
