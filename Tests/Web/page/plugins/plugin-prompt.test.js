import test from 'node:test';
import assert from 'node:assert/strict';
import { PluginPrompt } from '../../../../Sources/Baguette/Resources/Web/page/internal/plugins/plugin-prompt.js';

const SPEC = { arg: 'url', placeholder: 'myapp://path', submit: 'Open', filter: true };

test('should draw no field when the panel has no prompt', () => {
  assert.equal(new PluginPrompt(undefined).present, false);
  assert.equal(new PluginPrompt(null).present, false);
});

test('should not draw a prompt when it names no arg', () => {
  // The host refuses such a manifest, but the page must not depend on
  // that: a field submitting into nowhere looks like a working control.
  assert.equal(new PluginPrompt({ placeholder: 'x' }).present, false);
  assert.equal(new PluginPrompt({ arg: '' }).present, false);
});

test('should submit what was typed under the key the manifest named', () => {
  assert.deepEqual(new PluginPrompt(SPEC).args('myapp://profile/42'), { url: 'myapp://profile/42' });
});

test('should trim a pasted value before it is submitted', () => {
  // Pasting a link routinely brings a trailing newline; the host would
  // trim it anyway, and sending it untrimmed makes the echo look wrong.
  assert.deepEqual(new PluginPrompt(SPEC).args('  myapp://x\n'), { url: 'myapp://x' });
});

test('should do nothing, rather than run the command, when an empty field is submitted', () => {
  // A blank submit would spawn a subprocess to be told nothing was
  // typed. The button is inert until there is something to send.
  assert.equal(new PluginPrompt(SPEC).args(''), null);
  assert.equal(new PluginPrompt(SPEC).args('   '), null);
  assert.equal(new PluginPrompt(SPEC).args(undefined), null);
});

test('should never produce args when the panel has no prompt', () => {
  assert.equal(new PluginPrompt(undefined).args('myapp://x'), null);
});

test('should give a prompt a plain label when it named none', () => {
  assert.equal(new PluginPrompt({ arg: 'url' }).submitLabel, 'Run');
  assert.equal(new PluginPrompt(SPEC).submitLabel, 'Open');
});

test('should leave the field blank when the prompt named no placeholder', () => {
  assert.equal(new PluginPrompt({ arg: 'url' }).placeholder, '');
  assert.equal(new PluginPrompt(SPEC).placeholder, 'myapp://path');
});

test('should narrow the rows already on screen by title and subtitle when filtering', () => {
  // The rows came back from one subprocess run. Narrowing them locally
  // is what gives completion its feel without re-running the command.
  const prompt = new PluginPrompt(SPEC);
  assert.equal(prompt.matches({ title: 'myapp://', subtitle: 'My App' }, 'myap'), true);
  assert.equal(prompt.matches({ title: 'myapp://', subtitle: 'My App' }, 'my app'), true);
  assert.equal(prompt.matches({ title: 'other://', subtitle: 'Other' }, 'myap'), false);
});

test('should keep a suggestion visible once you have typed past it', () => {
  // Picking `account://` fills the box, and then you type the path. If
  // the filter only matched substrings, the row you just picked would
  // vanish the moment you added a character and the list would read
  // "Nothing matches" for the rest of the URL — the list would fight the
  // thing it exists to help with.
  const prompt = new PluginPrompt(SPEC);
  assert.equal(prompt.matches({ title: 'account://' }, 'account://'), true);
  assert.equal(prompt.matches({ title: 'account://' }, 'account://settings/1'), true);
  // An unrelated scheme still drops out.
  assert.equal(prompt.matches({ title: 'myapp://' }, 'account://settings'), false);
});

test('should match a row on the text it would fill in, not only on its label', () => {
  // `fill` is what actually goes into the field; `title` is display text
  // and may be decorated or translated. Searching only the label hides
  // the completion whenever the two differ — type `://` against a row
  // labelled "Account (SpringBoard)" and it disappears.
  const prompt = new PluginPrompt(SPEC);
  const row = { title: 'Account (SpringBoard)', fill: 'account://' };
  assert.equal(prompt.matches(row, 'account'), true);
  assert.equal(prompt.matches(row, '://'), true);
  assert.equal(prompt.matches(row, 'zzz'), false);
});

test('should match typing past a suggestion on its fill text when there is one', () => {
  const prompt = new PluginPrompt(SPEC);
  const row = { title: 'Account (SpringBoard)', fill: 'account://' };
  assert.equal(prompt.matches(row, 'account://settings'), true);
});

test('should ignore case when filtering, so typing MYAPP still finds myapp', () => {
  assert.equal(new PluginPrompt(SPEC).matches({ title: 'myapp://' }, 'MYAPP'), true);
});

test('should hide nothing when the field is empty', () => {
  assert.equal(new PluginPrompt(SPEC).matches({ title: 'myapp://' }, ''), true);
  assert.equal(new PluginPrompt(SPEC).matches({ title: 'myapp://' }, '   '), true);
});

test('should keep every row visible when the panel did not ask for filtering', () => {
  // Otherwise typing a full URL into a deep-link bar would empty the
  // list of schemes underneath it — the list is a reference, not a
  // search result, unless the manifest says so.
  const unfiltered = new PluginPrompt({ arg: 'url' });
  assert.equal(unfiltered.matches({ title: 'myapp://' }, 'zzz'), true);
  assert.equal(new PluginPrompt(undefined).matches({ title: 'myapp://' }, 'zzz'), true);
});

// --- inline completion + history -------------------------------------
//
// A suggestion list you have to point at is slower than a bar that
// finishes your sentence. These are the affordances that make the field
// feel like a URL bar rather than a text box with a list under it.

const BAR = { ...SPEC, complete: true, history: true };

const SCHEME_ROWS = [
  { title: 'account://', subtitle: 'SpringBoard', fill: 'account://' },
  { title: 'activitysharing://', subtitle: 'Fitness', fill: 'activitysharing://' },
];

test('should let a panel opt into completion and history separately', () => {
  assert.equal(new PluginPrompt(SPEC).completes, false);
  assert.equal(new PluginPrompt(SPEC).remembers, false);
  assert.equal(new PluginPrompt(BAR).completes, true);
  assert.equal(new PluginPrompt(BAR).remembers, true);
});

test('should offer what you have used before ahead of what is merely installed', () => {
  // `account://hello` is a thing you actually did; `account://` is a
  // scheme that happens to exist. The first is the better guess.
  const candidates = new PluginPrompt(BAR).candidates(SCHEME_ROWS, ['account://hello']);
  assert.deepEqual(candidates, ['account://hello', 'account://', 'activitysharing://']);
});

test('should not offer a candidate twice when history repeats a row', () => {
  const candidates = new PluginPrompt(BAR).candidates(SCHEME_ROWS, ['account://']);
  assert.deepEqual(candidates, ['account://', 'activitysharing://']);
});

test('should ghost only the part you have not typed', () => {
  const prompt = new PluginPrompt(BAR);
  assert.equal(prompt.ghost('acc', ['account://hello']), 'ount://hello');
  assert.equal(prompt.ghost('account://hello', ['account://hello']), '');
});

test('should keep the case you typed, rather than rewrite it, when completing', () => {
  // Typing ACC and having the field snap to lowercase mid-word is the
  // kind of thing that makes a bar feel like it is fighting you.
  const prompt = new PluginPrompt(BAR);
  assert.equal(prompt.ghost('ACC', ['account://hello']), 'ount://hello');
  assert.equal(prompt.accepted('ACC', ['account://hello']), 'ACCount://hello');
});

test('should ghost nothing when nothing starts with what you typed', () => {
  assert.equal(new PluginPrompt(BAR).ghost('zzz', ['account://']), '');
  assert.equal(new PluginPrompt(BAR).accepted('zzz', ['account://']), 'zzz');
});

test('should ghost nothing when the field is empty, so the bar is quiet until you type', () => {
  assert.equal(new PluginPrompt(BAR).ghost('', ['account://']), '');
});

test('should never ghost when the panel did not ask for completion', () => {
  assert.equal(new PluginPrompt(SPEC).ghost('acc', ['account://']), '');
  assert.equal(new PluginPrompt(SPEC).accepted('acc', ['account://']), 'acc');
});

test('should remember what you open, most recent first', () => {
  const prompt = new PluginPrompt(BAR);
  let history = prompt.remember([], 'account://hello');
  history = prompt.remember(history, 'myapp://x');
  assert.deepEqual(history, ['myapp://x', 'account://hello']);
});

test('should move a link to the front, rather than duplicate it, when it is re-opened', () => {
  const prompt = new PluginPrompt(BAR);
  let history = prompt.remember(['a://', 'b://'], 'b://');
  assert.deepEqual(history, ['b://', 'a://']);
});

test('should cap history, so it stays a shortlist rather than a log', () => {
  const prompt = new PluginPrompt(BAR);
  let history = [];
  for (let i = 0; i < 40; i += 1) history = prompt.remember(history, `x://${i}`);
  assert.equal(history.length, 25);
  assert.equal(history[0], 'x://39');
});

test('should keep no history when the panel does not remember', () => {
  assert.deepEqual(new PluginPrompt(SPEC).remember(['a://'], 'b://'), ['a://']);
});

test('should not remember a blank submission', () => {
  assert.deepEqual(new PluginPrompt(BAR).remember(['a://'], '   '), ['a://']);
});

test('should filter out a row, rather than crash, when it carries no text', () => {
  assert.equal(new PluginPrompt(SPEC).matches({}, 'myap'), false);
  assert.equal(new PluginPrompt(SPEC).matches(null, 'myap'), false);
});
