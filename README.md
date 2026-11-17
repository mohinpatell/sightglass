# CPU Culprit

A macOS menu bar app that names what is using your CPU. The menu bar shows the
busiest app right now ("Python train.py 380%"). The panel shows the top five apps,
a stacked chart of the last 10 minutes, and a log of spikes with who caused each one.

100% means one full core, the same scale Activity Monitor uses.

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

The first prints the top five apps once a second. The second draws the panel to a
PNG after 8 seconds and quits. `--show-panel` opens the real panel 3 seconds after launch.

## How it works

- **Sampling.** Once a second the app reads cumulative CPU time for every process
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
  over a full core for 5 seconds, and closes after 3 calm seconds. Finished spikes are
  kept for 7 days in `~/Library/Application Support/CPU Culprit/spikes.json`.

## Known limits

- System processes using less than a quarter core in total are not listed, because
  `ps` does not run then.
- The first second of a system process burst shows as "Not yet identified".
- kernel_task cannot be read without root. Its CPU lands in "Short lived or kernel"
  together with processes that started and exited between two samples.
- A spike is saved when it ends. If the app quits during a spike, that spike is lost.
- XPC grouping uses `responsibility_get_pid_responsible_for_pid`, a private call.
