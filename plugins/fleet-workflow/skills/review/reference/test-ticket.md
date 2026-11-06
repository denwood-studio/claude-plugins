# Step 5 part B — handing testing context forward

On a pass-1 verdict of `APPROVE` or `APPROVE WITH SUGGESTIONS`, append your testing
recommendations to the implementation's test ticket. **This is part of approving, not a step after
it.** You have just read the diff closely; discarding what you worked out and making whoever writes
the tests re-derive it is the waste this step exists to stop.

## When it runs, and when it does not

| Situation | Runs? |
| --- | --- |
| Pass 1, verdict `APPROVE` or `APPROVE WITH SUGGESTIONS` | **yes** |
| Pass 1, verdict `BLOCK` or `REQUEST CHANGES` | no — there is nothing to approve yet |
| A re-round (`ROUND <n>`) that approves | no — pass 1 already wrote the section, and a second one would duplicate it |
| `MODE: plan` | no |
| The implementation ticket's title starts `Tests: ` | no — there is no nested test ticket; the change is itself the tests and pass 1 reviewed them |
| `TICKET: none` | no — there is no implementation ticket to hang a test ticket from |
| No tracker connected, or its write tools are unavailable | no — report `Test ticket: skipped, no tracker` in the return block and carry on; the review is still complete |

## The procedure

Use the connected tracker's tools; the names below are the operations, not tool names. In Linear they
are `get_issue`, `list_issues` (with `parentId`), `save_issue` and `save_comment`.

1. **Read the implementation ticket** (`<impl-id>`): its title, team, project and priority.
2. **Look for an existing test ticket**: list the children of `<impl-id>` and match **any child whose
   title starts with `Tests: `** — not an exact title match, because a renamed implementation ticket
   would otherwise get a second test ticket.
3. **Found — append.** Append your section to the end of that ticket's description with the tracker's
   append operation (in Linear, `save_issue` with a `patch` of `{op: "append", text: …}`). **Never read
   the description and write it back**, and never edit, reorder or reflow anything above your section.
4. **None found — create it.** Create a ticket titled `Tests: <impl title>` with `<impl-id>` as its
   parent and the parent's team, project and priority inherited. Add **no labels**. Its description is
   `Tests for <impl-id> — <impl title>`, a blank line, then your section. Then add a **back-link
   comment** on the new ticket naming `<impl-id>` and the PR, so it can be traced to the change. Never
   edit the implementation ticket's description.
5. Pass descriptions and comments with literal newlines, never `\n` escape sequences.

## What goes in the section

The heading is exactly

```md
## Reviewer
```

- The cases you wanted covered while you had the diff in front of you.
- The edge conditions you reasoned about, including the ones that turned out fine.
- Anything you chose not to block on but want verified.

Write it as ticket prose, not as a message to your caller. **Append only**, and **attributable**:
everything under your heading is yours, everything above it is somebody else's and stays
byte-for-byte as you found it.

## Nothing to add is still written down

With nothing to add you **still write the section**, containing an explicit *"no additional
recommendations"*. "The step ran and found nothing" must be distinguishable from "the step never
ran". **An approval that skipped the section is not a valid pass-1 approval.**

## A denied or impossible write is reported

If the tracker write is denied or fails, say so in your returned summary on its own line
(`Test ticket: failed: <why>`). With no tracker at all, the line is `Test ticket: skipped, no
tracker`. Never drop it silently, and never claim the section was written when it was not.
