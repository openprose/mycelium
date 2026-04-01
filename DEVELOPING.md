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
7. **Notes**
   - Read notes before touching files.
   - Leave notes on touched files and on the change commit after meaningful work.
8. **Validation**
   - Run the relevant local suites.
9. **Review**
   - Before push, do tmux + interactive `pi` review/dogfooding and record the result in a note.

## Separation rule

Keep these layers distinct:

- **User-facing surfaces**: `mycelium.sh`, `README.md`, `SKILL.md`, `prime`, `doctor`, and any examples intended for external users
- **Contributor-facing surfaces**: this file, branch-specific development notes, maintainer review workflow, and other repo-maintenance discipline

Contributor process can constrain how we build the tool. It should not automatically leak into the product surfaces seen by external users.

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
