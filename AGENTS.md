# AGENTS.md

Guidance for contributors to the **pve_helper_scripts** repository.  
Unless a subdirectory contains its own `AGENTS.md`, all instructions below apply throughout the repo.

---

## General Practices
- Use clear, imperative commit messages (`Add snapshot cleanup flag`).
- Run `git status` before committing to ensure only intended changes are staged.
- Update relevant documentation (`README.md`, inline comments) when behavior changes.
- Pull requests should describe the change, testing performed, and any follow‑up work.

---

## Shell Scripts (`*.sh`)
- Shebang: `#!/usr/bin/env bash`
- Safety header: `set -euo pipefail` and `IFS=$'\n\t'`
- Indentation: 4 spaces; no tabs
- Comment each function with a brief description
- Validate with `shellcheck path/to/script.sh`
- <ins>TODO:</ins> Add project-specific shell style guidelines or lint commands here

---

## Python (`*.py`)
- Target Python version: `3.x`  
- Follow PEP 8; format with `black` (or chosen formatter)
- Prefer type hints for new code
- Lint using `flake8` or `ruff` before committing
- <ins>TODO:</ins> Document any virtual environment or dependency management steps

---

## HTML / Static Assets
- Ensure files end with a trailing newline
- Use single quotes for HTML attributes unless double quotes are required
- Keep inline scripts/styles minimal; favor external files where possible
- <ins>TODO:</ins> Add formatting or accessibility guidelines for the dashboard

---

## Testing & Validation
- Run `shellcheck` on modified shell scripts
- Execute Python linting/tests (`pytest`) if applicable
- <ins>TODO:</ins> Provide instructions for manual or integration testing (e.g., running upgrade orchestrator in a staging cluster)

---

## Release & CI/CD
- Workflows should use the latest stable GitHub Actions (e.g., `actions/checkout@v4`)
- Update version numbers and changelog before tagging a release
- <ins>TODO:</ins> Insert manual release steps, required credentials, or additional CI checks

---

## Adding New Directories
If a subdirectory has unique conventions, create an `AGENTS.md` inside it with additional or overriding instructions.

---

_This file is a living document—update it as the project evolves._
