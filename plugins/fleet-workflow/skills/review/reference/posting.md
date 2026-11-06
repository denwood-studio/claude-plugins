# Step 5 part A — posting mechanics

The review reaches GitHub only through `${CLAUDE_PLUGIN_ROOT}/scripts/review-post.sh`, and only
under a bot identity the user configured. The bot is **the login configured in `review.botLogin`**,
authenticated by the token file named in `review.tokenFile`; both come from the user layer, and the
repo layer cannot set either. Posting also needs `review.postToGitHub` to be `true`. Without all
three, the script writes nothing and the review comes back in the session.

**Never read the token file, never print the token, never pass it as an argument, and never call
`gh pr review` yourself.** The script does the only read and hands the token to a single `gh` call
through its environment. Posting any other way risks landing the review as the human.

**Re-check `HEAD` before you post**, against the SHA pinned in Step 1.4. If the author pushed mid-review, **do not restart**. Confirm the pin is still an ancestor (`merge-base --is-ancestor <pinned-sha> HEAD`; if not they rebased, so diff `origin/main...HEAD`), diff forward, fold the new commits in, and post once against the current SHA.

## Three tokens are load-bearing and fail *green* if you change them

`review-scope.sh` parses your posted body for the first two, and a metrics collector may read the
third from the tool output. Nothing errors when one is wrong — the next review just scopes against
the wrong range. Emit all three verbatim; the names are frozen wire formats, not claims about which
agent reviewed:

1. A line beginning `**Reviewed at:**` **within the first 10 lines of the body**, at the start of
   its line.
2. `<!-- DAR-STATE sha=<full-40-char-sha> -->` as the **last body line**.
3. A line starting `DAR_RESULT:` **printed by `review-post.sh`** in step 4 below, read from that
   command's tool output. The copy you put in your summary is human-facing.

## The procedure

1. Resolve `PR=<number>` and `REPO=<owner>/<repo>` (from Step 1, or `gh pr view --json number,headRepositoryOwner,headRepository`).
2. Compose the review. Prefix a fixed three-line header:

   ```markdown
   🤖 **Automated review**

   **Verdict:** <VERDICT>
   **Reviewed at:** `<short-sha>`
   ```

   then a blank line, the review sections, and as the **last body line**:

   ```markdown
   <!-- DAR-STATE sha=<full-40-char-sha> -->
   ```

   **The trailer is load-bearing** — `review-scope.sh` reads it to scope your next pass (last occurrence wins, so quoting an earlier one is safe), and it never renders. `**Reviewed at:**` stays as the human-facing line and the parse fallback for older reviews.
3. Map the verdict: **APPROVE** / **APPROVE WITH SUGGESTIONS** → `--approve`; **REQUEST CHANGES** / **BLOCK** → `--request-changes`. (GitHub has no BLOCK event; the distinction survives only in the `**Verdict:**` line.)
4. Write the body and submit it in **one Bash call**. Shell variables do not survive between Bash
   calls, and `Write` is not available to you, so the file is created by a heredoc in the same call
   that runs the script, at a fixed path under the worktree's git dir (no `mktemp`, nothing outside
   the checkout). Substitute the literal values for `<WORKTREE>`, `<PR>` and `<owner>/<repo>`, and
   paste the full body between the markers; the quoted marker keeps the shell from expanding
   anything inside it:

   ```sh
   BODY="$(git -C <WORKTREE> rev-parse --absolute-git-dir)/review-<PR>.md"
   cat > "$BODY" <<'REVIEW_BODY_END'
   <the full review body, header first, DAR-STATE trailer last>
   REVIEW_BODY_END
   ${CLAUDE_PLUGIN_ROOT}/scripts/review-post.sh <WORKTREE> <PR> <owner>/<repo> <--approve|--request-changes> "$BODY"
   ```

   It prints exactly one line and always exits 0:

   | Line | Meaning |
   | --- | --- |
   | `DAR_RESULT: posted (<event>)` | The review is on the PR under the configured bot login. |
   | `DAR_RESULT: skipped (postToGitHub false)` | Posting is off. Returned in the session, no GitHub write. |
   | `DAR_RESULT: skipped (no bot login)` | No `review.botLogin`. Returned in the session, no GitHub write. |
   | `DAR_RESULT: skipped (no token)` | No usable `review.tokenFile`. Returned in the session, no GitHub write. |
   | `DAR_RESULT: skipped (empty review body)` | The body file was empty. Returned in the session, no GitHub write. |
   | `DAR_RESULT: failed (gh pr review error)` | `gh` refused the review. Nothing was posted. |

5. Report that exact `DAR_RESULT:` line in your summary, verbatim — never claim "posted" unless the
   script printed it. Any `skipped` line means **returned in the session, no GitHub write**. Still
   return your full verdict text: posting is *in addition to* returning.

Notes:

- The bot must be a **different identity** from the PR's author: GitHub does not let an account approve or request changes on its own PR. Never have the bot open PRs.
- Each run posts a fresh review; GitHub keeps the latest per reviewer, so a later **APPROVE** supersedes an earlier **REQUEST CHANGES**.
- If the script prints `failed`, don't retry blindly — report it so the user can fix the account or token.
