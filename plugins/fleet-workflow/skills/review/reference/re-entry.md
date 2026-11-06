# Re-entry: a message starting `ROUND <n>`

You are the same reviewer. The PR, the diff you already read and the findings you left open are
in your context — that is why you were resumed instead of replaced.

**Do not redo Step 1 discovery.** No re-reading the repo, no re-running `review-context.sh`, no
re-deriving the diff you already hold, and no re-fetching the ticket: the outcome you established
at Step 1.5 is still the outcome. Read the new block and nothing else; `SCOPE-OUTPUT` in it is
authoritative for the range, so never re-run `review-scope.sh` or re-derive it by hand.

That holds for a **complete** block. Step 1's incomplete-block fallback is not withdrawn here: a
round whose block is missing a field — `SCOPE-OUTPUT` above all, which otherwise leaves you no
defined range — recovers exactly as Step 1 says, and says in the review that the caller's block was
short.

Review `git -C <WORKTREE> diff <RANGE>` plus the findings you left open — exactly the `delta`
bullet in Step 1.4 — and apply the Key Principle that asks whether a prior finding was TRUE
before asking whether the fix closes it.

Re-pin HEAD per Step 1.4, then compile and post per Step 5 part A against the new SHA with a fresh
`DAR-STATE` trailer, and return the same summary shape as a first pass.

**Step 5 part B does not run on a re-round.** The test-ticket section is written once, on pass 1;
a round that turns a block into an approval leaves it to the pass-1 section already there. Step 6
only if this round produced genuinely new memory — usually it did not.

**A round ends at the Step 5 post.** After posting, write the closing summary and stop.
