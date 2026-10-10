#!/usr/bin/env bash
# Lokale vervanger voor de 'Claude Agents' GitHub Actions workflow.
# Draait Claude Code lokaal (via je eigen 'claude auth login' sessie) i.p.v.
# via CLAUDE_CODE_OAUTH_TOKEN in CI, wat momenteel kapot is
# (https://github.com/anthropics/claude-code-action/issues/1614).
#
# Nieuwe issues gaan eerst naar de product-owner; daarna bepaalt het (enige) routing-label
# de agent (de keten loopt via label-wissels, zie README), of
# issues met een nieuwe '@claude'-comment, en laat de bijbehorende rolagent
# (uit christiaandouma/claude-agent-template) het issue afhandelen.
#
# Bedoeld om herhaald te draaien (bv. via /loop), niet als daemon zelf.

set -euo pipefail

repo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
template_repo="christiaandouma/claude-agent-template"
state_file=".claude-agent-state.json"

[[ -f "$state_file" ]] || echo '{}' > "$state_file"

# Eén routing-label per issue; het label is de stafstok die agents doorgeven.
# Zelfde mapping als de 'Bepaal welke agent'-stap in
# .github/workflows/claude-agents-reusable.yml — pas daar aan, niet hier.
routing_labels='"needs-refinement","needs-info","architecture","design","bug","feature","ci","devops","dependencies","docs","documentation"'

label_to_agent() {
  case "$1" in
    needs-refinement|needs-info) echo "product-owner" ;;
    architecture|design) echo "architect" ;;
    bug|feature) echo "developer" ;;
    ci|devops|dependencies) echo "devops" ;;
    docs|documentation) echo "tech-writer" ;;
    *) echo "maintainer" ;;
  esac
}

# Eerste routing-label uit een labels-JSON, of "" als er geen is (= klaar).
routing_label() {
  echo "$1" | jq -r "[.[].name | select(IN($routing_labels))][0] // \"\""
}

state_has() {
  jq -e --arg n "$1" '(.[$n] // {}) | has("handled_label")' "$state_file" > /dev/null
}

state_get() {
  jq -r --arg n "$1" --arg k "$2" '.[$n][$k] // ""' "$state_file"
}

state_set() {
  local tmp
  tmp="$(mktemp)"
  jq --arg n "$1" --arg k "$2" --arg v "$3" '.[$n][$k] = $v' "$state_file" > "$tmp" && mv "$tmp" "$state_file"
}

fetch_role_file() {
  local agent="$1"
  gh api "repos/$template_repo/contents/.claude/agents/${agent}.md" -q .content | base64 --decode
}

sync_skills() {
  mkdir -p .claude/skills
  gh api "repos/$template_repo/git/trees/main?recursive=true" \
    --jq '.tree[] | select(.type == "blob") | select(.path | startswith(".claude/skills/")) | .path' | \
  while read -r path; do
    mkdir -p "$(dirname "$path")"
    gh api "repos/$template_repo/contents/$path" -q .content | base64 --decode > "$path"
  done
}

install_plugins() {
  claude plugin marketplace add JuliusBrussee/caveman >/dev/null 2>&1 || true
  claude plugin install caveman@caveman >/dev/null 2>&1 || true
}

run_agent() {
  local agent="$1" issue_number="$2" issue_title="$3" issue_body="$4" label="${5:-}"
  local role_md prompt
  role_md="$(fetch_role_file "$agent")"

  prompt="$(cat <<EOF
You are the "$agent" agent.
Write everything in English (comments, PRs, commits, docs), whatever language the issue uses.

Your role, scope and way of working:
---
$role_md
---

Issue: #$issue_number - $issue_title
Current label: ${label:-none}
Content:
$issue_body

Complete ONLY this issue, within your role. Do not start other work you come
across along the way (e.g. stray CVEs, dependency bumps, refactors) — mention it
at most as an observation in your comment/PR description, don't pick it up yourself.

When you are done, hand the issue off exactly as your "Hand-off" section describes:
swap the single routing label with gh issue edit $issue_number. Never leave more than one routing label on the issue.

If you change code: open a pull request (gh pr create) and leave it open.
Never merge yourself (no gh pr merge, no direct push to main) —
a human reviews and merges.

If it is about advice/analysis: post a comment on the issue
(gh issue comment $issue_number --body "...").
EOF
)"

  sync_skills
  install_plugins

  echo "[$agent] verwerk issue #$issue_number..."
  if claude -p "$prompt" \
    --allowedTools "Bash,Read,Write,Edit,Grep,Glob" \
    --disallowedTools "Bash(gh pr merge*),Bash(gh api*/merge*),Bash(gh api*-X PUT*pulls*),Bash(git push*main),Bash(git push*master),Bash(gh repo delete*),Bash(gh release*)" \
    < /dev/null; then
    echo "[$agent] issue #$issue_number afgehandeld."
    return 0
  else
    echo "[$agent] issue #$issue_number: claude run gefaald, probeer volgende keer opnieuw." >&2
    return 1
  fi
}

# Open blockers van een issue: regels als "Blocked by #12" / "Depends on #12"
# (ook "Geblokkeerd door" / "Afhankelijk van") in de body. Zelfde conventie als
# de 'Controleer of het issue geblokkeerd is'-stap in de reusable workflow.
open_blockers() {
  local self="$1" body="$2" n state out=""
  for n in $(echo "$body" | grep -iE '^[[:space:]>*-]*(blocked by|depends on|geblokkeerd door|afhankelijk van)\b' | grep -oE '#[0-9]+' | tr -d '#' | sort -u); do
    [[ "$n" == "$self" ]] && continue
    state="$(gh issue view "$n" --repo "$repo" --json state -q .state 2>/dev/null || echo CLOSED)"
    [[ "$state" == "OPEN" ]] && out+="#$n "
  done
  echo "$out"
}

# Steward (zie .claude/agents/steward.md): PR-review en wekelijkse audit.
run_steward() {
  local mode="$1" detail="$2" role_md prompt
  role_md="$(fetch_role_file steward)"
  prompt="$(cat <<EOF
You are the "steward" agent in $mode mode.
Write everything in English.

Your role, scope and way of working:
---
$role_md
---

$detail
EOF
)"
  sync_skills
  install_plugins
  echo "[steward] $mode..."
  claude -p "$prompt" \
    --allowedTools "Read,Grep,Glob,Bash(gh pr comment*),Bash(gh pr diff*),Bash(gh pr view*),Bash(gh pr list*),Bash(gh issue view*),Bash(gh issue list*),Bash(gh issue create*),Bash(gh issue edit*),Bash(gh issue comment*),Bash(git log*),Bash(git diff*)" \
    < /dev/null
}

# Review de eerste open PR (zelfde repo, geen concept) waarvan de huidige head nog
# niet gereviewd is. Geeft 0 terug als er een run is gedaan.
review_next_pr() {
  local pr number head_sha
  while read -r pr; do
    number="$(echo "$pr" | jq -r .number)"
    head_sha="$(echo "$pr" | jq -r .headRefOid)"
    [[ "$(state_get "pr-$number" reviewed_sha)" == "$head_sha" ]] && continue
    run_steward "PR review" "Review pull request #$number in $repo." || true
    state_set "pr-$number" reviewed_sha "$head_sha"
    return 0
  done < <(gh pr list --repo "$repo" --state open --json number,headRefOid,isCrossRepository,isDraft | \
    jq -c '.[] | select(.isCrossRepository == false and .isDraft == false)')
  return 1
}

# Wekelijkse audit (max. 1x per 7 dagen). Geeft 0 terug als er een run is gedaan.
weekly_audit() {
  local last now
  last="$(state_get audit last_run)"
  now="$(date +%s)"
  if [[ -n "$last" ]] && (( now - last < 604800 )); then
    return 1
  fi
  run_steward "periodic audit" "Produce the program status for $repo." || true
  state_set audit last_run "$now"
  return 0
}

# Eén agent-run per poll — bewust, niet de hele achterstand in één keer.
# Zo blijft elke run klein, te volgen, en kost een mislukte poging (netwerk,
# sessielimiet) je er maar één, niet de hele wachtrij.
#
# Flow: een nieuw issue gaat altijd eerst naar de product-owner, wat voor label
# je er ook op zet. Daarna bepaalt het label welke agent aan de beurt is; elke
# agent zet bij afronding het label voor de volgende (zie "Hand-off" in de
# rolbestanden). Geen routing-label meer = klaar.

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Leg vast wat er is afgehandeld. Wacht de agent op antwoord (needs-info), dan
# onthouden we dat label zodat er pas opnieuw gedraaid wordt na een @claude-comment.
settle() {
  local number="$1" start_label="$2" after
  after="$(routing_label "$(gh issue view "$number" --repo "$repo" --json labels -q .labels)")"
  case "$after" in
    needs-info|needs-refinement) state_set "$number" handled_label "$after" ;;
    *) state_set "$number" handled_label "$start_label" ;;
  esac
}

ran=0
issues_json="$(gh issue list --repo "$repo" --state open --limit 100 --json number,title,body,labels)"

while read -r issue; do
  number="$(echo "$issue" | jq -r .number)"
  title="$(echo "$issue" | jq -r .title)"
  body="$(echo "$issue" | jq -r '.body // ""')"
  labels="$(echo "$issue" | jq -c .labels)"
  current="$(routing_label "$labels")"

  # Het statusissue van de steward is geen werk voor de agents.
  [[ "$(echo "$labels" | jq 'any(.[]; .name == "program-status")')" == "true" ]] && continue

  # Geblokkeerd door een open issue: label zetten en overslaan (de rest van de wachtrij gaat door).
  blockers="$(open_blockers "$number" "$body")"
  if [[ -n "$blockers" ]]; then
    echo "[#$number] geblokkeerd door ${blockers}— overgeslagen."
    if [[ "$(echo "$labels" | jq 'any(.[]; .name == "blocked")')" != "true" ]]; then
      gh issue edit "$number" --repo "$repo" --add-label blocked >/dev/null || true
      gh issue comment "$number" --repo "$repo" --body "Blocked: waiting for ${blockers}to be closed. This issue is picked up automatically once all blockers are closed." >/dev/null || true
    fi
    continue
  fi
  if [[ "$(echo "$labels" | jq 'any(.[]; .name == "blocked")')" == "true" ]]; then
    gh issue edit "$number" --repo "$repo" --remove-label blocked >/dev/null 2>&1 || true
  fi

  # Migratie van het oude state-formaat (opened_handled).
  if ! state_has "$number" && [[ "$(state_get "$number" opened_handled)" == "true" ]]; then
    state_set "$number" handled_label "$current"
  fi

  # 1. Nieuw issue: altijd eerst de product-owner.
  if ! state_has "$number"; then
    run_agent product-owner "$number" "$title" "$body" "$current" || true
    settle "$number" "$current"
    state_set "$number" last_comment_at "$(now_utc)"
    ran=1
    break
  fi

  handled="$(state_get "$number" handled_label)"

  # 2. Label is veranderd sinds de laatste run: de volgende agent in de keten.
  if [[ -n "$current" && "$current" != "$handled" ]]; then
    agent="$(label_to_agent "$current")"
    run_agent "$agent" "$number" "$title" "$body" "$current" || true
    settle "$number" "$current"
    state_set "$number" last_comment_at "$(now_utc)"
    ran=1
    break
  fi

  # 3. Nieuwe @claude-comment: de agent van het huidige label (of de maintainer als het issue klaar is).
  last_comment_at="$(state_get "$number" last_comment_at)"
  comment="$(gh issue view "$number" --repo "$repo" --json comments -q .comments | \
    jq -c --arg last "$last_comment_at" '[.[] | select(.createdAt > $last) | select(.body | contains("@claude"))] | sort_by(.createdAt) | .[0] // empty')"
  if [[ -n "$comment" ]]; then
    agent="$(label_to_agent "${current:-none}")"
    if run_agent "$agent" "$number" "$title" "$(echo "$comment" | jq -r .body)" "$current"; then
      state_set "$number" last_comment_at "$(echo "$comment" | jq -r .createdAt)"
    fi
    settle "$number" "$handled"
    ran=1
    break
  fi
done < <(echo "$issues_json" | jq -c 'sort_by(.number) | .[]')

# Geen issue-werk deze poll: de steward (nog steeds max. één run per poll).
if (( ran == 0 )); then
  review_next_pr || weekly_audit || true
fi

echo "Poll klaar."
