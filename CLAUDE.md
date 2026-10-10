# CLAUDE.md

Project repos set up from this template route code and git changes
through GitHub issues — not through direct edits in a chat session.

## Rule

When the user asks for a change to tracked code, config, workflows or
infrastructure (not just a question or an explanation), create or update
a GitHub issue describing it first. Do not edit files and commit/push
directly as the response to the chat request itself, even when the user
is talking to you directly and the change looks small, obvious or urgent.

- If an issue already exists for the work, use that one.
- If none exists, create one — with the routing label this template's
  agent-chain uses (`architecture`, `bug`, `feature`, `ci`, `docs`, …) so
  it gets picked up automatically — then let that chain (or an explicit
  PR referencing the issue) make the actual change.
- Reviewing, discussing or planning in chat is fine. The change itself
  lands through an issue and a PR, not a direct commit made in response
  to the request.

**Why:** every change should be traceable to an issue and reviewed via a
PR, the same way the agent-chain (product-owner → architect → developer →
devops/tech-writer → steward) already works in this template. A direct
edit-and-push in a chat session skips that trail — no issue to link the
change to, no routing to the right role, no steward review before it
merges.

## Read the ADRs first

Before making or reviewing any change, read the project's existing
Architecture Decision Records (typically `docs/adr/*.md`) that are
relevant to the area being touched — not just the issue text. A decision
already recorded there (scope, a rejected alternative, a constraint) takes
precedence over re-deriving the same judgment call from scratch, and
missing it is how a change ends up contradicting a decision the project
already made. If a change does need to revisit a decision an ADR recorded,
say so explicitly and update that ADR rather than silently drifting from
it.

## The steward role

`.claude/agents/steward.md` defines a read-only, advisory role: it reviews
open pull requests against their issue's acceptance criteria, the ADRs and
architecture docs, scope, and fit with other open work — and separately
runs a periodic program-wide audit (dependency gaps, stale ADRs, lagging
docs), kept as a single `Program status` issue.

Steward never writes code, never pushes, never merges, never approves and
never edits another issue's body or labels — it only reports findings
(verdict `Fits` / `Concerns` / `Does not fit` on a PR) and leaves every
decision to a human. Treat its findings the same way: as input to weigh,
not as something to act on automatically.
