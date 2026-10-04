# Per-open gate spike

A feasibility test, not a feature. It has not been run on a device yet.

The question: with a free developer account (no Family Controls, no paid entitlement), can a Shortcuts personal automation "When [app] is opened" hand control to PushupTime, and can PushupTime then let the person back into the app for a limited time without intercepting it again?

The spike is DEBUG only. It lives in `App/GateSpike/` and compiles out of Release builds. It is reached from Workout, then "Gate spike", at the bottom of the idle Workout screen next to "Data collection mode".

## How it works

- Two App Intents are exposed to Shortcuts: **PressPass Gate** (for "is opened") and **PressPass Session End** (for "is closed"). Each takes an optional text parameter `app`, the name of the guarded app, which is stored in the log.
- PressPass Gate checks for a valid pass. With one, it logs `opened_with_pass` and returns without bringing PushupTime forward. Without one, it logs `opened_intercepted`, asks for the gate screen and tries to bring PushupTime to the foreground. PushupTime then shows the Gate spike screen as a sheet.
- PressPass Gate always returns a yes/no result, `needsGate`: yes when the gate was requested, no when a pass was valid. This lets a shortcut branch on it on any iOS version (see "Fallback variant").
- On the gate screen, "Grant pass and return" starts a pass of the chosen length, logs `pass_granted` and opens the URL scheme of the guarded app (default `instagram://`).
- Everything is logged in the app's own storage, newest first on the screen, with times to the second.

How the app is brought forward depends on the iOS version:

| iOS | Mechanism |
|---|---|
| 26 and later | `supportedModes` includes `.foreground(.dynamic)` and the intent calls `continueInForeground`, only when there is no pass |
| 16.4 to 25 | `ForegroundContinuableIntent` and `requestToContinueInForeground`, only when there is no pass |
| 16.0 to 16.3 | None available. The intent only returns `needsGate`, and the shortcut must open the app (fallback variant) |

## Before you start

1. Build and run the **PushupTimeDev** scheme on the phone from Xcode (DEBUG configuration, your personal team). Open the app once so the system learns its actions.
2. Pick a target app to guard. The steps below use Instagram and `instagram://`. For another app, use its name and its URL scheme.
3. Note the iOS version of the phone. The result depends on it.

## Create the automations

You need two personal automations in the Shortcuts app.

### Automation 1: app is opened

1. Open Shortcuts, go to the **Automation** tab and tap **+** (New Automation).
2. Choose **App**.
3. Tap **Choose** and select the target app (Instagram).
4. Tick **Is Opened** and untick **Is Closed**. Tap **Next**.
5. Tap **Add Action**, search for **PressPass Gate** (it is listed under PushupTime) and add it.
6. Tap the `App` parameter on the action and type the target app's name, for example `Instagram`.
7. Tap **Next**, choose **Run Immediately** (not Ask Before Running), and turn off **Notify When Run** if you want a quieter test. Tap **Done**.

### Automation 2: app is closed

1. New Automation, **App**, choose the same target app.
2. Tick **Is Closed** and untick **Is Opened**. Tap **Next**.
3. Add the action **PressPass Session End** and set its `App` parameter to `Instagram`.
4. **Next**, **Run Immediately**, **Done**.

### Fallback variant: If needsGate then Open App

Use this if, in Automation 1, opening the target app does not bring PushupTime forward by itself (always the case on iOS 16.0 to 16.3, and possible on others). Build Automation 1 as three actions:

1. **PressPass Gate** with the `App` parameter set to `Instagram`.
2. **If**, with the input set to the result of PressPass Gate (the variable named after the action), condition **is**, value **Yes** (if the picker offers it, "is true" is the same thing).
3. Inside the If: **Open App**, choosing PushupTime. Leave the Otherwise branch empty. Finish with **End If**.

Then run the test script below. Record whether the Open App step brings PushupTime forward directly or only shows a notification to tap.

## Test script

Do these in order, and write down what you see at each step. Use the Gate spike screen to read the log. Run the whole script once with the main variant and, if it failed at step 1, once with the fallback variant.

1. **No pass.** In PushupTime, open Gate spike and tap **Clear pass**. Go to the home screen and open the target app.
   - Expect: PushupTime comes forward showing the Gate spike screen. The log has `opened_intercepted` with detail `Instagram`.
   - Note: whether a prompt asked you to confirm before PushupTime opened, whether the target app showed for a moment first, and how long it took.
2. **Grant a pass.** On the Gate spike screen set the pass length to 2 minutes, make sure the URL is `instagram://`, and tap **Grant pass and return**.
   - Expect: the target app opens and is not intercepted. The log has `pass_granted` and then `opened_with_pass`. PushupTime does not come forward again.
   - Note: whether iOS asked permission to open the other app, and whether `opened_with_pass` appeared.
3. **Reopen within the pass.** Close the target app to the home screen (a `closed` entry should appear), then open it again within the 2 minutes.
   - Expect: no interception. Another `opened_with_pass` entry.
4. **Wait for expiry.** Wait until the 2 minutes are over (the screen shows the pass status once PushupTime is open, or just wait 2 minutes from step 2), then open the target app again.
   - Expect: intercepted again, `opened_intercepted`, and the gate screen.
5. **Closes.** Close the target app a few times and check the log.
   - Expect: a `closed` entry each time. Note any closes that were missed, and any delay.

## What each outcome means

| Outcome | Meaning |
|---|---|
| Step 1 works with no prompt | The gate can intercept an open with a free account. This is the best case |
| Step 1 works but needs a tap on a prompt or notification | Interception works but with friction. Judge whether that is acceptable for the product |
| Step 1 works only with the fallback variant | The intent cannot bring the app forward by itself on this iOS version. The user's shortcut has to do it, so setup is more involved |
| Step 1 never brings PushupTime forward, even with the fallback | A Shortcuts automation cannot hand control to the app this way. The per-open gate is not feasible on this route |
| Step 1 works but the target app is visible first | The gate arrives after the app opens. It can be bypassed in that moment, so judge how much that matters |
| Step 2 returns to the target app with `opened_with_pass` | A time-limited pass works without a loop |
| Step 2 gets intercepted again (`opened_intercepted` right after `pass_granted`) | The automation fires on the return open before the pass is seen. Check the order of the log entries, and whether the pass was stored (the screen should say pass valid) |
| Step 2 shows "Could not open" | The URL scheme is wrong or the app is not installed. Try another scheme |
| Step 3 shows no `opened_with_pass` | The automation did not run for that open. Check that it is set to Run Immediately |
| Step 4 is not intercepted after expiry | The pass check is wrong, or the automation did not fire. Check the pass status and the log times |
| No `closed` entries | "Is Closed" automations are not reliable here, so a session end cannot be detected this way |

Also note whether the automation runs when the phone is locked and unlocked into the target app, and whether Shortcuts shows any banner on each run.
