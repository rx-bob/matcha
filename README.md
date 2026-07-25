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
