# Step 3 — the four craft lenses

Four lenses, every review, every changed file. None of them is a separate pass and none is
optional; **security is read on every review**, including the ones where nothing about the ticket
sounds like security.

## Security

- **Unsafe parameters** — a value reaching a query, a command, a path, a redirect or a deserializer
  without passing through the framework's permitting or escaping layer. In Rails: strong parameters
  bypassed, a raw param interpolated into `where`, `find_by_sql`, `order`, `pluck` or a `LIKE`, mass
  assignment re-opened. In JS: a value interpolated into SQL, a shell string, `dangerouslySetInnerHTML`
  or an `href`.
- **Injection surfaces** — SQL, shell, template, header, log. Name the sink and the reachable input.
- **Authz gaps** — an action, scope or serializer that trusts an id from the request; a record looked
  up globally where it should be scoped to the current user or account; a policy check missing on a
  sibling of a checked action.
- **Secrets** — a credential, token or key added to the repo, printed, logged, passed as a CLI
  argument, or committed to a fixture.
- **Unsafe defaults** — a permissive CORS entry, a disabled verification, a wildcard, a
  fail-open branch, a `rescue` that swallows an authorization error.

A security finding is Critical unless you can show the sink is unreachable. Match verification cost
to severity per `key-principles.md`: anything raised Critical or Significant is executed, not
reasoned about.

## Rails

Idiom and the conventions the framework expects. N+1 queries and missing `includes`; queries or
business logic in a controller or a view; a callback doing work that belongs in a service or a job;
validations bypassed by `update_column`/`insert_all`; a migration that is not reversible, locks a
large table, or adds a `NOT NULL` column with a default on a big table without a backfill; missing
index on a new foreign key or a column the new query filters on; `default_scope`; fat models where
a plain object would do; `rescue` without a class; time zone handling via `Time.now`.

## React

Component and state design, hooks, rendering behaviour. State duplicated from props or derivable on
render; an effect used where a computed value or an event handler would do; a missing or
over-broad dependency array; a key taken from the array index on a reorderable list; a new context
or provider where a prop would do; a component that fetches and renders and decides layout; work in
render that should be memoised, or memoisation that guards nothing; `dangerouslySetInnerHTML`;
uncontrolled-to-controlled input flips; accessibility — label, role, focus order, keyboard reach.

## Clean code

**Code smells:** deep nesting (>3 levels); duplicated logic, even subtle; magic numbers or strings;
vague, misleading or locally-inconsistent naming; god objects; **over-abstraction** — an interface,
factory, base class, options hash or indirection layer with one caller, a wrapper that only
forwards, a generalisation nothing asked for; complexity that could be less; dead code being
*added* (unreachable branches, unused exports); catch-all error handling. And:

- **Extended cyclomatic complexity over 10 in a function the diff *adds*** — counted as 1,
  plus one per conditional branch, dispatch arm (each arm, not the dispatch keyword), short-circuiting
  boolean, loop and enterable handler; a bare `else`, null-safe navigation and a bare `??` default
  don't count. Show the count and the points counted.
  **Suggestion severity**, hardening only when it compounds a correctness finding. Never raise it
  against a function the diff merely edits, moves or doesn't touch.

**Comments** are governed by the one-directional rule in the skill's Step 3. The only remedy you
ever propose is deletion.

## The rest of every changed file

**Pattern consistency:** an established pattern for this work, or a newly-invented one — show where
the existing one lives; naming and file/folder placement against the existing structure.

**Architecture:** separation of concerns; unjustified new dependencies; business logic in the wrong
layer; circular dependencies or tight coupling; changes that make future refactoring harder.

**UI:** design-system, shared or utility components that could have been reused; a new component
duplicating one (name it and its path); inline styles where a styling system is in use.

**Pattern adherence:** Step 1.2's `PATTERNS:` hits are the cheap first cut — work from them, not the
file. But the criterion is any entry whose **tags** match this PR's feature area, and the derived
terms are paths, not tags: so where the commit message or PR description claims
`Pattern: follows <name>`, verify it against `patterns.md` **directly** whether or not the terms hit
— `grep -n '<name>' <WORKTREE>/.claude/memory/patterns.md`, `sed` its window, then check the code
against the referenced `file:line`. On `Pattern: establishes new`, check the pattern was captured in
`patterns.md`.

**Tests:** existing tests updated where behaviour changed; assertions on behaviour, not the
framework; edge cases. A PR with no new test file is not a failure on that fact — see the skill's
Step 3 § Tests for where a wanted test goes instead.

## Prose

A README, ADR, runbook, agent or skill definition is reviewed like any other artefact,
against the outcome. On a docs ticket the prose **is** the deliverable, so the lenses that apply are
accuracy against the code it describes, internal contradiction, and whether a reader who is not the
author can act on it. Never let a prose diff produce an empty review.
