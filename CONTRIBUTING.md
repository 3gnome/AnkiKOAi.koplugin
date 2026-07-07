# Contributing to AnkiKOAi

Thanks for your interest in improving AnkiKOAi! This plugin turns KOReader
highlights into Anki cards, and contributions of all kinds are welcome: bug
reports, documentation fixes, new card types, AI provider support, and more.

## Ways to contribute

- **Report a bug** — open an [issue](../../issues) using the Bug report template.
- **Request a feature** — open an issue using the Feature request template.
- **Improve docs** — fixes to `README.md` or anything in `docs/` are very welcome.
- **Submit code** — fork, branch, and open a pull request (see below).

## Development setup

This is a [KOReader](https://github.com/koreader/koreader) plugin written in Lua.

1. Fork and clone the repository.
2. Copy the config template and add your own keys (this file is gitignored):

   ```bash
   cp configuration.lua.sample configuration.lua
   cp LOCAL_DEV.md.sample LOCAL_DEV.md   # optional: local paths for Cursor AI
   ```

   Edit `LOCAL_DEV.md` with your WSL paths (gitignored). Attach `@LOCAL_DEV.md` in Cursor chat when working locally.

3. Run it against the KOReader desktop emulator or a stable AppImage with the
   helper script:

   ```bash
   bash start.sh --emulator alice.epub   # dev emulator + plugin synced
   bash start.sh --appimage alice.epub   # stable AppImage (recommended on WSL)
   ```

   See the header of `start.sh` and `docs/getting-started.md` for details.

## Pull request guidelines

- Create a topic branch from `main` (e.g. `fix/anki-sync-timeout`).
- Keep PRs focused — one logical change per PR is easier to review.
- Match the existing Lua style (indentation, naming) in the file you edit.
- **Never commit secrets.** `configuration.lua`, `*_settings.json`,
  `*_cards.json`, and `*.log` are gitignored — keep it that way. Only
  `configuration.lua.sample` (placeholder keys) should be committed.
- Update docs when you change user-facing behavior.
- Describe what changed and why in the PR description, and link any related issue.
- Test on the emulator (and on-device if you can) before submitting.

## Reporting security issues

If you find a security problem (e.g. credential handling), please avoid filing a
public issue with sensitive details — open a minimal issue asking for a private
contact, or note it discreetly so it can be addressed before disclosure.

## Code of conduct

Be respectful and constructive. We want this to be a welcoming project for
readers and language learners of all backgrounds.
