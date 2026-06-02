---
name: New per-app
about: Propose adding a new per-app directory (for a new webapp)
title: "[per-app] <name>"
labels: enhancement
---

## Webapp to package

- **Name:** (e.g. Foo)
- **GitHub URL:** (e.g. https://github.com/owner/foo)
- **What it does:** (one paragraph)

## Proposed per-app structure

- **Bundle ID:** (e.g. com.example.foo)
- **Runtime:** (python / node / static / go / etc.)
- **Default port:** (e.g. 8080)
- **Source upstream:** (URL + branch to sync to)

## Checklist

- [ ] I have read [`STANDARD.md`](STANDARD.md)
- [ ] I have read [`docs/adding-a-new-webapp.md`](docs/adding-a-new-webapp.md)
- [ ] I have created `apps/<name>/` with the required files
- [ ] I have added `<name>` to the CI matrix in `.github/workflows/build.yml`
- [ ] The Cardinal Rule test passes locally
- [ ] The lift-and-shift test passes locally
- [ ] The build pipeline produces a working `.dmg`

## Open questions

Anything the maintainer should know about the webapp, its quirks, or its dependencies.
