# Runtime-agnostic engine, macOS installer, per-user config layer

**Status:** accepted

boxwood's engine carries **no language-runtime, editor, or OS dependency of its own**:
config is parsed with `yq` (not Ruby), the editor and AI **Assistant** are configurable
commands rather than hardcoded `nvim`/RubyMine/`claude`, and the only platform-specific
piece is the installer (macOS / Homebrew). Developer preferences — in-tmux editor,
external GUI editor, Assistant command — move to a new **per-user `~/.ws/config.yml`**
that applies across every repo and is never committed; the per-repo `.ws/` recipe stays
purely about the *stack*. This extends ADR-0002 (stack-agnostic) to also be
*runtime/editor/developer*-agnostic, so "works for any repo" means any language, any
editor, and (engine-wise) any POSIX OS — even though we ship a Mac-only installer first.

## Considered options

- **Keep Ruby for YAML parsing.** Zero migration, but forces a Ruby install on every Go/
  Node/Rust shop — a self-contradiction for a "works with anything" tool. Rejected in
  favor of `yq` (one Homebrew-installable static binary, keeps the commented recipe).
- **Config as JSON instead of YAML.** No new dep (`jq` already required), but loses the
  self-documenting comments in the recipe humans hand-edit per repo. Rejected.
- **Editor/Assistant as plain env vars** (`$EDITOR`, `$BOXWOOD_ASSISTANT`) instead of a
  per-user config file. Lighter, kept as the fallback, but no single place to see/set
  multi-value prefs. Rejected as the primary mechanism.
- **Editor/Assistant committed in the per-repo `.ws/config.yml`.** Bakes one developer's
  RubyMine/Claude choice into a recipe teammates inherit. Rejected — wrong owner.
- **Cross-platform (Linux) installer now.** Doubles install/portability surface (brew vs
  apt/dnf, `open` vs `xdg-open`) for no current need. Deferred: keep the *engine*
  Linux-clean (POSIX commands, `date` GNU fallback) so a Linux installer is additive
  later, but ship macOS-only first.
- **`gh`/GitHub as a hard requirement, auth in `ws init`.** Matches a literal "authorize
  to GitHub at init" reading, but GitHub auth is machine-global and one-time (belongs in
  the installer), and hard-requiring `gh` blocks local-only/GitLab repos. Rejected: `gh`
  stays optional (only `--pr` needs it); the installer does the one-time `gh auth login`.

## Consequences

- New dependency set: required `git docker tmux jq yq`; optional `gh` (for `--pr`) and
  `claude` (the Assistant, per-user, skippable). Ruby drops off entirely.
- `lib/config.sh` swaps the `ruby -ryaml -rjson` parse for `yq -o=json`.
- `launch_tmux` reads editor/Assistant from `~/.ws/config.yml`; the `claude:` block leaves
  the per-repo recipe and becomes `assistant:` in the per-user config (refines ADR-0002's
  "Claude context" to "Assistant context").
- The installer becomes a remote one-liner (`bash -c "$(curl -fsSL …/install.sh)"`) that
  bootstraps Homebrew, installs the dep set, installs OrbStack, clones boxwood to
  `~/.boxwood`, and runs a short interactive tail (launch OrbStack, `gh auth login`,
  optional Claude) — the irreducibly-interactive steps that cannot be automated.
- `cmd_attach`'s unconditional `git fetch origin` / `origin/$main_branch` must degrade
  gracefully for remote-less or non-`origin` repos.
- Verification shifts off Wescom as the dev loop: `bats` unit tests for pure logic + an
  `alpine`-image smoke repo for the full Docker lifecycle, with Wescom as a one-shot
  parity run.
