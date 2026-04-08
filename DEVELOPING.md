# Developing mycelium

This file is for **how we develop the tool**, not for the tool's external user experience.

It describes the maintainer-side discipline for keeping the repo coherent:
- checked into git
- readable by contributors and agents working on this repo
- validated by local test suites
- recorded in mycelium notes on the files and commits involved

It is **not** part of the user-facing product surface. In particular, it should not be surfaced by `mycelium.sh prime`, `README.md`, `SKILL.md`, or other artifacts intended for external users of the tool.

## First-class artifacts

When behavior changes, treat all of these as part of the same contract:

- **code/runtime** — `mycelium.sh`, `scripts/*.sh`
- **tests** — `test/test.sh`, multi-repo tests
- **agent contract for users** — `SKILL.md`, `mycelium.sh prime`
- **human/public contract** — `README.md`
- **introspection contract** — `mycelium.sh doctor`
- **rationale/history** — mycelium notes on touched files and the change commit

## Change checklist

For every semantic change, check these in the same commit slice:

1. **Code/runtime**
   - Update `mycelium.sh` and any workflow scripts together.
2. **Tests**
   - Add or update tests for the new intended behavior.
3. **Skill**
   - Update `SKILL.md` if the agent workflow or arrival path changed.
4. **README**
   - Update `README.md` if the public contract or examples changed.
5. **Prime**
   - Check that `mycelium.sh prime` still teaches the right mental model.
6. **Doctor**
   - Check that `mycelium.sh doctor` still reflects the intended ontology/state model.
7. **Changelog**
   - Add an entry under `[Unreleased]` in `CHANGELOG.md` for any user-visible change.
   - Follow [Keep a Changelog](https://keepachangelog.com/) categories: Added, Changed, Deprecated, Removed, Fixed, Security.
   - When tagging a release, move `[Unreleased]` entries into the new version heading and update comparison links at the bottom.
8. **Notes**
   - Read notes before touching files.
   - Leave notes on touched files and on the change commit after meaningful work.
9. **Validation**
   - Run the relevant local suites.
10. **Review**
    - Before push, do tmux + interactive `pi` review/dogfooding and record the result in a note.

## Separation rule

Keep these layers distinct:

- **User-facing surfaces**: `mycelium.sh`, `README.md`, `SKILL.md`, `prime`, `doctor`, and any examples intended for external users
- **Contributor-facing surfaces**: this file, branch-specific development notes, maintainer review workflow, and other repo-maintenance discipline

Contributor process can constrain how we build the tool. It should not automatically leak into the product surfaces seen by external users.

## Release notes: two layers

Mycelium is underground — built for agents, by agents. But humans look at this
repo too, and they need a readable record of what changed.

- **CHANGELOG.md** — the human-readable surface. Maintained in
  [Keep a Changelog](https://keepachangelog.com/) format. Updated with every
  semantic change under `[Unreleased]`, stamped with a version heading when
  tagging. This is what a person reads on GitHub.
- **Mycelium notes on release commits** — the agent-readable layer. A
  `[slot:release]` note on a tag commit records what the release means,
  what was validated, what design decisions led here. Agents read this
  with `mycelium.sh read <commit> --slot release`.

Both layers are maintained in parallel. The changelog summarizes; the notes
explain. Neither replaces the other.

## Release policy

- **`main`** is the latest integrated branch, not the stable-release boundary.
- **Stable releases** are the latest non-prerelease semver tags on `main` (for example `v0.3.0`).
- **Prereleases** use semver prerelease tags on `main` (for example `v0.3.0-rc.1`, `v0.3.0-beta.1`).
- **Feature branches** remain the place for exploration and validation before merge.
- We do **not** maintain a separate `stable` branch at this project stage. Add one only if backports or parallel maintenance become real needs.
- User-facing install docs should distinguish:
  - `main` = latest integrated
  - `VERSION=X.Y.Z` = pinned stable
  - `VERSION=X.Y.Z-rc.N` = pinned prerelease

In short: branch → validate → merge to `main` → tag prerelease/stable milestone as needed.

## Tooling stance

- **Canonical source of truth for maintainer workflow:** this checked-in file
- **Hooks:** local reminders are okay, but keep shipped examples focused on the product or clearly repo-specific
- **Notes:** notes record rationale and per-slice decisions; they are not the only source of truth for the checklist itself

## Minimum local validation for this repo

```bash
./test/test.sh
./test/test-multi-repo-phase0.sh
./test/test-multi-repo-phase1.sh
```

When touching adapter code, also run the plugin compliance suite:

- `bash test/test-plugin-spec.sh` when changing anything under `integrations/`, `PLUGIN-SPEC.md`, or `test/test-plugin-spec.sh` itself.
- `cd integrations/pi && bun run typecheck && bun test` when changing anything under `integrations/pi/`.

The shipped pre-commit hook at `hooks/pre-commit` runs both of these automatically against staged files, including a graceful skip for the bun tests when `bun` is not installed.
