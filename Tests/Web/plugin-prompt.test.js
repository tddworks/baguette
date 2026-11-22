'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadBrowserModule } = require('./helpers/load-browser-module.js');

const MODULE_PATH = path.join(
  __dirname, '..', '..', 'Sources', 'Baguette', 'Resources', 'Web',
  'page/plugins/plugin-prompt.js'
);

function PluginPrompt() {
  return loadBrowserModule(MODULE_PATH).Baguette._PluginPrompt;
}

const SPEC = { arg: 'url', placeholder: 'myapp://path', submit: 'Open', filter: true };

test('a panel with no prompt draws no field', () => {
  const Prompt = PluginPrompt();
  assert.equal(new Prompt(undefined).present, false);
  assert.equal(new Prompt(null).present, false);
});

test('a prompt naming no arg is not drawn', () => {
  // The host refuses such a manifest, but the page must not depend on
  // that: a field submitting into nowhere looks like a working control.
  const Prompt = PluginPrompt();
  assert.equal(new Prompt({ placeholder: 'x' }).present, false);
  assert.equal(new Prompt({ arg: '' }).present, false);
});

test('what was typed is submitted under the key the manifest named', () => {
  const Prompt = PluginPrompt();
  assert.deepEqual(new Prompt(SPEC).args('myapp://profile/42'), { url: 'myapp://profile/42' });
});

test('a pasted value is trimmed before it is submitted', () => {
  // Pasting a link routinely brings a trailing newline; the host would
  // trim it anyway, and sending it untrimmed makes the echo look wrong.
  const Prompt = PluginPrompt();
  assert.deepEqual(new Prompt(SPEC).args('  myapp://x\n'), { url: 'myapp://x' });
});

test('submitting an empty field does nothing rather than running the command', () => {
  // A blank submit would spawn a subprocess to be told nothing was
  // typed. The button is inert until there is something to send.
  const Prompt = PluginPrompt();
  assert.equal(new Prompt(SPEC).args(''), null);
  assert.equal(new Prompt(SPEC).args('   '), null);
  assert.equal(new Prompt(SPEC).args(undefined), null);
});

test('a panel without a prompt never produces args', () => {
  const Prompt = PluginPrompt();
  assert.equal(new Prompt(undefined).args('myapp://x'), null);
});

test('a prompt that named no label gets a plain one', () => {
  const Prompt = PluginPrompt();
  assert.equal(new Prompt({ arg: 'url' }).submitLabel, 'Run');
  assert.equal(new Prompt(SPEC).submitLabel, 'Open');
});

test('a prompt that named no placeholder leaves the field blank', () => {
  const Prompt = PluginPrompt();
  assert.equal(new Prompt({ arg: 'url' }).placeholder, '');
  assert.equal(new Prompt(SPEC).placeholder, 'myapp://path');
});

test('filtering narrows the rows already on screen, over title and subtitle', () => {
  // The rows came back from one subprocess run. Narrowing them locally
  // is what gives completion its feel without re-running the command.
  const Prompt = PluginPrompt();
  const prompt = new Prompt(SPEC);
  assert.equal(prompt.matches({ title: 'myapp://', subtitle: 'My App' }, 'myap'), true);
  assert.equal(prompt.matches({ title: 'myapp://', subtitle: 'My App' }, 'my app'), true);
  assert.equal(prompt.matches({ title: 'other://', subtitle: 'Other' }, 'myap'), false);
});

test('a suggestion stays visible once you have typed past it', () => {
  // Picking `account://` fills the box, and then you type the path. If
  // the filter only matched substrings, the row you just picked would
  // vanish the moment you added a character and the list would read
  // "Nothing matches" for the rest of the URL — the list would fight the
  // thing it exists to help with.
  const Prompt = PluginPrompt();
  const prompt = new Prompt(SPEC);
  assert.equal(prompt.matches({ title: 'account://' }, 'account://'), true);
  assert.equal(prompt.matches({ title: 'account://' }, 'account://settings/1'), true);
  // An unrelated scheme still drops out.
  assert.equal(prompt.matches({ title: 'myapp://' }, 'account://settings'), false);
});

test('a row is matched on the text it would fill in, not only on its label', () => {
  // `fill` is what actually goes into the field; `title` is display text
  // and may be decorated or translated. Searching only the label hides
  // the completion whenever the two differ — type `://` against a row
  // labelled "Account (SpringBoard)" and it disappears.
  const Prompt = PluginPrompt();
  const prompt = new Prompt(SPEC);
  const row = { title: 'Account (SpringBoard)', fill: 'account://' };
  assert.equal(prompt.matches(row, 'account'), true);
  assert.equal(prompt.matches(row, '://'), true);
  assert.equal(prompt.matches(row, 'zzz'), false);
});

test('typing past a suggestion is matched on the fill text when there is one', () => {
  const Prompt = PluginPrompt();
  const prompt = new Prompt(SPEC);
  const row = { title: 'Account (SpringBoard)', fill: 'account://' };
  assert.equal(prompt.matches(row, 'account://settings'), true);
});

test('filtering ignores case, so typing MYAPP still finds myapp', () => {
  const Prompt = PluginPrompt();
  assert.equal(new Prompt(SPEC).matches({ title: 'myapp://' }, 'MYAPP'), true);
});

test('an empty field hides nothing', () => {
  const Prompt = PluginPrompt();
  assert.equal(new Prompt(SPEC).matches({ title: 'myapp://' }, ''), true);
  assert.equal(new Prompt(SPEC).matches({ title: 'myapp://' }, '   '), true);
});

test('a panel that did not ask for filtering keeps every row visible', () => {
  // Otherwise typing a full URL into a deep-link bar would empty the
  // list of schemes underneath it — the list is a reference, not a
  // search result, unless the manifest says so.
  const Prompt = PluginPrompt();
  const unfiltered = new Prompt({ arg: 'url' });
  assert.equal(unfiltered.matches({ title: 'myapp://' }, 'zzz'), true);
  assert.equal(new Prompt(undefined).matches({ title: 'myapp://' }, 'zzz'), true);
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

test('a panel opts into completion and history separately', () => {
  const Prompt = PluginPrompt();
  assert.equal(new Prompt(SPEC).completes, false);
  assert.equal(new Prompt(SPEC).remembers, false);
  assert.equal(new Prompt(BAR).completes, true);
  assert.equal(new Prompt(BAR).remembers, true);
});

test('what you have used before is offered ahead of what is merely installed', () => {
  // `account://hello` is a thing you actually did; `account://` is a
  // scheme that happens to exist. The first is the better guess.
  const Prompt = PluginPrompt();
  const candidates = new Prompt(BAR).candidates(SCHEME_ROWS, ['account://hello']);
  assert.deepEqual(candidates, ['account://hello', 'account://', 'activitysharing://']);
});

test('a candidate is not offered twice when history repeats a row', () => {
  const Prompt = PluginPrompt();
  const candidates = new Prompt(BAR).candidates(SCHEME_ROWS, ['account://']);
  assert.deepEqual(candidates, ['account://', 'activitysharing://']);
});

test('the ghost is only the part you have not typed', () => {
  const Prompt = PluginPrompt();
  const prompt = new Prompt(BAR);
  assert.equal(prompt.ghost('acc', ['account://hello']), 'ount://hello');
  assert.equal(prompt.ghost('account://hello', ['account://hello']), '');
});

test('completing keeps the case you typed rather than rewriting it', () => {
  // Typing ACC and having the field snap to lowercase mid-word is the
  // kind of thing that makes a bar feel like it is fighting you.
  const Prompt = PluginPrompt();
  const prompt = new Prompt(BAR);
  assert.equal(prompt.ghost('ACC', ['account://hello']), 'ount://hello');
  assert.equal(prompt.accepted('ACC', ['account://hello']), 'ACCount://hello');
});

test('nothing is ghosted when nothing starts with what you typed', () => {
  const Prompt = PluginPrompt();
  assert.equal(new Prompt(BAR).ghost('zzz', ['account://']), '');
  assert.equal(new Prompt(BAR).accepted('zzz', ['account://']), 'zzz');
});

test('an empty field ghosts nothing, so the bar is quiet until you type', () => {
  const Prompt = PluginPrompt();
  assert.equal(new Prompt(BAR).ghost('', ['account://']), '');
});

test('a panel that did not ask for completion never ghosts', () => {
  const Prompt = PluginPrompt();
  assert.equal(new Prompt(SPEC).ghost('acc', ['account://']), '');
  assert.equal(new Prompt(SPEC).accepted('acc', ['account://']), 'acc');
});

test('what you open is remembered, most recent first', () => {
  const Prompt = PluginPrompt();
  const prompt = new Prompt(BAR);
  let history = prompt.remember([], 'account://hello');
  history = prompt.remember(history, 'myapp://x');
  assert.deepEqual(history, ['myapp://x', 'account://hello']);
});

test('re-opening a link moves it to the front rather than duplicating it', () => {
  const Prompt = PluginPrompt();
  const prompt = new Prompt(BAR);
  let history = prompt.remember(['a://', 'b://'], 'b://');
  assert.deepEqual(history, ['b://', 'a://']);
});

test('history is capped, so it stays a shortlist rather than a log', () => {
  const Prompt = PluginPrompt();
  const prompt = new Prompt(BAR);
  let history = [];
  for (let i = 0; i < 40; i += 1) history = prompt.remember(history, `x://${i}`);
  assert.equal(history.length, 25);
  assert.equal(history[0], 'x://39');
});

test('a panel that does not remember keeps no history', () => {
  const Prompt = PluginPrompt();
  assert.deepEqual(new Prompt(SPEC).remember(['a://'], 'b://'), ['a://']);
});

test('blank submissions are not remembered', () => {
  const Prompt = PluginPrompt();
  assert.deepEqual(new Prompt(BAR).remember(['a://'], '   '), ['a://']);
});

test('a row carrying no text is filtered out rather than crashing', () => {
  const Prompt = PluginPrompt();
  assert.equal(new Prompt(SPEC).matches({}, 'myap'), false);
  assert.equal(new Prompt(SPEC).matches(null, 'myap'), false);
});
