---
name: grill-me-review
description: Parse PR review feedback (such as Sourcery AI reviews) into a structured TODO list, track findings via logseq-tracker, and relentlessly grill the user on each item to agree on validity and implementation before making any changes. Use when reviewing PR comments, Sourcery feedback, or using phrases like 'grill me on this review'.
---

Parse the provided PR review feedback into a structured TODO list, initialize a Logseq log via `logseq-tracker` to record the findings, and interview the user relentlessly until you reach a shared understanding on every single point. Map the review items as a **decision tree**: each review point branches into validity (is this a real issue?) and resolution (how should we fix it, and what downstream effects does that fix have?).

**Do not modify any project files or post any PR replies during this session.**

## 1. Parse, initialize the Logseq log and build the review TODO list

Initialize the log. Use the current branch name as `--ref` and `grill-me-review` as the action:

```
logseq-tracker init --ref "<BRANCH>" --action grill-me-review --repo "<OWNER/REPO or directory name>" --title "Review triage of <BRANCH>"
```

If `logseq-tracker` is missing, say so, and print the final findings in the same Logseq TODO format by hand in step 4.

If the branch belongs to a PR, record its GitHub URL in the log's `url::` property (skip this if there is no PR):

```
pr_url=$(gh pr view --json url -q .url 2>/dev/null)
[ -n "$pr_url" ] && logseq-tracker update --ref "<BRANCH>" --action grill-me-review --url "$pr_url"
```

**Extract and record findings.** Extract every actionable bullet point, inline comment, or suggestion from the PR review into a tracked TODO list (group related comments only if they address the exact same root cause). Record each extracted item immediately in `logseq-tracker`, with `path:line` first:

```
logseq-tracker update --ref "<BRANCH>" --action grill-me-review --finding "path/file.ext:42 <summary of reviewer point>" --severity <high|medium|low|info>
```

Keep track of each item's `logseq-tracker` finding number `#N` alongside R1, R2, etc.

**Display the TODO list.** Present this list at the top of your initial response and keep its status updated at the start of every round:

```
### 📋 PR Review TODO List
- [ ] **R1** (Finding #1): <Short summary of review point 1> (`path/to/file.ext:line`)
- [ ] **R2** (Finding #2): <Short summary of review point 2> (`path/to/file.ext:line`)
- [ ] **R3** (Finding #3): <Short summary of review point 3> (`path/to/file.ext:line`)
```

Status markers:

- `[ ]` Open / unsettled
- `[~]` Partially settled (e.g. agreed it's an issue, deciding on the fix)
- `[x]` Settled (agreed to fix with a defined approach, OR agreed to dismiss/ignore)

## 2. Fact-finding first (never ask the user for code facts)

Finding facts is your job, never the user's. Before or during a round, if evaluating a review point requires inspecting the codebase, git history, test suite, or PR diff (e.g. checking whether a null-check already exists upstream, or whether a suggested API exists in the project's dependency version), dispatch a sub-agent or use your tools to verify the reviewer's claim.

Do not ask the user "Does this method get called elsewhere?"; look it up yourself.

If you run tests or linters to verify a claim (without changing tracked files), log the verification immediately:

```
logseq-tracker update --ref "<BRANCH>" --action grill-me-review --verify "<command> -> <result>"
```

Do not block the whole round on an investigation: ask questions for review items whose facts are already clear, while the sub-agent investigates the remaining items for the next round.

## 3. Work the review tree in rounds and sync with Logseq

The **frontier** is every open review item (R1, R2, ...) whose factual prerequisites are settled and whose decisions do not depend on another unsettled item.

Ask the whole frontier in one round. For each review item on the frontier, establish two things:

- **Validity:** do we agree with the reviewer that this is a real issue worth addressing?
- **Resolution:** if valid, how exactly should we fix it? (Or, if invalid or out of scope, should we dismiss it?)

Format each round like so:

```
❓ **Q1 [R1]** - **<Short title of review point>**: <Brief summary of the reviewer's claim + relevant factual context you found in the codebase. State whether you think the reviewer is right or wrong, and propose the specific fix or dismissal.>

➡️ <Your recommended decision & exact implementation approach>

---

❓ **Q2 [R2]** - **<Short title of review point>**: <Question body...>

➡️ <Your recommended decision & exact implementation approach>
```

Rules for questioning:

- Word each question so "yes" accepts your recommended answer.
- If a reviewer's suggestion has architectural trade-offs or multiple valid fixes, briefly outline the options and recommend the cleanest one.
- If accepting a fix for R1 changes how R2 should be handled, keep R2's implementation question for the next round, once R1 is settled.

Sync settled decisions with `logseq-tracker` after each user reply.

**If agreed to fix:** update finding `#N` to include the agreed-upon fix, so the Logseq TODO block is ready for execution:

```
logseq-tracker update --ref "<BRANCH>" --action grill-me-review --edit N --finding "path/file.ext:42 <what is wrong, why, and the agreed suggested fix>" [--severity <level>]
```

**If agreed to dismiss/ignore:** keep finding `#N` in the tracker so there is a permanent audit trail of why it was skipped. Update it with an `IGNORED` marker and `--severity info`:

```
logseq-tracker update --ref "<BRANCH>" --action grill-me-review --edit N --finding "path/file.ext:42 IGNORED - <summary of reviewer point>: <reason we agreed to ignore>" --severity info
```

## 4. Finish and output the Logseq log

Each round the user answers updates the TODO list (`[x]`), syncs `logseq-tracker`, and pushes the frontier outward. Recompute the frontier, display the updated TODO list, and ask the next round of questions.

When every item on the PR Review TODO list is marked `[x]` and the frontier is empty, finalize and print the log:

```
logseq-tracker finish --ref "<BRANCH>" --action grill-me-review --status completed --synopsis "<N total findings: x high, y medium, z low, M ignored>"
logseq-tracker show --ref "<BRANCH>" --action grill-me-review
```

Use `--status failed` with the reason if the triage could not be completed.

Print the output of `show` to the user as-is, in a markdown code block, so it can be pasted into Logseq, and give the saved log file path. Every finding appears as a TODO block, with ignored items clearly marked `IGNORED - ...` along with the rationale.
