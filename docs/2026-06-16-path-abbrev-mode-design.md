# Abbreviated path mode for the `dir` segment

Date: 2026-06-16
Branch: `feat/path-abbrev-mode` (PR into `rust`)

## Problem

The `dir` segment renders the working directory in `seg_dir`
(`rust/src/render.rs`). When a path is deeper than `VL_PATH_DEPTH`, the middle is
squashed to `first/second/…/last`, dropping intermediate components entirely.
Some users would rather *keep* every component but shorten the intermediate ones
in place, so the path's shape stays legible:

```
D:/Path/To/Git/Repo   ->   D:/Pa…/To/Gi…/Repo
```

## Goal

Add a second, opt-in path-rendering strategy ("abbrev"), selectable via config,
leaving the existing "truncate" behavior as the unchanged default.

## Scope decision: Rust-only extension

This is a **coralline-rs extension**, implemented only in `rust/src/`, exactly
like the existing `worktree` segment. The bash `statusline.sh` is **not**
changed.

Parity is preserved because the parity harness (`rust/test-parity.sh`) never sets
`VL_PATH_STYLE`, so it runs in the default `truncate` mode where bash and Rust
remain byte-identical. The new mode gets a dedicated Rust-side feature check (no
bash oracle), mirroring how `worktree` is tested.

## Design

### Config (`rust/src/config.rs`)

- New field: `path_style: String`, default `"truncate"`.
- New key in `set()`: `VL_PATH_STYLE` -> `path_style`.
- Accepted values: `truncate` (current behavior) and `abbrev` (new). Any other
  value behaves as `truncate`.

### Rendering (`rust/src/render.rs`, `seg_dir`)

The home-directory collapse (`p.cwd.starts_with(self.home)` -> `~{rest}`) is
shared by both modes and runs first, unchanged.

The split must stay exactly as today to preserve parity semantics:

```rust
let parts: Vec<&str> = short.split('/').collect();  // keep empties (leading '/')
```

Then branch on `cfg.path_style`:

- **truncate** (default): existing logic, unchanged —
  `if parts.len() as i64 > cfg.path_depth && parts.len() >= 2 { first/second/…/last } else { short }`.
- **abbrev**: ignore `path_depth`. Keep the **last** component verbatim;
  abbreviate every other component via the per-component rule below; `join("/")`.
  A path with a single component renders unchanged.

`seg_dir` then pushes `disp` exactly as it does now (same bold/fg/pill framing).

### Per-component abbreviation rule

Helper `fn abbrev_part(s: &str) -> String` applied to every component **except
the last**:

- Count length in **Unicode chars** via `s.chars().count()` (not bytes) so
  non-ASCII directory names stay correct.
- If `> 2` chars: take the first 2 chars (`s.chars().take(2).collect()`) + `…`.
- If `<= 2` chars: return `s` unchanged. This leaves the leading empty field
  from a root `/`, the drive `D:`, `~`, and short dirs like `To` whole —
  abbreviating them would only add length.

Keep length (`2`) and marker (`'…'`, `\u{2026}`) are module-level constants,
intentionally not configurable (decided during design; YAGNI).

### Worked examples

| Input (cwd) | home collapse | abbrev output |
|-------------|---------------|---------------|
| `D:/Path/To/Git/Repo` | (no home) | `D:/Pa…/To/Gi…/Repo` |
| `/Users/demo/projects/coralline` | (no home) | `/Us…/de…/pr…/coralline` |
| `C:/Users/alex/Projects/coralline` (home=`C:/Users/alex`) | `~/Projects/coralline` | `~/Pr…/coralline` |
| `D:/Repo` | (no home) | `D:/Repo` (`D:` ≤2; `Repo` last) |
| `D:` | (no home) | `D:` (single component) |

Note the `/Users/...` case: `split('/')` yields a leading empty field that the
`<=2` rule leaves whole, so the leading slash survives the join.

## Testing (`rust/test-parity.sh`)

Add a Rust-only feature check (no bash oracle), in the same style as the
`worktree` check:

- Run the binary with `VL_PATH_STYLE=abbrev` and a crafted deep `cwd` JSON,
  assert the output contains the expected abbreviated form (e.g. `Pa…` and the
  full final component) and does **not** contain the dropped-middle `…/` form.
- Keep the existing default-mode checks untouched to prove truncate parity is
  unaffected.

(The crate has no `#[cfg(test)]` unit tests today; the project's test surface is
the parity shell harness, so the new coverage goes there to match convention.)

## Documentation (`rust/README.md`)

Add a bullet to the existing **"Beyond upstream"** section describing
`VL_PATH_STYLE=abbrev`, alongside the `worktree` entry, and note the dedicated
`test-parity.sh` check.

## Out of scope

- Changing the bash `statusline.sh`.
- Configurable keep-length or marker.
- Changing the `truncate` default or any other segment.
- Width-aware/adaptive abbreviation (shorten only enough to fit the terminal).
- Layering abbrev on top of `path_depth` truncation (explicitly not chosen).
