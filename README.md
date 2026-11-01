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
task run-plan-designs # all designs + comparison index at dist/plan-designs/index.html
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

Browser acceptance checks run against the generated standalone sample plan:

```sh
task build-client
task run-plan
cd client
npx playwright install chromium
npm run test:browser
```

The suite checks navigation/history, themes, search, clipboard fallbacks, HTML/JSON downloads,
PDF printing, and mobile focus behavior. Screenshots, the PDF, and results are saved to
`/tmp/matcha-browser-evidence` (override with `MATCHA_BROWSER_OUTPUT`). The local reference
prototype at `references/ui/chonk.html` is used for comparison screenshots.

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

### Persistent loops

From a project directory, run `matcha loop` with `.matcha.json` and a prompt file.
Matcha checks only the launch directory; it never searches parents. `--config PATH`
selects a replacement project file, which must exist. The worker still runs in
the launch directory. User defaults remain flat JSON at
`$XDG_CONFIG_HOME/matcha/loop.json` or `~/.config/matcha/loop.json`;
`matcha loop config` edits that user file while preserving other fields.

```json
{
  "schema_version": 1,
  "loop": {
    "backend": "codex",
    "prompt_file": "prompts/task.md",
    "max_turns": 50,
    "env_files": [".matcha.env"],
    "env": { "TOOLCHAIN_HOME": "/opt/toolchains/current" },
    "path_prepend": ["tools/bin"],
    "log_dir": "build/agent-logs",
    "verifier": { "backend": "codex", "args": [] }
  }
}
```

Create `prompts/task.md` and `.matcha.env` beside this config before running it.
The resolver test checks this exact JSON example.
Other `loop` fields: `backend_bin`, `model`, `reasoning_effort`, `verify_enabled`,
`sandbox`, `yolo`, `token_budget`, `timeout_seconds`, `output_mode` (`live`, `quiet`,
`json`), and `extra_backend_args`. `verifier` accepts `backend`, `backend_bin`,
`model`, `reasoning_effort`, and `args`; legacy string backend names still work.
Unknown fields, wrong types, unsupported schema versions, and invalid limits fail
before execution. Limits must be positive; `null` clears nullable values, including
`max_turns` (unlimited), model, reasoning, prompt file, and log directory.

CLI values override project values, which override user defaults, which override
built-ins. Omitted fields inherit; explicit booleans apply even when false. Maps
merge by key; arrays replace, including `[]`. `--unlimited` clears inherited turn
limits. Relative paths from a config file use that file's directory; CLI paths
use the invocation directory. This includes prompt, env, PATH, log, and executable
paths. Bare executable names resolve through the effective child `PATH`.

Prompt order: positional text or `--prompt-file` > nonblank piped stdin > configured
`prompt_file`. Positional text and `--prompt-file` conflict. A blank pipe permits
config fallback; a bad explicit file fails. Prompt files and stdin are capped at
1 MiB. Flags work before or after positional text; `--` sends following arguments
only to the worker. `@task.md` is literal prompt text.

Use `--max-turns N` or `--unlimited`, `--token-budget N`, and `--timeout 45m`
to bound a run. `--quiet` and `--json` change terminal output, not audit logs.

```sh
matcha loop
matcha loop --config ./config/automation.json
matcha loop "fix the build" --max-turns 5
matcha loop --prompt-file ./task.md --env TOOLCHAIN_HOME=/opt/toolchains/current --path-prepend ./tools/bin --log-dir ./logs
matcha loop resume --last --env TOOLCHAIN_HOME=/opt/toolchains/new --log-dir ./recovery-logs
```

`--env KEY=VALUE` and `--env-file PATH` repeat. Env files accept `KEY=VALUE`, blank
lines, whole-line `#` comments, optional `export`, and matching outer quotes.
Values remain literal: no shell expansion or command execution. In each layer,
env files load in order, then direct `env`/`--env` values win; higher layers win
by key. Configured `path_prepend` and repeated `--path-prepend` replace inherited
lists. Child PATH order is Matcha's executable directory, configured prefixes in
their given order, then inherited PATH. Both roles receive the same environment.

### Backend and verifier controls

Default backend is `codex`; `-b`/`--backend` selects `droid` or `agy`.
`--backend-bin` selects one executable, not a shell command. Custom executables
must support that backend adapter's flags and stream protocol. `--model` and
`--reasoning-effort` control the worker. An enabled verifier uses the worker
backend by default; `--verifier` selects another. For the same backend, omitted
verifier model, effort, and executable inherit worker values. For a different
backend, omitted values use its native defaults. Explicit `null` in verifier JSON
or empty `--verifier-model=`/`--verifier-bin=` selects native defaults. Verifier
objects merge by field; `verifier: null` clears the override. `--no-verify`
conflicts with explicit verifier controls.

`verifier.args` or repeated `--verifier-arg=VALUE` supply independent verifier
arguments; CLI values replace the config array. Arguments after `--` are worker
only. Both roles use the same sandbox policy. Unsupported structured policies,
unrecognized effort names, and conflicting native flags fail before either role
starts. Matcha accepts the common effort names `low`, `medium`, `high`, `xhigh`,
and `max`; the selected model may accept only a subset and reject a turn after
launch. No model name is assumed by Matcha.

| Backend | Structured sandbox | Reasoning flag | Explicit approval bypass |
| --- | --- | --- | --- |
| Codex | `workspace-write`, `danger-full-access`, `backend-default` | `-c model_reasoning_effort=...` | `--yolo` |
| Droid | `backend-default` only | `--reasoning-effort` | `--yolo` |
| Agy | `backend-default` only | `--effort` | `--yolo` |

`--sandbox` selects isolation without bypassing approvals; `--yolo` explicitly
bypasses them. They conflict in one layer, while a higher-layer choice replaces
an inherited choice. `--sandbox backend-default` (or JSON `sandbox: null`) resets
to native policy. `read-only` cannot support state-writing callbacks and is
rejected for every backend. Droid/Agy have no verified independent equivalent of
Codex's two structured modes. See [local CLI evidence](LOOP_SANDBOX_CAPABILITIES.md).

### Resume and logs

New loops save objective, resolved settings, cwd, and explicit environment
overrides. Resume does not reread config, prompt files, or env files. It inherits
the **current** ambient shell environment, then reapplies saved overrides and
PATH prefixes. Saved backend identities cannot change. Legacy snapshots keep
their historical shared model and argument behavior.

`matcha loop resume [ID|--last]` accepts `--objective`, repeatable `--env` and
`--env-file`, repeatable `--path-prepend`, `--backend-bin`, `--verifier-bin`,
`--model`, `--verifier-model`, `--reasoning-effort`,
`--verifier-reasoning-effort`, `--sandbox`, `--yolo`, and `--log-dir`.
`--config`, new prompt sources, backend changes, and new verifier args are
run-only. Resume validates a candidate before atomically saving it; accepted
overrides become the base for later resumes. A failed candidate leaves prior
state intact. `--sandbox backend-default` resets saved policy.

Logging is opt-in with config `log_dir` or `--log-dir`. Each initial run or resume
creates a fresh timestamped `.log`/`.jsonl` pair with loop and invocation IDs;
retries stay in that pair. The readable log records lifecycle, role/attempt,
assistant and tool activity, token summaries, and full stderr. The JSONL records
lifecycle context and base64-encoded raw backend stdout/stderr bytes, including
events hidden by terminal quiet/JSON output. Raw output can contain secrets.
Configured environment values are also saved in loop state; protect both files
accordingly. `turns.jsonl` in the loop store remains a compact state-history
summary, not the raw audit stream. Requested logging is mandatory: a write or
flush failure stops execution. A paused loop can resume with `--log-dir` pointing
to a working directory.
