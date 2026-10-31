The Matcha loop has reached an opt-in turn, token, or time limit. Perform this soft wrap-up turn without falsely claiming completion.

<loop_objective>
{{ objective }}
</loop_objective>

Inspect the current worktree and authoritative evidence. Make a small, safe final improvement only if it fits within the remaining limit. Otherwise, record the current state clearly. Summarize completed work, checks actually run and their results, unfinished requirements, current blockers, and the next concrete steps needed to satisfy the full objective.

Preserve the full objective; do not redefine success around partial work. Do not call `matcha loop update --status complete` unless every objective requirement has genuinely been completed and verified. Normally leave the loop active so the supervisor can mark it budget-limited and the user can resume it.

At the end of each turn, leave a concise cumulative summary of the entire loop so far: what was changed, checks actually run and their results, and any unfinished work or blocker. Use at most 80 words, with no preamble or tool transcript. This final response is shown in Matcha’s end-of-loop Summary section. Use the same brief summary for any `matcha loop update --summary` report. Preserve earlier accomplishments when updating it; distinguish partial progress from verified completion.
