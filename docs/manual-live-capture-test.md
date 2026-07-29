# Manual test: verifying live mic capture on a real call

Some parts of `listen` can only be checked by a human on an actual call - no
automated test can join a meeting, speak into a mic, or confirm that your
Mac's echo cancellation (AEC) hardware behaves. This is that check. It takes
about 5 minutes.

## What you're verifying

When you run `listen`, your own voice (from the microphone) should be written
to the transcript as `speaker: "me"`, and the other people on the call (their
audio coming out of your speakers/headphones) should be written as
`speaker: "other"`. This test confirms that your own speech lands as `"me"`
with roughly correct words and timing.

## Before you start (one-time permissions)

Run it from the **same terminal app** you'll always use (e.g. Terminal or
iTerm). The first run will ask macOS for two permissions - grant both:

- **Microphone** access (to capture you).
- **Screen Recording** access (this is how the tool captures the call's
  audio - macOS routes system audio capture through Screen Recording).

If you deny either, `listen` won't be able to capture that side. After
granting Screen Recording you may need to quit and reopen the terminal app.

## Steps

1. **Build (once):**
   ```
   make release
   ```

2. **Start a call you can talk on.** A real meeting is ideal, but a simple
   stand-in works too: start a call with one other person (or a second device
   of your own) so there is real "other" audio coming out of your speakers or
   headphones.

3. **Start listening.** From your terminal, in the project directory:
   ```
   make listen OUT=~/mytest.jsonl
   ```
   Wait until it prints `Listening. Press Ctrl-C to stop.` (loading the models
   takes several seconds - that's normal).

4. **Talk.** Over about 30-60 seconds, do all of these so you have clear
   things to look for afterward:
   - Say a couple of distinctive, easy-to-spot sentences yourself, e.g.
     *"This is me speaking, testing one two three."* Note roughly **when** you
     said them.
   - Let the other person (or your second device) talk for a bit too.
   - Try one stretch where you each talk right after the other.

5. **Stop.** Press **Ctrl-C** once in the terminal. It should print
   `Stopping capture...` and then `Done. Wrote N turn(s)...`. (Give it a
   second or two to flush.)

## What to check in the transcript

Open `~/mytest.jsonl`. Each line is one turn, for example:

```
{"seq":0,"start":...,"end":...,"speaker":"me","text":"this is me speaking testing one two three","final":true,"conf":1}
```

Check all of these:

1. **Your speech is labeled `"me"`.** Find the distinctive sentences you said.
   They should appear on lines where `speaker` is `"me"` - not `"other"`.
2. **The text is roughly right.** It won't be perfect (no punctuation,
   occasional wrong word), but it should clearly be what you said.
3. **The other person is labeled `"other"`.** Their speech should be on
   `"other"` lines.
4. **Timing/order makes sense.** Turns should read top-to-bottom in about the
   order the conversation actually happened, and `seq` should count up with no
   gaps.

If all four hold, live capture is working correctly for you.

## Optional: the mid-meeting device switch

Worth running once on any change to `Capture.swift`. Partway through step 4,
change your input device (System Settings -> Sound -> Input, or just put in
AirPods). Two things should happen:

1. A boxed `NOTICE: microphone input device changed mid-session` appears in the
   terminal at that moment.
2. Your speech **after** the switch still lands as `"me"` - capture doesn't go
   silent or die.

Bleed is more likely after a switch to a Bluetooth device than before it; that
is expected and not a regression. What would be a regression is no notice, or
no `"me"` turns at all after the switch.

## If you see duplicate "me"/"other" turns for the same speech

The most likely problem: **the other person's speech shows up twice** - once
correctly as `"other"`, and again (wrongly) as `"me"` - or your own words leak
onto `"other"`. This happens when you're using **speakers instead of
headphones**: your microphone physically picks up the call's audio coming out
of your speakers, and that bleed gets mislabeled.

The tool turns on echo cancellation to fight this, but it is **not guaranteed**
to fully remove speaker bleed on every Mac and audio setup.

**Fix: put on headphones and run the test again.** With headphones, the mic
physically cannot hear the call's audio, so the `"me"` / `"other"` split is
clean. If headphones make the duplicates disappear, that confirms the cause
was speaker bleed - use headphones for any meeting where correct `"me"`
labeling matters.
