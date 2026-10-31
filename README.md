# Matcha 🍵

Matcha is a CLI that lets you escape the modern markdown hell that working with an agent has become. You tell it to create a plan or a map with matcha & sit back 'n relax. No need to worry about semi-functional / semi-broken UIs.

Matcha gives the best of both worlds: 
* structured easily readable output for the human
* noise-free markdown for the clanker.

## Install

```sh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/bitbybob/matcha/main/scripts/setup)"
```

This installs `matcha` to `~/.local/bin`. Set `MATCHA_INSTALL_DIR` to choose a different directory.
It builds from source and expects `zig`, `node`, and `npm` to be available.

## Build and Run

Matcha is now a Zig CLI. Use `task` for day-to-day operations:

```sh
task run -- help
task run-plan        # writes dist/plan.html from sample_plan.json
task run-map         # writes dist/map.html from sample_map.json
task run -- serve .  # serves generated artifacts from the current directory
task test            # runs Zig unit tests
task build           # builds dist/matcha
```

The Svelte/Vite client remains a separate npm build:

```sh
task build-client
```

`task build-client` produces `plan.js`, `plan.css`, `plan-components.css`, `map.js`, `map.css`, `serve.js`,
and `serve.css` at the repo root. The Zig CLI injects these assets when rendering HTML output.

## Usage

```sh
matcha plan --input path/to/plan.json --output "~/matcha/file.html"
matcha map --input path/to/map.json --output "~/matcha/file.html"
matcha plan read plan.json
matcha plan read dist/plan.html > plan.md
matcha plan read dist/plan.html | codex
matcha serve path/to/generated_artifacts
matcha serve ~/matcha/out --host 127.0.0.1 --port 8080 --interval 10
matcha usage
```

Without explicit paths, `matcha plan` reads `sample_plan.json` and writes `dist/plan.html`; `matcha map`
reads `sample_map.json` and writes `dist/map.html`.

`matcha plan read <path>` prints a plan as Markdown to stdout. It accepts canonical plan JSON or a
matcha-generated plan HTML file. The command is stdout-only and has no `--output` option; use shell
redirection or piping to capture or forward the Markdown:

```sh
matcha plan read sample_plan.json > plan.md
matcha plan read dist/plan.html | codex
```

## Serving generated artifacts

`matcha serve <directory>` hosts an existing directory of generated Matcha HTML artifacts on your LAN.
It is read-only: only catalog browsing and serving files under `/artifacts/<encoded-relative-path>` is supported.
It never discovers JSON inputs, accepts only existing generated HTML artifacts, and does not provide
editing or upload capabilities.

Important defaults:
- bind host: `0.0.0.0` (all interfaces)
- bind port: `27004`
- catalog refresh interval: `5` seconds

Directory discovery rules:
- scan `directory` recursively for regular `.html` files
- recognize plans by `<script id="plan-data"...>` markers
- recognize maps by `<script id="map-data"...>` markers
- ignore unrelated HTML files and non-HTML files
- group by embedded `project` metadata first, then first relative directory segment, else `Ungrouped`

Interactive behavior:
- if `<directory>` is omitted in a terminal, a prompt is shown and a single path entry is accepted
- if `<directory>` is omitted in non-interactive mode, Matcha exits immediately with usage instead of waiting for input

Security posture:
- binding to `0.0.0.0` exposes documents to peers that can reach the host on the local network
- use `--host 127.0.0.1` to limit access to loopback only

`matcha usage` prints CLI instructions and the expected JSON input formats for LLMs.

To make the compiled CLI available as `matcha`, install it into `~/.local/bin` after building:

```sh
task install
```

### Project loop configuration

New loops read `.matcha.json` only in the launch directory. `--config PATH`
(or `--config=PATH`) replaces that selection; an explicit file must exist.
Project files use this envelope:

```json
{"schema_version":1,"loop":{"backend":"codex","model":null,"max_turns":10,"prompt_file":"prompts/task.md","verify_enabled":true}}
```

Settings resolve as CLI > project > user defaults > built-ins. User defaults
retain the flat JSON format at `$XDG_CONFIG_HOME/matcha/loop.json` (otherwise
`~/.config/matcha/loop.json`). Interactive `matcha loop config` edits that user
file and preserves other supported settings.

Supported loop fields are `backend`, `model`, `max_turns`, `prompt_file`,
`verifier` (backend name), `verify_enabled`, `yolo`, `token_budget`,
`timeout_seconds`, `output_mode` (`live`, `quiet`, `json`), and
`extra_backend_args`. Unknown fields, invalid types, unsupported versions, and
nonpositive configured limits fail before execution. Omitted fields inherit;
`null` clears model, prompt file, verifier override, or a limit. Null limits
mean unlimited. Booleans apply even when false; arrays replace, including `[]`.
CLI `--unlimited` overrides inherited turn limits. Future map fields should merge
by key; no map settings are exposed yet.

Explicit positional text or `--prompt-file` wins over nonblank piped stdin,
which wins over configured `prompt_file`. Explicit forms cannot be combined.
Only the winning prompt file is read, at most 1 MiB; stdin has the same bound.
Blank stdin permits configured-file fallback. Blank explicit input fails.
Config file paths are relative to their defining config directory; CLI paths
use the launch directory. Selecting a config elsewhere does not change worker cwd.

Snapshots capture objective text, execution settings, budgets, and launch cwd.
Resume uses those saved values even if source files change or disappear. Legacy
snapshots retain their shared worker/verifier model and arguments; inspection
never rewrites them. Ambient shell environment remains inherited. Callback
updates preserve captured settings, and saves replace state atomically.
