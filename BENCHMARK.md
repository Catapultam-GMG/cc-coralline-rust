# Benchmarking coralline

[繁體中文說明](./BENCHMARK.zh-TW.md)

Claude Code re-executes the statusline once per second, so a render's cost is a product constraint rather than a detail. This document is the method used to produce the performance numbers in release notes. It exists because several plausible-looking measurements taken during the v0.13.0 work were wrong, and every one of them was wrong in a way that produced a confident, readable, incorrect number.

## What to measure

**CPU time (`user + sys`), not wall time**, whenever the question is "does this change cost more work". Under concurrency, wall time is dominated by scheduling and contention: a 40% CPU reduction can be invisible in wall time, and a broken harness can invent a 2x wall-time difference that does not exist.

**Wall time** answers a different question: what the user waits for. Use it when the claim is about the refresh interval, and measure the whole process, including interpreter startup. The two are not interchangeable, and a release note that mixes them will contradict itself. The v0.13.0 PowerShell figures differ by 400 ms depending on which one is quoted, which lands on opposite sides of the one-second refresh.

Always measure the **interpreter floor**: how long a bare `bash`/`powershell.exe` that does nothing takes on that host. Subtract it mentally before attributing cost to coralline.

## Experiment design

**Paired alternating rounds.** Each round runs every arm back to back. Ambient load then lands on all arms within the same round instead of on whichever arm happened to run during a spike.

**Rotate which arm leads.** Round `r` starts at arm `r % count`. Without this, the first arm systematically pays for cold caches.

**Carry a byte-identical control arm.** Copy the candidate to a second name and measure it as if it were a separate version. Its measured difference from the candidate is the noise floor. Every number smaller than that floor is not a result. This is the single highest-value habit in this document: during the v0.13.0 work it caught two false conclusions, and its absence produced both of them.

**Report medians of per-round statistics**, not a mean over all renders. Compute p50/p95/max within a round, then take the median across rounds.

**A paired ratio is not the quotient of two medians.** If you publish both, say so, or a reader will divide the two absolute numbers and fail to reproduce your ratio.

## Environment control

- **Disable the live statuslines.** They are the same program under test, running once per second in every open session. Back up `~/.claude/settings.json`, record its SHA-256, remove `statusLine` and `subagentStatusLine`, run, restore, and verify the hash matches. Tie the restore to the same command as the run so an interruption cannot leave the user without a statusline.
- **Strip inherited configuration.** Unset every `REMORA_*` and `CORALLINE_*` variable in the child environment. An earlier benchmark inherited them and had to be discarded entirely.
- **Never point a benchmark at the live store.** Give each arm its own state directory. A misconfigured arm that falls back to defaults will read and write `~/.claude/coralline/`.
- **Record the host load** before and after. A result taken at load average 20 is not comparable to one taken at load average 3, even if the relative comparison survives.

## Fixture

Each arm gets an identical state directory containing both shapes of history, so one fixture is fair to every generation:

- `burn-5h.tsv` with `BURN_TRIM` rows, so trimming and healing are exercised rather than skipped.
- `burn-5h.d/` with N marker directories named `b_<reset:12>_<sample:12>_<pct>_<counter>`, which only the v0.12 generation walks. Without it, that generation is measured in its best case and the regression looks an order of magnitude smaller than it is.
- `limit-5h.d/` and `limit-7d.d/` each with one `<reset:10>_<pct:7.3>` entry.

Vary the marker count (350 / 1400 / 4000) to expose cost that scales with history. A single fixture size cannot distinguish "slower" from "slower the longer you use it", and the second is the defect that matters.

Set `CORALLINE_NO_SAMPLE=1` to measure the read path alone. The difference against a mutating run is the write path, which is where hardening costs concentrate.

## Harness pitfalls

Each of these produced a wrong number that looked reasonable.

**Do not feed stdin from the parent.** Spawning N children with `stdin=PIPE` and then writing to them one at a time serialises them: a child blocks on its first read until the parent reaches it, while its timer is already running. Measured effect at n=12: p50 inflated 2.3x, max 4.3x, and the distortion depends on spawn order. Open the payload file per child and hand over the descriptor.

**Give each variant a distinct output filename.** Deriving it from `basename $BASH` gives `bash` for both `/bin/bash` and `/opt/homebrew/bin/bash`, and the second run silently overwrites the first.

**`sed 's/x/y/' f > f` truncates `f`.** The shell opens the redirect before `sed` reads. Generate from a template, never from a sibling of the file you are writing.

**Do not name a script after a stdlib module.** `bisect.py` shadows Python's `bisect`, which `statistics` imports transitively, and the failure surfaces as a confusing circular-import error.

**`$(times)` measures the subshell.** Command substitution and pipelines both fork, so `t=$(times)` and `times | head -1` report zeros. Measure a child process from a parent that can read its `rusage` instead.

**zsh `noclobber` silently keeps the old file.** `cat > f` on an existing file fails, often without failing the surrounding command. `rm -f` first, and read back anything that will be published.

**On Windows, drive from a native PowerShell parent.** Launching children from an MSYS bash parent adds roughly 240 ms per child, which is larger than most effects being measured.

**Do not build Windows commands as inline quoted strings over SSH.** Multi-level quoting through `ssh` + `powershell -Command` mangles arguments in ways that look like program errors. Write a `.ps1`, `scp` it, and run it with `-File`.

**Write config files with LF endings.** CRLF in a `coralline.conf` makes both runtimes reject the paths it declares.

## Before concluding

Attribute before you publish. A single number telling you "this version is slower" is a starting point, not a finding.

1. **Bisect across merge points.** Stage each merge commit as an arm. If the whole delta appears at one commit, you have a cause rather than a suspicion.
2. **Split the render.** Compare with no state segments, with the state path read-only, and with mutation enabled. The v0.13.0 gap against v0.11 was 1.0 ms in general rendering, 0.8 ms on the read path, and 13.3 ms on the write path, which pointed straight at per-mutation revalidation.
3. **Microbenchmark the suspect in isolation.** Run the function N times in one process and divide. A function suspected of costing 9 ms turned out to cost 38 microseconds; the 9 ms was noise from a 15-round sample with no control arm.

## Reproducing the v0.13.0 numbers

Arms: `v0.11.0`, `v0.12.0`, the merge of #58, and the release under test, each extracted with `git show <ref>:statusline.sh`. Cohorts n = 1, 5, 12, 16. 25 paired rounds per cohort, arms rotated, on macOS Bash 3.2.57 and 5.3.15 with the live statuslines disabled. Windows figures use the same design on native x64 PowerShell 5.1 with a byte-identical control arm and the interpreter floor measured in the same run.
