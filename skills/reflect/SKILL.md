---
name: reflect
description: Use at the end of an /orchestrate run, or when the user asks to reflect on the session, learn from it, or turn what went wrong into skill updates. Writes proposals as markdown files to ~/.claude/skill-proposals for the user to review; never edits skills directly.
---

# Reflect

Turn what this session learned into skill-change proposals for the user to review. You propose; the user applies. Never edit files under `~/.claude/skills/` from this skill.

## 1. Find the evidence

After an orchestrate run, read its ledger first (`ledger.md` in the newest run dir under `~/.local/state/orchestrate/<repo path with / replaced by ->/`, the ledger's State line): after compaction it is the only record of fix rounds and findings. Then look back over this session for moments that cost time:
- a worker that reported FAILED or BLOCKED, or needed fix rounds, and why
- a tester or reviewer finding that a better brief or skill would have prevented
- the user correcting you or repeating an instruction
- a command or tool that failed in a non-obvious way, and the fix
- a skill that was missing, wrong, or loaded too late

## 2. Filter hard

A proposal is worth making only if it carries a specific, checkable fact that cost time. "Be careful with tests" is worthless. "pytest -x on this repo hides the second failure, so the worker fixed one and the tester found the next; brief the Check as `pytest -q`" is the standard.

Drop anything that:
- happened once and will not recur
- is already in a skill, CLAUDE.md, or a memory file (grep `~/.claude/skills`, `~/.claude/CLAUDE.md` and the project memory directory)
- duplicates a proposal already waiting, applied or rejected: read the `# ` titles in `~/.claude/skill-proposals/*.md`, `applied/*.md` and `rejected/*.md` under it. A rejected idea is never proposed again.

Prefer an edit to an existing skill over a new skill. At most three proposals. Zero is a normal outcome: say so and stop.

## 3. Write the proposals

Get this session's id from your scratchpad directory path, which the system prompt gives as `/tmp/claude-<uid>/<project>/<SESSION_ID>/scratchpad`: the component just before `/scratchpad` is the id and the transcript file name. Never take the newest transcript across projects: other sessions run at the same time.

Pipe the proposals as JSON into the writer shipped with this workflow (`~/.claude/orchestrate/write_proposals.py`), which validates them and never overwrites:

```bash
python3 ~/.claude/orchestrate/write_proposals.py <<'EOF'
{"proposals": [
  {"kind": "edit", "target": "<existing skill name>", "slug": "short-kebab-summary",
   "confidence": "high|medium|low", "sources": ["<session-id>:live"],
   "title": "One line naming the fact",
   "body": "Markdown. For an edit: what to add and where. For a new skill: full SKILL.md frontmatter and body."}
]}
EOF
```

Each proposal becomes `~/.claude/skill-proposals/<YYYYMMDD>-<slug>.md` with the frontmatter fields `kind`, `target`, `confidence`, `sources` and `generated`, then `# <title>` and the body. Use `"kind": "new"` and omit `target` for a new skill.

The writer checks that `kind` is exactly `edit` or `new`, that an `edit` has a `target`, that `confidence` is `high`, `medium` or `low`, that `sources` is a non-empty list, and that `slug` is kebab-case (`a-z`, `0-9`, `-`). No em-dashes and no line breaks in `target` or `slug`. Write each `body` as one JSON string with `\n` escapes: a raw line break inside a string makes the JSON invalid.

Exit 90 means the input was rejected (bad JSON, a failed check, or a file of that name already exists) and nothing was written: fix it and re-run. Exit 0 means every file is written: never re-run, or you create duplicates. Any other nonzero exit: `ls ~/.claude/skill-proposals` before re-running, since some files may already be written.

## 4. Tell the user

One line per proposal: file name, target skill, and the fact. Remind them the queue is reviewed by hand (move applied files to `~/.claude/skill-proposals/applied/`, rejected ones to `~/.claude/skill-proposals/rejected/`).
