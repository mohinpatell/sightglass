# Sightglass

A sight glass is the small window on a boiler or an engine that lets you watch what
is happening inside while it runs. This is one for your Mac.

Sightglass lives in the menu bar and shows, all the time, what is using your CPU,
your battery and your memory, and which apps are responsible.

- **CPU:** the busiest apps right now, a stacked chart of the last 10 minutes, and a
  log of spikes that names what caused each one, even after it is over.
- **Energy:** watts drawn right now and where they go. Power coming in from the
  charger, power going out, and what the battery gains or loses as a result. Real
  watts per app, and a running total per app since you plugged in or unplugged.
- **Memory:** how much is in use, whether the Mac is under memory pressure or
  swapping, the apps holding the most, and the apps that grew the most.

Point at any app in a list to quit it. Switch on alerts for the things you care
about, such as an app hogging the CPU or the battery draining while plugged in.

## Install

Sightglass needs macOS 14 (Sonoma) or later. The Energy view needs an Apple Silicon
Mac. On an Intel Mac the CPU and Memory views should work, but that is untested.

With [Homebrew](https://brew.sh):

```bash
brew install mohinpatell/tap/sightglass
```

Homebrew builds it on your Mac, which takes about a minute. It needs Apple's Command
Line Tools, which Homebrew installs with itself. Then start it:

```bash
sightglass
```

A reading appears in the menu bar. Click it to open the panel.

### First run

- **Start at login.** Tick "Open at login" at the bottom of the panel.
- **Menu bar readings.** By default the menu bar shows CPU use. Under "Menu bar
  shows" you can add the watts the Mac is using and what the battery is gaining or
  losing, and choose icons or thin dividers between them. Dividers take less room.
- **Alerts.** They are all off at first. Open "Alerts" in the panel and switch on
  the ones you want. macOS asks once whether Sightglass may send notifications.
- **Update speed.** Sightglass reads once a second while plugged in and every 5
  seconds on battery. Both are settings in the panel.

If the reading does not appear, the menu bar may be full. macOS hides items that do
not fit, most often on a MacBook with a notch. Quit a menu bar app you do not need
or switch to dividers.

### Update

```bash
brew upgrade sightglass
```

After an update, quit Sightglass from its panel and run `sightglass` again.

### Uninstall

Quit Sightglass from its panel, then:

```bash
brew uninstall sightglass
```

To also remove its settings and saved spikes:

```bash
defaults delete io.github.mohinpatell.sightglass
```

```bash
rm -rf ~/Library/Application\ Support/Sightglass
```

## Reading the numbers

- **Percentages are out of 100.** Every CPU figure is a share of the whole machine,
  so 100% means every core is busy. The panel header also shows the per core figure
  it comes from, such as "475% of 1200%" on a 12 core Mac.
- **Watts per app are CPU energy only.** Graphics, memory and the screen are shown
  as totals, because nothing reports them per app. "Screen and rest" is hardware no
  app can be blamed for: the screen, anything plugged into the ports, Wi-Fi, storage
  and power lost in conversion.
- **Plugged in does not always mean charging.** If the Mac uses more than the
  charger supplies, the battery makes up the difference and the panel says so.
- **Short lived commands are charged to whatever ran them.** A shell, a build tool
  or a coding agent that launches thousands of quick commands shows up under its
  own name with their CPU included.

## Alerts

All are off until you switch them on, and each has its own limits.

| Alert | What you can set |
|---|---|
| An app hogs the CPU | more than half a core, 1, 2 or 4 cores, for 1, 5 or 15 minutes |
| The whole Mac is busy | CPU above 50%, 75% or 90%, for 1, 5 or 15 minutes |
| Losing charge while plugged in | for at least 2, 5 or 15 minutes |
| Battery is running low | less than 30 minutes, 1 hour or 2 hours left |
| Memory is under pressure | high or critical, or critical only |
| An app uses a lot of memory | more than 2, 4, 8 or 16 GB |

You also choose how often the same alert may repeat and whether it plays a sound.
An alert about an app has a button to stop alerts about that app, which is meant for
long jobs you started on purpose.

## Build from source

You need macOS 14 or later and the Swift toolchain. Command Line Tools are enough;
Xcode is not required.

```bash
git clone https://github.com/mohinpatell/sightglass.git
```

```bash
cd sightglass
```

```bash
scripts/bundle.sh
```

```bash
open Sightglass.app
```

If the repo sits in an iCloud synced folder such as Desktop, point `.build`
somewhere else with a symlink before building. Thousands of build files in a synced
folder keep iCloud busy.

### Tests

```bash
scripts/test.sh
```

Use the script instead of plain `swift test`. Command Line Tools keep Swift Testing
outside the default search path, and the script adds it.

### Developer aids

```bash
.build/release/sightglass-probe 10
```

This prints the busiest apps once a second. Add `--energy` before the number for
power readings.

The app itself takes a few flags so the panel can be checked without clicking:

| Flag | Effect |
|---|---|
| `--show-panel` | opens the panel 3 seconds after launch |
| `--snapshot out.png` | draws the panel to a PNG after 8 seconds and quits |
| `--test-alert` | posts one notification |

Any setting can be overridden for one launch, for example `-panelMode energy`,
`-showAllApps YES`, `-intervalOnPower 5`, `-menuBarDividers YES`,
`-showAlertsPage YES`, `-showQuitButtons YES`, `-testQuitDialog YES` (opens the quit
confirmation without quitting anything) and `-panelMaxHeight 600`.

## How it works

- **Sampling.** At each interval Sightglass reads the cumulative CPU time of every
  process and subtracts the previous reading. This catches short spikes that the
  decaying average from `ps -o pcpu` smooths over.
- **Your processes** are read with `proc_pid_rusage`, which takes under a
  millisecond for all of them.
- **Other users' processes** (WindowServer, mds) refuse that call, so they come from
  `/bin/ps`, which is setuid root. A `ps` run costs 15 to 35 ms, so it only runs
  while the kernel reports at least a quarter core that the direct readings do not
  explain, and then at most every 3 seconds. In between, the last result is reused.
- **Short lived commands.** A command that starts and finishes between two samples
  is never seen as a process. When its parent collects it, the kernel adds its CPU
  time to the parent's child time, which the same call returns. Sightglass charges
  that to the parent, after subtracting what a longer lived child was already
  charged while it was running. It is never allowed to exceed the CPU the kernel
  counted that nothing else explains.
- **Grouping.** Helpers roll up into the outermost `.app` in their path. XPC services
  go to the app they work for. Interpreters are named with their script.
- **Spikes.** One opens when the machine stays over 40% for 3 seconds or one app
  stays over a full core for 5 seconds, and closes after 3 calm seconds. Finished
  spikes are kept for 7 days in
  `~/Library/Application Support/Sightglass/spikes.json`.
- **Energy per app.** The kernel keeps a CPU energy counter per process
  (`ri_energy_nj`). It is real joules and reflects which cores ran the work: on the
  Mac this was developed on, a process on a performance core cost about ten times
  one on an efficiency core for the same CPU time.
- **Power per component.** CPU, graphics and memory watts come from IOReport, a
  private Apple library that reads the chip's energy counters without root.
- **Power in and out.** The System Management Controller reports charger input
  (`PDTR`) and whole machine draw (`PSTR`) about once a second. The battery
  controller reports the same two figures but only refreshes them every half
  minute, so it is the fallback.
- **Memory.** Per app it is the footprint Activity Monitor shows. The total is app
  memory plus wired plus compressed, which is how Activity Monitor defines Memory
  Used.
- **Alerts.** Each rule needs its condition to hold for a while and then stays
  quiet for a while, so a blip never notifies and a lasting problem does not nag.

## Known limits

- System processes using less than a quarter core in total are not listed, because
  `ps` does not run then.
- The first sample of a system process burst shows as "Not yet identified".
- kernel_task cannot be read without root. Its CPU shows as "Kernel and system
  tasks", together with short lived commands whose parent belongs to another user.
- CPU energy and memory of processes owned by other users cannot be read per app.
  Their energy shows as one measured total, "System and short lived".
- A spike is saved when it ends. If the app quits during a spike, that spike is lost.
- Time asleep is not counted in the totals since plugged in or unplugged, and those
  totals start over when the app restarts.
- Reading the chip's energy counters costs about 2 ms per sample. Showing three
  menu bar readings costs roughly half as much again as showing one, because the
  item is redrawn on every display.
- The app is not signed with an Apple Developer ID. Building it on your own Mac,
  which is what Homebrew does, avoids the warning macOS shows for downloaded apps.
- IOReport, the SMC key names, the battery registry keys and
  `responsibility_get_pid_responsible_for_pid` are undocumented and could change.

## Feedback

Found a problem, or want something changed or added? Open an issue at
[github.com/mohinpatell/sightglass/issues](https://github.com/mohinpatell/sightglass/issues).
The "Send feedback" link at the bottom of the panel goes to the same place. It helps
to say what you expected, what happened, and your Mac model and macOS version.

## License

MIT. See [LICENSE](LICENSE).
