# Pull request template

## What does this PR do?

(One paragraph.)

## Per-app or shared infra?

- [ ] Per-app: `apps/<name>/`
- [ ] Shared wrapper (`wrapper/`)
- [ ] Standard (`STANDARD.md` or `agent-prompt.md`)
- [ ] CI / build pipeline (`ci/`, `.github/`)
- [ ] Documentation (`README.md`, `docs/`)
- [ ] Other: _____

## Tests run locally

- [ ] `./ci/build-app.sh <name>` succeeds
- [ ] `./ci/cardinal-rule-test.sh "dist/<Name>.app"` passes
- [ ] `./ci/lift-and-shift-test.sh "dist/<Name>.app"` passes
- [ ] `./ci/package-dmg.sh <name>` produces a .dmg
- [ ] I have installed the .dmg on a clean Mac and verified it works

## Cardinal Rule reminder

> The `.app` bundle contains no unique user data. All user data lives in `~/Library/Application Support/<bundle_id>/`.

- [ ] This PR does not introduce any code that writes user data into the `.app` bundle.
- [ ] Any new env vars or paths use `$DATA_DIR`, `$LOGS_DIR`, etc.

## Checklist

- [ ] I have read [`STANDARD.md`](STANDARD.md)
- [ ] I have read [`agent-prompt.md`](agent-prompt.md) (if this is an LLM-driven per-app update)
- [ ] I have updated `apps/<name>/DESIGN.md` if this is a per-app change
- [ ] I have run `shellcheck` on any new or modified shell scripts
- [ ] I have not modified `wrapper/Sources/` directly (changes there require explicit human review)
