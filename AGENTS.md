# Repository Workflow

This repository uses a two-checkout workflow:

- WSL checkout: `/home/bc/repos/github/bonomani/baseliner`
- Windows checkout: `/mnt/c/scripts/Baseliner`

Working rules:

- Treat the WSL checkout as the source repo.
- Make edits and commits in WSL.
- Use the Windows checkout as the validation mirror.
- Sync both checkouts through Git only.
- After pushing from WSL, update the Windows checkout with `git pull --ff-only origin master`.

Practical expectations:

- Prefer Linux/WSL tools for repository maintenance and Git operations.
- Use the Windows checkout for Windows-specific execution and testing.
- Keep local/editor/runtime artifacts ignored when they are not part of the release payload.

If this file conflicts with a direct user instruction, follow the user instruction.
