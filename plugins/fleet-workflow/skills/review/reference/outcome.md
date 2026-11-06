# Step 1.5 — establishing the outcome

The outcome statement is the thing this review checks the diff against, so where it comes from is
part of the contract, not a convenience. **You fetch it. No caller hands it to you.**

## The three-level precedence

| Level | When it applies | What you do |
| --- | --- | --- |
| 1 | A real `TICKET` id in the spawn block and a tracker get-issue tool connected | Call it (for example `mcp__linear__get_issue(<id>)`; if its schema is deferred, load it first) and read its `## Outcome` section plus its acceptance criteria. The normal path, and it works identically whether `PLAN` carries a plan or `none`. |
| 2 | The fetch failed or no tracker is connected, and the `PLAN:` block carries an `Outcome:` header line | Use that line, and **say in the review that the outcome came from the plan, not the ticket**. |
| 3 | `TICKET: none` (an integration PR, a ticketless change) and no plan header | **Say so plainly at the top of the review.** Check the diff against `ACCEPTANCE-CRITERIA` and `CONSTRAINTS` where the block carries them, and on its own merits otherwise. Never manufacture an outcome. |

Fetching the ticket is a **read**.

## No tracker

With no tracker tool connected, or `TICKET: none`, level 1 is skipped rather than failed. Say
`Tracker: skipped, no tracker` in one line at the top of the review and in your return block, then
run level 2 or 3 as the table says. Nothing else about the review changes.

## Never the PR description

The PR description is the author's account of their own change. Checking the change against it asks
whether the author described what they did, which is never the question. **It is not a source of
the outcome at any level, and not a fallback when levels 1–3 all come up short** — level 3 already
says what to do when there is no outcome to be had.

Read the PR description for orientation if you like. Never cite it as the thing the diff was
supposed to deliver.

## A failed fetch is reported, never absorbed

Dropping from level 1 to level 2 or 3 after a failed fetch changes what this review is worth, so it is visible in two
places: one line at the top of the posted review naming the level you ran at, and one line in your
returned summary. A review that quietly reviewed against a weaker source reads exactly like one
that did not.
