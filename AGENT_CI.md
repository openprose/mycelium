# Agent-native CI

This repo keeps its first-class artifacts in sync **inside the repo**, not in GitHub Actions.

Think of this as local, agent-native CI:
- checked into git
- readable by agents
- surfaced by `mycelium.sh prime`
- reinforced by local hooks
- validated by local test suites
- recorded in mycelium notes on the files and commits involved

## First-class artifacts

When behavior changes, treat all of these as part of the same contract:

- **code/runtime** — `mycelium.sh`, `scripts/*.sh`
- **tests** — `test/test.sh`, multi-repo tests
- **agent contract** — `SKILL.md`, `mycelium.sh prime`
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

## Tooling stance

- **Canonical source of truth:** this checked-in file
- **Agent surfacing:** `mycelium.sh prime` should print this when present
- **Hook behavior:** hooks may remind, but should stay lightweight and non-blocking where possible
- **Notes:** notes record rationale and per-slice decisions; they are not the only source of truth for the checklist itself

## Minimum local validation for this repo

```bash
./test/test.sh
./test/test-multi-repo-phase0.sh
./test/test-multi-repo-phase1.sh
```
