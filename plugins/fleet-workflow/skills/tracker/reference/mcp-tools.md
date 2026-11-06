# Linear: MCP tool reference

`<ID>` is an issue identifier such as `ENG-123`; identifiers, team names or keys, project names and `"me"` are accepted wherever an id is.

## Reading

```
get_issue(id: "<ID>")
```
Full issue detail: description, status, assignee, gitBranchName, team. `fields: [...]` selects what comes back and overrides the defaults, so name every field you need (`statusType` is one).

```
list_comments(issueId: "<ID>")
```
Full comment history: session notes and decisions live here. The param is `issueId`, **not** `issue`: passing `issue` fails validation. The same goes for `save_comment`. These take exactly one parent: `issueId` | `projectId` | `initiativeId` | `documentId` | `milestoneId` | `statusUpdateId`.

```
list_issues(team: <team>, project: <project>, state: <state>, priority: <1|2|3|4>, assignee: <name|"me">, label: <label>, parentId: "<ID>", query: <text>)
```
Any combination of filters; results are paginated, so follow `cursor` while `hasNextPage` is true. **Descriptions come back truncated at 500 bytes**, so headings and acceptance criteria usually sit past the cut: use `get_issue` for anything that reads a body.

```
list_issue_statuses(team: <team>)
list_issue_labels(team: <team>)
```
The team's own states and labels. Always pass `team`.

```
get_project(query: <project>, includeMilestones: true)
get_status_updates(type: "project", project: <project>, limit: 2)
list_documents(projectId: <project>, limit: 50)
get_document(id: <slug_or_id>)
```
`list_documents` filters on `projectId` (camelCase), not `project` like every other tool; the wrong key silently returns nothing.

## Writing

```
save_issue(id: "<ID>", state: <state type|name|id>, assignee: "me")
```
Update state and/or assignee.

```
save_issue(title: <title>, description: <markdown>, team: <team>, project: <project>, priority: <1-4>, state: <state>, labels: [...])
```
Create an issue (omit `id`). `team` is required. Pass `project` only when there is one.

```
save_issue(title: <title>, parentId: "<ID>", team: <team>, ...)
```
Create a child issue: the same call plus `parentId`. Read the parent first and inherit its project and priority rather than guessing.

```
save_issue(id: "<ID>", labels: [...], addLabels: [...], removeLabels: [...], priority: <1-4>)
```
`labels` replaces the whole set; `addLabels` and `removeLabels` change one label at a time.

```
save_issue(id: "<ID>", blocks: ["<ID>"], blockedBy: [...], relatedTo: [...])
save_issue(id: "<ID>", removeBlocks: [...], removeBlockedBy: [...], removeRelatedTo: [...])
```
Relations are **append-only**: use the matching `remove*` field to drop one. Write `blocks`/`blockedBy` only when one ticket genuinely cannot start before the other. "These two touch the same code" is a scheduling constraint, not a dependency.

```
save_comment(issueId: "<ID>", body: <markdown>)
save_comment(parentId: <comment_id>, body: <markdown>)
```
Append a note to an issue; reply in a thread with `parentId`.

```
save_status_update(type: "project", project: <project>, body: <markdown>, health: "onTrack"|"atRisk"|"offTrack")
```
Post a project status update.

```
save_project(id: <project>, description: <markdown>)
```
Updates the project description. Read the current text with `get_project` first and write the whole of it back with your edit: a partial `description` replaces everything.

```
save_issue(id: "<ID>", patch: [{op: "append", text: <markdown>}])
```
Edit an issue description without a read-modify-write. The ops are `replace | insert_before | insert_after | prepend | append | replace_range`. Prefer this to re-sending `description` whenever you are adding to an existing body: a rewrite can drop or reflow what someone else wrote.

Linear normalises the markdown it stores, so a section does not read back byte-identical to what was sent. Any character that could open inline markup is backslash-escaped in running text (`[x]` stores as `\[x\]`), and a `## heading` gains a blank line after it. **That breaks exact-match `patch` anchors silently:** an anchor built from what you wrote may not match what is stored, and if an unescaped copy of that text sits elsewhere in the document (inside backticks, say) the patch edits *there*, with no error. Anchor on something the serialiser cannot rewrite: an identifier, a slug, a date.

```
save_document(project: <project>, title: <title>, content: <markdown>)
save_document(id: <doc_id>, content: <markdown>)
save_document(id: <doc_id>, patch: [{op, ...}])
```
Create (exactly one parent: `project`, `issue`, `initiative`, `cycle` or `team`) or update. **When updating, pass only `id` and `content` (or `patch`):** passing a parent on update silently moves the document there. Find the `id` with `list_documents` first.

Pass multi-line text with real newlines, never `\n` escape sequences: they render as literal backslash-n.
