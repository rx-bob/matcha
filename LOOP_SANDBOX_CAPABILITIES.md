# Loop adapter capability evidence

Inspected local CLI help on 2026-10-31, without running agent turns:
`codex-cli 0.161.0` (`codex exec --help`), `droid 1.1.0`
(`droid exec --help`), and `agy 1.4.12` (`agy --help`).
These are adapter claims for those CLIs, not a promise that every model accepts
every effort value. [Factory settings](https://docs.factory.com/droid-cli/settings)
and [Agy effort documentation](https://antigravity.google/docs/cli/commands/effort/)
explicitly say allowed efforts depend on the selected model. OpenAI's
[model reference](https://developers.openai.com/api/docs/models/gpt-6.1-sol)
likewise gives values for a specific model. Matcha rejects unsupported structured
policies and unrecognized effort names before launching either role.

| Backend | Help evidence | Matcha adapter behavior |
| --- | --- | --- |
| Codex | `-s/--sandbox` lists `read-only`, `workspace-write`, `danger-full-access`; `-c/--config` accepts config key/value; explicit bypass flag exists. | Supports `workspace-write`, `danger-full-access`, and `backend-default`. Emits `--sandbox` before `resume`; adds loop state directory with `--add-dir` for `workspace-write`. Reasoning emits `-c model_reasoning_effort="..."`. |
| Droid | `--auto` selects autonomy level; `--skip-permissions-unsafe` bypasses checks; `-r/--reasoning-effort` exists. | No verified independent structured sandbox choice. Supports `backend-default`; reasoning emits `--reasoning-effort`. |
| Agy | `--mode`, `--sandbox`, and explicit bypass flags exist; `--effort` lists `low`, `medium`, `high`, `xhigh`, `max`. | No verified equivalent of Codex's independent structured sandbox choice. Supports `backend-default`; reasoning emits `--effort`. |

`read-only` is rejected even for Codex because loop update/verify callbacks must
write state. `backend-default` injects no structured sandbox or approval flags;
the backend's native settings must allow callbacks. `--sandbox` never implies
approval bypass. `--yolo` is explicit and maps to each adapter's native bypass
flag. Matcha validates `low`, `medium`, `high`, `xhigh`, and `max` as effort names;
Droid help does not enumerate values, while Factory documents a broader set of
model-dependent values. Matcha intentionally accepts only the five common names
for its structured interface. The selected model may reject an accepted name
after launch; checking every model's current catalog would require vendor
discovery and cannot be guaranteed for custom executables. Custom executable
compatibility depends on its own version.
