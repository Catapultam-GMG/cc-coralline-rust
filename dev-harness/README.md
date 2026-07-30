# Differential harness for the one-pass burn state change

Not part of the upstream test suite. Drop this directory before opening a PR
unless the maintainer wants it.

It compares the patched `statusline.sh` against the pristine one from `main`
across a set of state-store shapes, checking two things per case: the rendered
statusline byte-for-byte, and the state store on disk after the render.

    cases.py       builds 13 store shapes anchored to a given epoch
    run_suite.sh   render-output equivalence + timing (mutation disabled)
    run_mut.sh     post-render store-state equivalence (mutation enabled)
    mkinput.sh     Claude Code payload with reset times anchored to now
    gen.sh         synthetic store of N markers + M legacy TSV rows
    bench.sh       median render time
    test.conf      minimal config: burn + limit segments only, no clock

Both runners expect `t_repo_base.sh` (pristine `main`) and `t_repo_fast.sh`
(patched), each with a `CORALLINE_FAKE_NOW` hook inserted after the `NOW=`
line so the two revisions can be compared at a pinned timestamp. Run these
from inside `dev-harness/`:

    git -C .. show main:statusline.sh > /tmp/base.sh
    sed '241a NOW=${CORALLINE_FAKE_NOW:-$NOW}' /tmp/base.sh > t_repo_base.sh
    sed '241a NOW=${CORALLINE_FAKE_NOW:-$NOW}' ../statusline.sh > t_repo_fast.sh

The harness itself requires GNU coreutils (`date -d`, `%s%N` timestamps) and
gawk, and was developed on Linux/WSL2 — it is not expected to run on stock
macOS, unlike `statusline.sh` itself.
