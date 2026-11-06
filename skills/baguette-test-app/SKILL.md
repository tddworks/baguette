---
name: baguette-test-app
description: |
  Test an iOS app the way a person uses it: read the simulator's screen, decide
  what's next, click, and check what happened, with the `baguette` CLI. Use when
  asked to test, QA, verify or walk through an app or a user flow on a simulator,
  check that a change works on screen, or complete a task inside an app ("sign up
  and check the receipt"). For the commands themselves, or for
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
"Signed up" isn't enough: "a new account, on the free plan, with the receipt
emailed".

## The loop

**1. Open the app and read the screen, in one call.**

```bash
baguette launch --udid <X> --bundle-id <id> --relaunch --then-describe-ui
```

It waits for the first real screen, usually 4 to 5 seconds. Baguette logs to stderr,
so add `2>/dev/null` if you only want the answer.

**2. Read the answer and think.** It says what you can do next, each with the command
to run:

```json
{"ok":true,"changed":true,
 "affordances":{"fill Name":"baguette fill --udid X --label Name --text <text>",
                "tap Back":"baguette tap --udid X --label Back --then-describe-ui",
                "tap New List":"baguette tap --udid X --label 'New List' --then-describe-ui"},
 "disabled":["Share List"],
 "text":["My Lists"],
 "values":{"Home":"1"}}
```

- **`affordances`:** what you can do next. Run the command as it's written, filling in
  anything like `<text>`. `fill` is for a text field, `type` for one that has focus, and
  `swipe` for a slider, because a press can't set its value.
- **`disabled`:** controls that can't be used yet. Do what they're waiting for first.
- **`text`:** what the screen says. Some of it can be tapped too, like a `Show more` link.
- **`values`:** a control's value, like a switch's `1` or the selected tab's.

Read what's there before choosing: the first row is rarely the one the task means.

**A long answer** can offer over a hundred actions, so filter it by what you're after
instead of cutting it off, because what you need next may be anywhere in it:

```bash
... 2>/dev/null | jq -r '.affordances | to_entries[] | select(.key | test("New List|Continue")) | .value'
```

**3. Tap by name, and read, in one call.**

```bash
baguette tap --udid <X> --label 'Groceries' --then-describe-ui
```

Use single quotes, so a `$` in a name like `Total $20` stays as it is. A name can be part of a label,
as long as it matches only one element. baguette waits for the element and for the
screen to settle, so don't add a `sleep`. The answer is the next screen, so go back
to step 2.

If the name is wrong or matches several, nothing is tapped, and the answer says why
and lists `visible` or `matches`. `"used":"touch"` means baguette couldn't find the
element to press, so it touched it instead.

**4. Check it worked.** Is this the screen you expected? Selections don't always show
in the answer, so look for their effect: a button that now says `Continue with Groceries`,
or `Share List` leaving `disabled`.

**Scrolling isn't needed to tap.** A press reaches a control wherever it is. To read
more of a list, use `baguette swipe` with `--then-describe-ui`. `changed:false` means
nothing moved: usually the end of the list, but possibly a spot that doesn't scroll, so
take a screenshot if it matters. Long lists load rows as they scroll, so the answer only
lists what's loaded.

**Several clicks you're already sure of** go in one call. Each waits for its element,
so you can name what the next screen will show, if the task already tells you:

```bash
baguette input --udid <X> 2>/dev/null <<'EOF' | tail -1
{"type":"tap","label":"New List","then_describe_ui":true}
{"type":"tap","label":"Choose a Template","then_describe_ui":true}
{"type":"tap","label":"Blank","then_describe_ui":true}
EOF
```

Stop wherever the next choice depends on what appears. A failed click doesn't stop
the ones after it, so put anything you can't undo, like `Delete Account`, in its own call.

## A press isn't a finger

`--label` presses through accessibility, as VoiceOver does. So it can reach what a
finger can't, like a row under a tab bar or off screen. That's right for
getting through a task, but it can hide a bug where users can't reach something.

**Use `--touch` for a real finger** when you're testing that a user can tap something,
or when a press had no effect but the control looks live:

```bash
baguette tap --udid <X> --label 'New List' --touch --then-describe-ui
```

It refuses an element off screen. A `changed:false` here can be a real finding, or
just a blank spot in a wide row: check with a screenshot.

## When a tap does nothing

`"changed":false` means the app's own tree didn't change, and the answer says what it
knows in `hint`, plus a `try` with a better way if it has one. baguette never retries for
you, because the app may have acted anyway: check before tapping `Delete Account` a
second time.

`"changed":true` doesn't prove the tap did what you wanted either. It only means the
screen is different, so check the result. For what matters, take a screenshot.

1. **Look.** `baguette screenshot --udid <X> --output /tmp/s.jpg`, then read it.
2. **Check it's the right element**, and that it isn't waiting on something else.
3. **Check the input surface.** If real touches do nothing anywhere, run
   `baguette heal --udid <X>`. It restarts SpringBoard and running apps die.

Web content isn't in the tree `changed` watches. A link that loads a page still shows
up, but a change inside a page may not.

## What the answer can't tell you

- **Not everything is a named control.** Text and images aren't listed under `tap`,
  because their role doesn't say they respond. Try them by name if they look tappable.
  Some controls have no useful name, like `RadioButton #3`: a screenshot shows which is which.
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

`examples/Skylark` in the baguette repo is an app built for this, with a task and a
known right answer in its README. To test yourself fairly, get the task from someone
else rather than reading the README first.
