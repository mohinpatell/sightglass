# CPU Culprit

A macOS menu bar app that names what is using your CPU and your battery. The menu
bar shows total CPU use right now ("40.3%"). Click it for two views:

- **CPU:** the top apps, a stacked chart of the last 10 minutes, and a log of spikes
  with who caused each one. Every number is a share of the whole machine, so 100%
  means all cores are busy. The header also shows the per core figure it comes from
  ("475% of 1200%").
- **Energy:** watts being drawn now, split into CPU, graphics, memory and everything
  else. Power coming in from the charger, power going out, and what the battery gains
  or loses as a result. The apps using the most CPU energy in real watts. A running
  total per app since you last plugged in or unplugged.

## Build and run

Needs macOS 14 or later and the Swift toolchain. Command Line Tools are enough, Xcode is not required.

```bash
scripts/bundle.sh
open "CPU Culprit.app"
```

`.build` should not live in an iCloud synced folder. If the repo is on a synced
Desktop, point `.build` somewhere else with a symlink before building.

## Test

```bash
scripts/test.sh
```

Use the script instead of plain `swift test`. Command Line Tools keep Swift Testing
outside the default search path, and the script adds it.

Two developer aids:

```bash
.build/release/culprit 10
"CPU Culprit.app/Contents/MacOS/CPUCulprit" --snapshot panel.png
```

The first prints the top five apps once a second (`--energy` prints power readings
instead). The second draws the panel to a PNG after 8 seconds and quits.
`--show-panel` opens the real panel 3 seconds after launch.

Settings can be overridden for one launch on the command line, which is how the panel
is tested without clicking: `-panelMode energy`, `-showAllApps YES`,
`-showAllEnergy YES`, `-intervalOnPower 5`, `-intervalOnBattery 10`, `-panelMaxHeight 600`.

## How it works

- **Sampling.** Every 1, 2, 5 or 10 seconds the app reads. There is one setting for
  when the Mac is plugged in (default 1) and one for battery (default 5), because the
  app's own energy use only matters on battery. Each time it reads cumulative CPU time for every process
  and subtracts the previous reading. This catches short spikes that the decaying
  average from `ps -o pcpu` smooths over.
- **Your processes** are read with `proc_pid_rusage`, under a millisecond for all of them.
- **Other users' processes** (WindowServer, mds, fileproviderd) refuse that call, so
  they come from `/bin/ps`, which is setuid root. A `ps` run costs 15 to 35 ms, so it
  only runs while the kernel reports at least a quarter core that the direct readings
  do not explain.
- **Grouping.** Helpers roll up into the outermost `.app` in their path. XPC services
  go to the app they work for. Interpreters are named with their script.
- **Spikes.** One opens when the machine stays over 40% for 3 seconds or one app stays
  over a full core for 5 seconds (rounded up to whole samples at longer intervals), and closes after 3 calm seconds. Finished spikes are
  kept for 7 days in `~/Library/Application Support/CPU Culprit/spikes.json`.

- **Energy per app.** The kernel keeps a CPU energy counter per process
  (`ri_energy_nj` from `proc_pid_rusage`). It is real joules and reflects which cores
  ran the work: here a process on a performance core cost about ten times one on an
  efficiency core for the same CPU time.
- **Power per component.** CPU, graphics and memory watts come from IOReport, a
  private Apple library that reads the chip's energy counters without root.
- **Power in and out.** The battery controller reports charger input and whole machine
  draw. The difference is what the battery gains or loses. It can be negative while
  plugged in, when the Mac draws more than the charger supplies.

## Known limits

- System processes using less than a quarter core in total are not listed, because
  `ps` does not run then.
- The first second of a system process burst shows as "Not yet identified".
- kernel_task cannot be read without root. Its CPU lands in "Short lived or kernel"
  together with processes that started and exited between two samples.
- A spike is saved when it ends. If the app quits during a spike, that spike is lost.
- XPC grouping uses `responsibility_get_pid_responsible_for_pid`, a private call.
- Energy per app is CPU energy only. Graphics, memory, the screen, storage and radios
  are shown as totals because nothing reports them per app.
- CPU energy of processes owned by other users cannot be read. It shows as one
  measured total, "System and short lived", together with kernel and idle overhead.
- The battery controller refreshes its power figures about every half minute, so
  power in, power out and the screen figure move in steps.
- Time asleep is not counted in the totals since plugged in or unplugged, and those
  totals start over when the app restarts.
- IOReport and the battery registry keys are undocumented and could change.
