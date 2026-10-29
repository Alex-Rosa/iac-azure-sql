# Use-case dashboard

A visual view of a use-case run, for presentations. It shows what's happening now, the topology (one
column per availability zone, the nodes, their roles and the replication link), the clock, RTO and
lost transactions, live throughput charts, the success criteria and an event log. It can follow a
run **live** or **replay** a recorded one.

```
pwsh ./dashboard/dashboard.ps1                     # asks: use case, stack, live / replay / report / compare, web or terminal
pwsh ./sqlvm-linux-ag.ps1 -Action dashboard        # same, from the menu (6) Dashboard)
```

The engine is the one from [`sqlvm-linux-ao-ag-dag-01`](../../sqlvm-linux-ao-ag-dag-01/dashboard/README.md).
It is generic: everything a use case shows comes from its `dashboard.json` and the events it writes.
For this single-region project it lays the topology out by **failure domain** instead of by region.

## Two views of the same data

| | Web page | Terminal |
|---|---|---|
| Start | `-Mode web` (default) | `-Mode terminal` |
| Where | `http://localhost:8765` (this machine only), opened in your browser | the current console, redrawn in place |
| Refresh | every `-RefreshSeconds` (default 3); clocks tick smoothly in between | every `-RefreshSeconds`; replay every second |
| Keys | `space` pause · `n`/`p` next/previous phase · `r` restart · `+`/`-` speed · `t` view | same, plus `q` quit |

`-Mode both` serves the web page and opens the terminal view in a new Terminal window. Both show the
same replay position, and either one can control it.

**Executive / Technical.** The executive view shows the zones, the nodes and their roles, the clock,
RTO / lost transactions, the main charts and the success criteria. The technical view adds VM names,
IPs, link states, every metric and chart (send/redo queues, slowest commit), phase durations, and the
full event log. Switch with the button on the page or `t` in either view. `-View technical` starts in
it, and so does `?view=technical` in the page URL.

The page has no external dependencies: no CDN and no web fonts. It works offline, in light or dark
mode (the ◐ button).

## Reading the dashboard

- **Narration banner:** the running phase, explained in plain language. Blue means running, green
  completed, red stopped (with the reason).
- **Topology:**
  - One column per **availability zone**. With an availability set it is one column per **fault
    domain**; without either, one per **host**.
  - The line under each column title names the region; the zone that fails in UC-02 is marked
    *failure domain*.
  - **■ ZONE DOWN** (red, dashed outline) means every node in the column is off. **▲ RECOVERING**
    means a node there is starting.
  - Node cards show the power dot, the role pill and the 🔒 FENCED tag (UC-02 reinstate). The
    writable primary carries a gold ★ and border.
  - Role pills: **PRIMARY**, **SECONDARY**, **LOST** (the primary that went down with its zone),
    **STALE PRIMARY** (it came back still believing it is primary).
  - **The link:** the arrow points from primary to secondary. Solid green means healthy, moving green
    dashes mean synchronizing or synchronized, thick amber means catching up after a reinstate, and
    red dotted means down. The note under it shows the current send and redo queues.
  - **Application box:** a blue arrow points at the node the application writes to. It turns red
    ("no writable primary") while there is none: that is the interruption the clock measures.
- **Key numbers:** the clocks (UC-01 *Write interruption*, UC-02 *Outage clock*), RTO, lost
  transactions (target 0) and live throughput. The technical view adds every other metric.
- **Monitoring:**
  - **Charts:** application throughput, failed attempts per second, slowest commit, and the send and
    redo queues. Dashed vertical lines mark key phases (warm-up, AG offline / failure, reconnect,
    resync).
  - The data comes from the application writer's own log (one point per second), so a chart shows
    exactly what the application experienced, even across the seconds when Run Command calls were
    busy elsewhere.
  - The terminal shows the same data as sparklines.
- **Progress:** every phase of every stage, with its duration. **Success criteria:** ✓ / ✕ per
  criterion. **Events:** newest first, errors in red.

## Live

```
pwsh ./dashboard/dashboard.ps1 -UseCase uc-02 -Mode web -RefreshSeconds 3
pwsh ./use-cases/uc-02/uc-02.ps1 -Action drill -Dashboard -DashboardMode both ...   # opens it for the drill
```

Live mode follows the **newest run** of the stack (`-Stack`: the use case's `runs/<rg>` folder,
by default the one used most recently). A new drill shows up by itself as soon as its pre-check
starts. `-Run <run-id>` pins one run instead.

The dashboard never runs anything on the VMs, so it can't collide with the use case's own
`az vm run-command` calls (Azure allows one per VM at a time). Everything comes from the run's
`events.jsonl`. The one exception is the VMs' **power state**: in live mode it polls `az vm list -d`
every `-PowerPollSeconds` (default 30, `0` = off). That's a control-plane read, so a powered-off
zone shows up the moment Azure reports it.

## Replay

```
pwsh ./dashboard/dashboard.ps1 -UseCase uc-01 -Replay latest -Speed 5
pwsh ./dashboard/dashboard.ps1 -UseCase uc-02 -Stack sqlvm-257672-node-1-node-2-rg -Replay 20261013-101500 -Speed 10 -Mode both
```

A replay plays a recorded run back at `-Speed` x (0.25–100, changeable on the page). Idle gaps
longer than `-MaxGapSeconds` (default 30) are fast-forwarded, and the page shows "⏩ skipping idle
time" while that happens. Clocks and values always show the real recorded times. Click the progress
bar or use `n`/`p` to jump between phases.

## Reports and comparisons

A **report** is the dashboard page at the end of a run, saved as one self-contained HTML file. Both
drills write one at the end (`use-cases/uc-NN/runs/<rg>/<run-id>/report.html`).

```
pwsh ./dashboard/dashboard.ps1 -UseCase uc-02 -Report latest
```

A **comparison** puts two or more runs side by side: key numbers (with B − A), criteria, phase
durations, and every chart overlaid on a common time axis. The time origin is set by the use case's
`compareOrigin`: t = 0 at the **failure** for UC-02, and at the **role swap** (AG offline) for UC-01.

```
pwsh ./dashboard/dashboard.ps1 -UseCase uc-01 -Compare 20261013-101500,20261013-113000
```

## Options

| Parameter | Default | |
|---|---|---|
| `-UseCase` | asked (or the only one) | any `use-cases/uc-NN/` with a `dashboard.json` |
| `-Stack` | most recently used | `runs/<rg>` folder of the use case |
| `-Run` | `latest` | live: pin a run id instead of following the newest |
| `-Replay` | | run id or `latest`: replay instead of live |
| `-Mode` | `web` | `web`, `terminal`, `both` |
| `-RefreshSeconds` | 3 | 1–60 |
| `-Speed` / `-MaxGapSeconds` | 5 / 30 | replay speed, idle-gap fast-forward threshold |
| `-View` | `executive` | or `technical` |
| `-Port` | 8765 | web server port (localhost only) |
| `-PowerPollSeconds` | 30 | live VM power-state poll, `0` = off |
| `-NoBrowser` | | don't open the browser |
| `-Report` / `-Compare` / `-Out` | | static report of a run / comparison of runs / output file |

## Adding a use case to the dashboard

1. **`use-cases/uc-NN/dashboard.json`**:
   - The title, stages and phases (each with a plain-language `explain`) and clocks.
   - **Metrics:** `exec`, `target` / `targetOp`, `"sample": "<key>"` for a live tile, and
     `"format": "duration"`.
   - **Success criteria:** `metric` + `op` (`exists`, `eq`, `le`, `ge`).
   - **Monitoring:** `charts` (one sample `key` each) and `chartMarkers`.
   - `compareOrigin` / `compareOriginLabel`: the phase that is t = 0 in comparisons.
   - `{placeholders}` are filled from the topology params: `{primary}`, `{secondary}`,
     `{primaryDomain}`, `{secondaryDomain}`, `{region}`.
2. **The script**: build it on [`use-cases/common/uc-common.ps1`](../use-cases/common/uc-common.ps1),
   like `uc-01.ps1` and `uc-02.ps1`. It provides the topology by zone, the application writer and its
   monitoring (`Start-UcWriter`, `Update-UcMonitor`, `Invoke-UcObserve`), the planned swap
   (`Invoke-UcPlannedFailover`), the verification (`Invoke-UcVerify`) and the session handling. The
   events themselves come from [`use-cases/common/uc-events.ps1`](../use-cases/common/uc-events.ps1):
   `Write-UcTopology`, `Set-UcAction`, `Set-UcPhase` (`-At` for steps that report their own time),
   `Set-UcNode`, `Set-UcLink`, `Set-UcSample`, `Set-UcMetric`, `Set-UcClock` and `Write-UcEvent`.
