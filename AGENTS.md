# Agent Notes for `matcha`

## What this project is

`matcha` is a Zig CLI that turns structured JSON plans and UML diagrams into self-contained HTML
artifacts. It is also a Svelte/Vite client build that produces the embedded JavaScript bundles the
CLI injects into those HTML files.

## Repository layout

| Path                                       | Purpose                                                                                                       |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------- |
| `build.zig`                                | Zig build configuration and executable build entrypoints.                                                        |
| `src/main.zig`                             | Zig CLI entrypoint.                                                                                           |
| `src/cli.zig`                              | `runArgs` and command dispatch for `help`, `version`, `plan`, and `map` commands.                               |
| `src/render_html.zig`                       | HTML render path for plan and map outputs.                                                                     |
| `src/render_markdown.zig`                   | Markdown renderer used by `plan read`.                                                                          |
| `src/plan_read.zig`                        | Input parsing and extraction for `plan read`.                                                                   |
| `client/`                                  | Svelte/Vite client. Builds `plan.js`/`plan.css` and `map.js`/`map.css`.                                       |
| `client/src/main.ts`                       | Plan client entrypoint; mounts `App.svelte` into `dist/plan.html`.                                            |
| `client/src/map.ts`                        | Map client entrypoint; mounts `MapApp.svelte` into `dist/map.html`.                                           |
| `plan.js`, `plan.css`, `map.js`, `map.css` | Built client artifacts committed at the repo root for the CLI to read.                                        |
| `plan.schema.json`, `uml.schema.json`      | Canonical JSON schemas for the two input formats.                                                             |
| `llm_output_format.txt`                    | Prompt output format for plans.                                                                               |
| `llm_uml_output_format.txt`                | Prompt output format for UML diagrams.                                                                        |
| `sample_plan.json`, `sample_map.json`      | Example inputs used by the CLI and tests.                                                                     |
| `themes/`                                  | Color-theme CSS files (e.g. `catppuccin-latte.css`).                                                          |
| `dist/`                                    | Output directory for generated HTML and compiled binary.                                                      |

## Commands

Use `task` (go-task) for day-to-day work:

```sh
task fmt      # zig fmt
task lint     # zig fmt --check
task check    # zig build
task test     # zig build test
task run -- help
task run-plan # writes dist/plan.html from sample_plan.json
task run-map  # writes dist/map.html from sample_map.json
task build    # compile CLI to dist/matcha
task build-client  # npm run build in client/
task install  # install dist/matcha to ~/.local/bin
```

## How data flows

1. The CLI reads a `sample_plan.json` or `sample_map.json` file.
2. It builds a standalone HTML page by inlining:
   - a theme CSS,
   - the matching `plan.css`/`map.css`,
   - the input JSON,
   - the matching `plan.js`/`map.js` bundle.
3. The Svelte bundle reads the inlined JSON from a `<script type="application/json">` tag or
   `window.PLAN_DATA` / `window.MAP_DATA` and renders the UI.

## Important conventions

- Runtime is **Zig**, not Deno. Use `zig` for CLI work and `npm` for the client build.
- The CLI expects `sample_plan.json` and `sample_map.json` in the working directory when running
  `plan`/`map`.
- `zig fmt` / `zig fmt --check` apply to CLI sources; `client/` and bundled assets are handled by `npm`.
- The Svelte client is built in IIFE format so it can run inline in generated HTML.
- Keep the UML format semantic. `JOINTJS_NOTES.md` records JointJS implementation notes; the JSON
  schema stays independent of any diagram library.

## Where to start when changing things

- New CLI command or output behavior: `src/cli.zig`.
- Plan data shape: `plan.schema.json` + `llm_output_format.txt`.
- UML data shape: `uml.schema.json` + `llm_uml_output_format.txt`.
- Plan UI: `client/src/App.svelte` and `client/src/components/`.
- Map UI: `client/src/MapApp.svelte` and `client/src/map.ts`.
- Client build output consumed by CLI: `client/package.json` copies `dist/plan.js`, `dist/plan.css`,
  `dist/map.js`, and `dist/map.css` to the repo root.

# Rules

You are not allowed to edit the README.md unless you get explicit approval from the user.
