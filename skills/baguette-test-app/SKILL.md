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

**3. Run an offered command.** Every result starts with `affordances`: what you can
do right now, each one finished and ready to run. Pick one and run it as written.
Don't work out a tap from a frame: the offered point allows for things a frame can't
show, like a row whose centre is blank.

```json
{"affordances":{
  "home":"baguette press --udid X --button home",
  "screenshot":"baguette screenshot --udid X --output /tmp/baguette-screen.jpg",
  "tap Orbit 3, 10h 10m, $1,240":"baguette tap --udid X --x 56 --y 550 --width 402 --height 874 --then-describe-ui"
},"children":[…]}
```

A tap waits for the screen to settle, so don't add a `sleep`, and answers with
`changed`, the next `affordances`, and the new screen under `tree`.

A control with no offer won't work now: it's disabled, or off screen and needs a
scroll. Plain text and images offer nothing because their role doesn't say they
respond, though some do, like a `See all` link: tap those at their frame's centre.
A focused text field also offers `type`.

**4. Check it worked.** Is this the screen you expected? Then go back to step 2.

**Several clicks you're already sure of** can go in one call. Each waits for the
screen before the next, so this saves a turn, and `tail -1` keeps only the last screen:

```bash
baguette input --udid <X> 2>/dev/null <<'EOF' | tail -1
{"type":"tap","x":201,"y":314,"width":402,"height":874,"then_describe_ui":true}
{"type":"tap","x":201,"y":351,"width":402,"height":874,"then_describe_ui":true}
EOF
```

Only batch what the screen you've read already shows, or what can't depend on
anything new. When the next choice depends on what appears, read first.

**To read a result without the long tree,** keep the offers and the text. Add this to
any `tap` or `launch`:

```bash
| jq '{changed, hint, try, offers: (.affordances | keys), text: [.tree | .. | objects | select(.label? and .frame.y >= 50 and .role == "AXStaticText") | .label]}'
```

Then read the command for the one you want with
`jq -r '.affordances["tap Search flights"]'` on the same output, or print the whole
map with `jq .affordances`. After a plain `describe-ui`, the labels are at the top
instead of under `.tree`, and there's no `changed`. Don't write `.changed // "n/a"`: `//` treats `false` as missing.

## When a tap does nothing

`ok:true` means the touch was sent. `"changed":false` means the app's own tree
didn't change, and the answer says what's there in `hint`. If baguette would tap that
element somewhere else, `try` has the command: run it rather than repeating the point
or re-reading the screen.

1. **Look.** With no `try`, take a screenshot and read it: `baguette screenshot --udid <X> --output /tmp/s.jpg`.
2. **Tap what's drawn.** A frame can be wider than what responds, so an offered point
   can land on blank space. Tap the drawn text by coordinates instead.
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
