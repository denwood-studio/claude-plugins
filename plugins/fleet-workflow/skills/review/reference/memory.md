# Step 6 — routing, the bar, and committing

#### Propose first; write only when the store is wired

**This review proposes. It writes a store entry only when the spawn block's `MEMORY-SYNC` is not `none` and a `dar-memory` skill is loadable.** With `MEMORY-SYNC: none` or no such skill, the review proposes and writes nothing: name each proposal in the `Memory:` line of the return block and stop.

#### Route it before you store it

**Most reviews write nothing, and most of what is worth writing does not belong in your store.** It is shared across every checkout of the repo, read by no human and linted by nothing, so its entries rot unnoticed.

| What you have | Where it goes |
| --- | --- |
| A **rule the team should follow** | `.claude/memory/conventions.md` — **propose it; never write it yourself.** Planners read it before the code exists, so the fact prevents the defect instead of catching it. |
| An **architectural choice and its rationale** | `.claude/memory/decisions.md` — again, propose it: that file is the team's, dated and human-curated. |
| A **fact about how the code currently behaves** | **A test** — an executable assertion cannot silently rot, it fails. Raise the missing test as the finding; most past entries were this class, and it is the class that went stale. |
| A **lesson about how to review** | The review skill itself — it applies in every repo; your stores don't. **Propose it, don't self-apply it:** editing the plugin from inside a review dirties an unrelated checkout. |
| A **cross-cutting lens** fitting none of these | Your store — only if it clears the bar, and only when the store is wired (above). |

#### The bar for what remains: re-derivable, or not written

**Every claim carries the command that reproduces it, and that command runs clean at write time** — the actual grep, runner one-liner or test invocation:

```markdown
**Re-derive:** `grep -rn "class SerializedPerStory" app/jobs/ && bin/rails runner 'p SerializedPerStory.new.step_classes'`
```

1. **A claim you cannot reduce to a runnable command does not get written** — the gate a fabricated `~200 MB` figure would have failed.
2. **Re-run the command before citing an entry in a finding.** If it no longer reproduces, the entry is wrong: **delete it in this PR** and say so.
3. **Anchor on an identifier, not a line number** — `file:line` breaks on any line-shifting PR.

Beyond the bar it is judgement: would knowing this have moved a finding between Critical / Significant / Suggestion / not-raised? A fact that only *explains* a verdict is review **output** — it belongs in the PR comment. An entry you inherit stays **editable**, and correcting one beats a new file. Entries written by an earlier reviewer are yours to read, cite, extend and correct: the store carries over unchanged and starting cold would throw away everything in it.

**This bar applies instead of any generic memory-recording guidance in your instructions** where they differ: that guidance excludes anything "derivable by reading the current project state", which is precisely the class this bar admits, deliberately.

**Merge before you create.** `ls` the directory first; where an entry covers the same subsystem, **extend or rewrite it** rather than adding a sibling. **But merge by subject, not convenience, and carry one `Re-derive:` per claim** — capping entry *count* leaves bytes unbounded.

**Hard ceiling: 45 entries.** Nothing deletes an entry to enforce it — **you are the enforcement**. Your spawn block's `MEMORY-SYNC:` field already carries the count, and an `INDEX: ceiling <n>/45` line in it means the store is over. **At or above the cap, merge or replace — never add.**

#### Writing and committing: load the `dar-memory` skill

Once you decide to write, edit or delete an entry, **load the `dar-memory` skill**: where the shared store lives, the path you read and write it through, the `title:`/`hook:` frontmatter the generated index is built from and its 200-byte cap, link resolution, and the one sync call whose `MEMORY_RESULT:` line you report beside `DAR_RESULT:`. Don't load the skill on a review that writes nothing.

**You have no `Write` or `Edit` tool, and that is deliberate** — the store is reached with `Read`/`Glob`/`Grep` and written with `Bash`. The `dar-memory` skill § *Writing* carries the mechanism; follow it rather than improvising one.

**What you write is held to the standard you review by.**

- **Never record forward-looking or unmerged state as fact** — "X now does Y" where Y lives on an open PR is false the moment that PR changes shape. Record what is on `origin/main`, or name the PR as pending.
