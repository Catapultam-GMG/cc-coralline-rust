# Abbreviated Path Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in `VL_PATH_STYLE=abbrev` mode to the `dir` segment that shortens each intermediate path component to its first two characters + `…` while keeping the final component whole, leaving the default `truncate` behavior unchanged.

**Architecture:** A coralline-rs–only extension (no `statusline.sh` change), exactly like the existing `worktree` segment. A pure helper `abbrev_path` (unit-tested) does the string work; `seg_dir` branches on a new `path_style` config field; a no-oracle feature check in `test-parity.sh` guards it. Default mode is `truncate`, so the byte-parity harness stays green.

**Tech Stack:** Rust (the `rust/` crate, edition per `Cargo.toml`), bash parity harness (`rust/test-parity.sh`).

---

## File Structure

- `rust/src/render.rs` — add `ABBREV_KEEP`/`ABBREV_MARK` consts, free fns `abbrev_part` + `abbrev_path`, a `#[cfg(test)] mod tests`, and branch `seg_dir` on `path_style`.
- `rust/src/config.rs` — add `path_style` field, its default, and the `VL_PATH_STYLE` parse arm.
- `rust/test-parity.sh` — add a Rust-only feature check for abbrev mode.
- `rust/README.md` — document `VL_PATH_STYLE=abbrev` in the "Beyond upstream" section.

All work happens on branch `feat/path-abbrev-mode` (already checked out at `~/cc-coralline-rust`). Run commands from the repo root unless noted.

---

## Task 1: Pure abbreviation helpers (TDD)

**Files:**
- Modify: `rust/src/render.rs` (add consts + free fns near the other top-level helpers, e.g. just above `struct Seg`/the other `fn`s; and a test module at end of file)

- [ ] **Step 1: Write the failing tests**

Append this module at the very end of `rust/src/render.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn abbrev_keeps_last_and_shortens_middles() {
        assert_eq!(
            abbrev_path("D:/Path/To/Git/Repo"),
            "D:/Pa\u{2026}/To/Gi\u{2026}/Repo"
        );
    }

    #[test]
    fn abbrev_preserves_leading_slash() {
        assert_eq!(
            abbrev_path("/Users/demo/projects/coralline"),
            "/Us\u{2026}/de\u{2026}/pr\u{2026}/coralline"
        );
    }

    #[test]
    fn abbrev_leaves_home_tilde_whole() {
        assert_eq!(abbrev_path("~/Projects/coralline"), "~/Pr\u{2026}/coralline");
    }

    #[test]
    fn abbrev_single_component_unchanged() {
        assert_eq!(abbrev_path("D:"), "D:");
        assert_eq!(abbrev_path("Repo"), "Repo");
    }

    #[test]
    fn abbrev_leaves_short_components_whole() {
        assert_eq!(abbrev_path("/a/b/c/d"), "/a/b/c/d");
    }
}
```

- [ ] **Step 2: Run tests to verify they fail (compile error: `abbrev_path` undefined)**

Run: `cargo test --manifest-path rust/Cargo.toml abbrev`
Expected: FAIL — `cannot find function 'abbrev_path' in this scope`.

- [ ] **Step 3: Write the minimal implementation**

Add these consts and free functions to `rust/src/render.rs`, just below the existing `const NORM` line (top-level, not inside `impl`):

```rust
/// Keep this many leading chars of an abbreviated path component.
const ABBREV_KEEP: usize = 2;
/// Marker appended to a component that was shortened.
const ABBREV_MARK: char = '\u{2026}';

/// Shorten one path component to `ABBREV_KEEP` chars + `ABBREV_MARK`. Components
/// of `ABBREV_KEEP` chars or fewer (the empty leading field of a rooted path,
/// `~`, `D:`, short dir names) are returned unchanged — abbreviating them would
/// only add length. Length is counted in Unicode chars, not bytes.
fn abbrev_part(s: &str) -> String {
    if s.chars().count() > ABBREV_KEEP {
        let mut out: String = s.chars().take(ABBREV_KEEP).collect();
        out.push(ABBREV_MARK);
        out
    } else {
        s.to_string()
    }
}

/// Abbreviate every component except the last. Splits on '/' WITHOUT dropping
/// empties (matching `seg_dir`'s split semantics) so a leading '/' survives the
/// rejoin. A single-component path is returned unchanged.
fn abbrev_path(short: &str) -> String {
    let parts: Vec<&str> = short.split('/').collect();
    if parts.len() <= 1 {
        return short.to_string();
    }
    let last = parts.len() - 1;
    parts
        .iter()
        .enumerate()
        .map(|(i, p)| if i == last { (*p).to_string() } else { abbrev_part(p) })
        .collect::<Vec<_>>()
        .join("/")
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test --manifest-path rust/Cargo.toml abbrev`
Expected: PASS — 5 tests pass (`abbrev_keeps_last_and_shortens_middles`, `abbrev_preserves_leading_slash`, `abbrev_leaves_home_tilde_whole`, `abbrev_single_component_unchanged`, `abbrev_leaves_short_components_whole`).

- [ ] **Step 5: Commit**

```bash
git add rust/src/render.rs
git commit -m "feat(render): add abbrev_path helper for abbreviated path mode"
```

---

## Task 2: Config field `path_style` / `VL_PATH_STYLE`

**Files:**
- Modify: `rust/src/config.rs` (struct field after `path_depth` line 23; default after `path_depth: 4,` line 71; parse arm after `VL_PATH_DEPTH` line 167)

- [ ] **Step 1: Add the struct field**

In `rust/src/config.rs`, immediately after the line `pub path_depth: i64,`, add:

```rust
    pub path_style: String,
```

- [ ] **Step 2: Add the default value**

In the `impl Default for Config`, immediately after the line `path_depth: 4,`, add:

```rust
            path_style: "truncate".into(),
```

- [ ] **Step 3: Add the config parse arm**

In `fn set`, immediately after the line `"VL_PATH_DEPTH" => self.path_depth = v.parse().unwrap_or(self.path_depth),`, add:

```rust
            "VL_PATH_STYLE" => self.path_style = v,
```

- [ ] **Step 4: Verify it compiles**

Run: `cargo build --manifest-path rust/Cargo.toml`
Expected: builds with no errors (a warning that `path_style` is never read is acceptable here — Task 3 consumes it).

- [ ] **Step 5: Commit**

```bash
git add rust/src/config.rs
git commit -m "feat(config): add VL_PATH_STYLE (default truncate)"
```

---

## Task 3: Branch `seg_dir` on `path_style`

**Files:**
- Modify: `rust/src/render.rs` (`seg_dir`, the `let disp = ...` block, currently render.rs:235-239)

- [ ] **Step 1: Replace the `disp` computation**

In `fn seg_dir`, replace this exact block:

```rust
        let disp = if parts.len() as i64 > cfg.path_depth && parts.len() >= 2 {
            format!("{}/{}/\u{2026}/{}", parts[0], parts[1], parts[parts.len() - 1])
        } else {
            short
        };
```

with:

```rust
        let disp = if cfg.path_style == "abbrev" {
            abbrev_path(&short)
        } else if parts.len() as i64 > cfg.path_depth && parts.len() >= 2 {
            format!("{}/{}/\u{2026}/{}", parts[0], parts[1], parts[parts.len() - 1])
        } else {
            short
        };
```

(`parts` is still computed and used by the `truncate` branch; the `abbrev` branch borrows `short` and the `else` still moves it — this compiles under NLL since `parts` is dead by the move point.)

- [ ] **Step 2: Verify the whole crate still builds and unit tests pass**

Run: `cargo test --manifest-path rust/Cargo.toml`
Expected: PASS — all tests (including Task 1's `abbrev_*`) pass; no warnings about unused `path_style`.

- [ ] **Step 3: Manual smoke test against the built binary (no jq needed)**

```bash
cargo build --release --manifest-path rust/Cargo.toml
printf '. %s/themes/claude-coral.conf\nVL_PATH_STYLE="abbrev"\nVL_SEGMENTS="dir"\n' "$PWD" > /tmp/abbrev.conf
printf '{"cwd":"D:/Path/To/Git/Repo"}' | CORALLINE_CONFIG=/tmp/abbrev.conf rust/target/release/coralline.exe
```

Expected: the rendered `dir` pill contains `D:/Pa…/To/Gi…/Repo` (colors/escapes around it are fine).

Sanity-check the default is unchanged:

```bash
printf '. %s/themes/claude-coral.conf\nVL_SEGMENTS="dir"\n' "$PWD" > /tmp/trunc.conf
printf '{"cwd":"D:/Path/To/Git/Repo"}' | CORALLINE_CONFIG=/tmp/trunc.conf rust/target/release/coralline.exe
```

Expected: pill contains `D:/Path/…/Repo` (the existing truncate output, since depth 5 > default 4).

- [ ] **Step 4: Commit**

```bash
git add rust/src/render.rs
git commit -m "feat(render): wire seg_dir to VL_PATH_STYLE=abbrev"
```

---

## Task 4: Parity-harness feature check

**Files:**
- Modify: `rust/test-parity.sh` (add a check just before the final `rm -rf "$tmp" ...` cleanup line)

- [ ] **Step 1: Add the feature check**

In `rust/test-parity.sh`, immediately before the final cleanup line
`rm -rf "$tmp" "$HOME/.claude/coralline/.cache/out-native" 2>/dev/null`, insert:

```bash
# Feature check (NO upstream oracle — abbrev path mode is a coralline-rs
# extension): a deep cwd with VL_PATH_STYLE=abbrev shortens intermediate
# components in place and keeps the final one whole.
printf '. %s/themes/claude-coral.conf\nVL_PATH_STYLE="abbrev"\nVL_SEGMENTS="dir"\n' "$RT" > "$tmp/conf"
got=$(printf '{"cwd":"D:/Path/To/Git/Repo"}' | CORALLINE_CONFIG="$tmp/conf" "$EXE" 2>/dev/null)
if printf '%s' "$got" | grep -q 'Pa…/To/Gi…/Repo'; then
  printf '  ✓ %s\n' "feature: abbrev path mode"; pass=$((pass+1))
else
  printf '  ✗ %s\n' "feature: abbrev path mode"; printf '%s' "$got" | cat -v | head -1; fail=$((fail+1))
fi
```

- [ ] **Step 2: Run the parity harness (best-effort locally; required in CI)**

Run (from `rust/`, after `cargo build --release`):

```bash
cd rust && bash test-parity.sh; cd ..
```

Expected: ends with `── N passed, 0 failed ──`, and the line `  ✓ feature: abbrev path mode` is present.

> Local note: the harness needs `jq`, `perl`, `git`, and bash for the oracle. On this Windows box `jq` lives at `~/bin` and is not on `PATH` — if the script aborts with `need jq`, prepend it: `PATH="$HOME/bin:$PATH" bash test-parity.sh`. If local tooling is still missing, rely on the PR's `rust-parity` CI (Linux/macOS/Windows) as the gate; the manual smoke test in Task 3 already confirms the feature output.

- [ ] **Step 3: Commit**

```bash
git add rust/test-parity.sh
git commit -m "test(parity): add abbrev path mode feature check"
```

---

## Task 5: Documentation

**Files:**
- Modify: `rust/README.md` ("Beyond upstream" section, after the `worktree` bullet ending `...there's no upstream output to diff against).`)

- [ ] **Step 1: Add the doc bullet**

In `rust/README.md`, immediately after the `worktree` bullet in the "Beyond upstream" section, add:

```markdown
- **`VL_PATH_STYLE=abbrev`** — an alternative `dir` rendering. The default
  (`truncate`) collapses paths deeper than `VL_PATH_DEPTH` to
  `first/second/…/last`; `abbrev` instead keeps every component but shortens each
  intermediate one to its first two characters + `…`, leaving the final
  component whole — e.g. `D:/Path/To/Git/Repo` → `D:/Pa…/To/Gi…/Repo`.
  `VL_PATH_DEPTH` is ignored in this mode. `test-parity.sh` includes a dedicated
  check for it (there's no upstream output to diff against).
```

- [ ] **Step 2: Verify the section reads correctly**

Run: `grep -n "VL_PATH_STYLE" rust/README.md`
Expected: one match inside the "Beyond upstream" section.

- [ ] **Step 3: Commit**

```bash
git add rust/README.md
git commit -m "docs: document VL_PATH_STYLE=abbrev in Beyond upstream"
```

---

## Task 6: Push and open PR

- [ ] **Step 1: Push the branch**

```bash
git push -u origin feat/path-abbrev-mode
```

- [ ] **Step 2: Open the PR into `rust`**

```bash
gh pr create --base rust --head feat/path-abbrev-mode \
  --title "feat: abbreviated path mode (VL_PATH_STYLE=abbrev)" \
  --body "Adds an opt-in \`VL_PATH_STYLE=abbrev\` mode to the \`dir\` segment: intermediate path components are shortened to their first two chars + … while the final component stays whole (e.g. \`D:/Path/To/Git/Repo\` → \`D:/Pa…/To/Gi…/Repo\`). Rust-only extension like \`worktree\`; default \`truncate\` is unchanged, so byte-parity holds. Includes unit tests, a parity-harness feature check, and docs. Design: docs/2026-06-16-path-abbrev-mode-design.md"
```

Expected: PR created; `rust-parity` CI runs on Linux/macOS/Windows. Confirm the parity job (including the new abbrev feature check) is green before merge.

---

## Self-Review Notes

- **Spec coverage:** config field + key (Task 2), `seg_dir` branch ignoring `path_depth` (Task 3), per-component rule via `abbrev_part`/`abbrev_path` (Task 1), parity feature check (Task 4), README "Beyond upstream" doc (Task 5) — all spec sections mapped. The spec said coverage "goes to the shell harness"; this plan additionally adds Rust unit tests for the pure helper because TDD needs a test-first vehicle — strictly additive, no parity impact.
- **Naming consistency:** `path_style` (field) / `VL_PATH_STYLE` (key) / `abbrev_path` / `abbrev_part` / `ABBREV_KEEP` / `ABBREV_MARK` used identically across all tasks.
- **Values:** keep length `2` and marker `…` (`\u{2026}`) match the spec's worked examples and the unit-test expectations.
