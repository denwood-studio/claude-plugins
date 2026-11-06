# Step 2 — tiers

**Tiers change what an unmet criterion costs, not whether you report it.** A criterion tagged `[should]` is a wanted outcome the filer marked as not worth holding the merge for: report it unmet in the checklist and as a finding, exactly as you would any other, but **it cannot on its own take the verdict past APPROVE WITH SUGGESTIONS**. `[must]`, and any criterion with no tag at all, behaves as it always has — untagged means `[must]`, and most of the backlog is untagged, so never read a bare criterion as the soft kind. Combine tiers the same way: a PR whose only failures are `[should]`s approves with suggestions; one `[must]` unmet is a fail regardless of how many `[should]`s passed. You never re-tier a criterion to fit the verdict you want — a `[should]` you think should have blocked is a note to the human, and a `[must]` you think is unreasonable is still a fail.

**An undelivered outcome is not tierable.** The outcome statement carries no tag and takes none: a diff that does not deliver it fails, whatever the criteria say and however clean the code is.

**Where it goes in the review.** An unmet `[should]` takes `warn` in the Success Criteria Checklist and its finding goes under **Significant Concerns** — never Critical Issues, whose "missing requirements" means an unmet `[must]`, and never Suggestions, which is capped at 3 and would let a reported criterion fall off the list silently. Significant Concerns is unbudgeted, so it always survives. The cap is on the *verdict*, not on saying it: a review whose only failures are `[should]`s still writes them up in full and closes at APPROVE WITH SUGGESTIONS.

A deviation from `PLAN` is reported under `### Judgment calls`, never as a fail — a plan is a
hypothesis the build may have improved on.
