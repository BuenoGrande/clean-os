# clean-os

One key puts your Mac's windows back the way you like them.

You arrange your windows once and record that arrangement. From then on, however
badly you mess things up, one command restores it. A recorded position is three
things together: which monitor a window is on, which desktop of that monitor,
and where it sits on that desktop.

Nothing is ever closed. Restore can only launch, move and resize.

## Status

Early. The engine and a command line tool exist; the menu bar app and the
browser tab work do not yet. **This code has never been compiled**, because it
was written in a Linux container with no Swift toolchain. Treat the first build
as a debugging session, not an install.

## Start here

```sh
swift build
.build/debug/cleanos probe
```

`probe` changes nothing. It reports what actually works on your Mac, which is a
real question rather than a formality: everything to do with desktops is
undocumented and Apple changes it without notice. Read its output before
trusting anything else here.

Add `--try-move` to include the one test that moves a real window to another
desktop and back.

## What you need to turn on

Three macOS settings, none of them the default. `probe` checks all three and
tells you which is wrong.

**Keyboard shortcuts for Desktop 1 to 9**, in System Settings, Keyboard,
Keyboard Shortcuts, Mission Control. These keystrokes are how windows get moved
between desktops. Without them, desktops do not work at all.

**Automatically rearrange Spaces based on most recent use, turned off**, in
System Settings, Desktop and Dock. Left on, macOS renumbers your desktops as you
use them and a recorded desktop number stops meaning anything.

**Displays have separate Spaces, turned on**, in the same pane. This makes each
monitor own its own desktops, which is the model a recording assumes.

You also need to grant Accessibility permission, in System Settings, Privacy and
Security, Accessibility. That permission is tied to the app's code signature, so
an unsigned rebuild will be asked for it again. Set up a stable signing identity
early or you will approve a dialog every time you build.

## Using it

```sh
cleanos record            # record how things are now
cleanos restore           # put them back
cleanos restore --dry-run # say what would happen, change nothing
cleanos undo              # take back the last restore
cleanos list              # show recordings
cleanos path              # where recordings are kept
```

Recording walks each desktop in turn, because macOS will not list the windows on
a desktop you are not looking at. That takes a couple of seconds and some
animation. Use `record --no-sweep` to record only the visible desktop.

## What it will not do, on purpose

**It refuses to move browsers and terminals between desktops.** Moving a window
to another desktop works by simulating a drag of its title bar. In an app whose
title bar is a row of tabs, that drag tears out a tab instead of moving the
window, which loses whatever was in it. Since not losing anything is the point,
those apps are refused and reported rather than risked. Move them by hand, or
right-click the app's Dock icon and assign it to a desktop.

**It leaves windows it does not know about exactly where they are.** The button
tidies what you recorded and ignores everything else.

**Desktop moves are slow and visible.** Roughly half a second per window, and
the cursor is borrowed while it happens. That is the cost of the only mechanism
that works without weakening macOS security settings.

## Not losing anything

Three mechanisms, because it is a guarantee rather than a feature.

Restore never closes a window and never quits an app.

Every restore writes the previous state to an undo slot before touching
anything, so `cleanos undo` puts it back.

Every run appends what it saw to `log.jsonl`, flushed to disk immediately. It is
one JSON object per line and you can grep it.

## The recording

One JSON file per monitor arrangement, in
`~/Library/Application Support/clean-os/snapshots/`. Readable, hand-editable and
worth keeping in version control. Four decisions in the format, each fixing a
known failure in an existing tool:

Monitors are identified by hardware UUID, never by index or resolution, with a
vendor, model and serial fallback for when a UUID changes across a reboot.

Frames are stored as fractions of the monitor's usable area, so a recording
survives a resolution or scaling change.

Desktop numbers are counted per monitor, because global numbering shifts when a
desktop is added or removed.

Windows are matched by bundle identifier, an optional title pattern and an
ordinal, because window identifiers do not survive an app relaunch. Titles are
recorded as a note rather than a matching rule, since they change constantly.
Add a `titleRegex` by hand when you need to tell two windows of one app apart.

## Layout

```
Sources/CleanOSKit/
  Model/      the recording format
  Logic/      pure decisions: which recording applies, which window, what order
  Platform/   accessibility, monitors, the private desktop calls, the drag
  Capture/    reading the screen, writing a recording
  Restore/    executing a plan
  Store/      files, undo, log
Sources/cleanos/   command line tool
Tests/             the pure logic, which is where real bugs live
```

`swift test` covers the parts with no Mac API in them: matching a recording to
your monitors, folding a layout when a monitor is unplugged, ordinal assignment,
fraction and pixel conversion, and plan ordering.

## Why this exists rather than buying something

Rectangle Pro saves and restores window layouts for about ten dollars and does
it well. Its documentation says plainly that it cannot handle desktops, because
Apple never shipped the interface for it. That gap, plus organising browser tabs
by whether you were browsing or keeping something, is the whole reason to build
rather than buy. If `probe` says desktops do not work on your Mac, buying is the
better answer.
