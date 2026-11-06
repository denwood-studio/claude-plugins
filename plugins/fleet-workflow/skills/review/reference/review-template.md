# Step 4 — the review template and its budget

Structure your output as:

---

## Review

### Outcome

One short paragraph: the outcome statement you checked against, the level you got it from
(`outcome.md`), and whether the diff delivers it. On "no" — **name the part that is unmet**. On
`TICKET: none` say plainly that there was no outcome to check against.

### Success Criteria Checklist

only if the spawn block's `ACCEPTANCE-CRITERIA` carried criteria

- [status] criterion description — notes

### Critical Issues

Must fix before merge — an undelivered outcome, bugs, missing requirements (an unmet `[must]`; an unmet `[should]` is a Significant Concern), security issues

### Significant Concerns

Should fix — code smells, pattern violations, missing coverage, architecture issues

### Suggestions

Nice to fix — improvements, minor smells, style

### Judgment calls

Everything you report but cannot decide — a `PLAN` deviation, an unmet `[should]`, a `[should]` you think should have blocked, a mechanism-shaped criterion, a finding whose fix is a scope or product choice. Write `none` when empty; the caller reads this section mechanically. One line per call.

### What's Good

Acknowledge what was done well — be specific

### Verdict

One of:

- **BLOCK** — Critical issues must be addressed. An undelivered outcome lands here.
- **REQUEST CHANGES** — Significant concerns should be addressed. An unmet `[should]` is the one Significant Concern that must not reach this verdict on its own: it caps at APPROVE WITH SUGGESTIONS
- **APPROVE WITH SUGGESTIONS** — Good to merge, suggestions are optional
- **APPROVE** — Clean, solid work

---

For each issue: the file and line/area, the problem, why it matters, and a concrete fix.

Put the pinned SHA in the `**Reviewed at:**` slot and in the Step 5 `DAR-STATE` trailer.

#### Budget

**A longer review is not a better one, and length is what you spend.** Hold to these:

- **The Outcome section: one paragraph.** It is the headline, not the essay.
- **Critical Issues and Significant Concerns are unbudgeted.** Say everything the author needs to act on; never trim a real finding to a length target.
- **Suggestions: at most 3**, a short paragraph each — those most likely to change the code.
- **What's Good: at most 3 bullets, one line each.** No sub-bullets, evidence blocks or quoted diffs.
- **Success Criteria Checklist: one line per criterion** — status, criterion, one clause of evidence.
- **Report verification as a result, not a transcript** — the outcome is the finding; the commands you ran and the fixtures you built are not.
- **Never restate the diff** — quote only the lines a finding turns on.
