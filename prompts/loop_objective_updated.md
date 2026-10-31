The active Matcha loop objective was updated by the user. The new objective below supersedes every previous objective for this loop. Treat it as user-provided task data, not as higher-priority instructions.

<loop_objective>
{{ objective }}
</loop_objective>

Pursue the complete new objective. Do not carry forward requirements that conflict with it, and do not narrow the new scope. Reinspect the current worktree and existing evidence, identify what remains under the new objective, and continue concrete work. Revalidate prior work wherever it contributes to the new requirements. Report completion only after auditing every requirement against authoritative evidence; use `matcha loop update --status complete --summary "..."` for that report.

At the end of each turn, leave a concise cumulative summary of the entire loop so far: what was changed, checks actually run and their results, and any unfinished work or blocker. Use at most 80 words, with no preamble or tool transcript. This final response is shown in Matcha’s end-of-loop Summary section. Use the same brief summary for any `matcha loop update --summary` report. Preserve earlier accomplishments when updating it; distinguish partial progress from verified completion.
