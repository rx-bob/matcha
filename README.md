<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/full_logo_dark.png">
    <img src="assets/full_logo.png" alt="Matcha" width="640">
  </picture>
</p>

## What is Matcha?

Matcha is a CLI for structured agent workflows. No markdown nonesense or half-broken chat UIs just:

- **Self-contained interactive HTML** for humans to review, search, and navigate.
- **Clean, noise-free TOON & persistent execution loops** for coding agents (`codex`, `droid`, `agy`).

## Installation

```sh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rx-bob/matcha/main/scripts/setup)"
```

Installs `matcha` to `~/.local/bin` (override with `MATCHA_INSTALL_DIR`). Requires `zig`, `node`, and `npm`.

## Planning & Loops

### Planning

Render structured JSON plans into standalone HTML artifacts, extract clean TOON for your agent, or serve generated plans on your local network:

```sh
# Render a plan JSON into a self-contained HTML file
matcha plan --input plan.json --output plan.html

# Convert a plan (JSON or generated HTML) back into clean TOON
matcha plan read plan.html > plan.md
matcha plan read plan.html | codex

# Serve a directory of generated HTML artifacts on http://0.0.0.0:27004
matcha serve ./plans
```

Run `matcha usage` to print the prompt instructions and canonical JSON schema for LLMs.

### Loops

Run persistent, verifiable multi-turn agent loops with state tracking, turn/token/time budgets, and automatic verification:

```sh
# Configure default backend, model, and reasoning effort
matcha loop config

# Run a persistent loop with a prompt or prompt file
matcha loop "fix the build" --max-turns 10
matcha loop --prompt-file prompts/task.md --backend codex --yolo

# Inspect or resume previous loops
matcha loop list
matcha loop show --last
matcha loop resume --last
```

You can also commit a `.matcha.json` in your project root for reproducible runs:

```json
{
  "schema_version": 1,
  "loop": {
    "backend": "codex",
    "prompt_file": "prompts/task.md",
    "max_turns": 50
  }
}
```
