---
name: decide
description: Use when the user asks Claude to choose between options, or says they do not know what is best, for a real choice they will act on (which approach, tool, design, project, trade-off). Not for code reviews, factual lookups, debugging, or Claude's own implementation details.
---

# Decide

The user usually does not know the best option and would otherwise just ask you. Make the decision for them, based on what you know about their setup and what you find, and show your work briefly. You are the main session (Opus); stay here, do not fork.

## Scope

- A real choice between named or discoverable options that the user will act on.
- Not code reviews, factual lookups ("which is faster"), debugging ("what should I do about this error"), or your own implementation details: answer those directly.
- Inside superpowers:brainstorming, use decide only when the user asked for a choice or the approach is hard to reverse; otherwise use brainstorming's own one-line call. There, brainstorming's rules win: one question at a time, its approach message format, and its design-doc approval as the gate.

## Tier (say which one in a line)

- **Full** if ANY of: irreversible or hard to undo, costs weeks or money, touches several systems, or the user says "decide". All steps.
- **Quick** otherwise: steps 1, 2, 3 (options only) and 6, a 3-line pro/con per option, then the block. No advisor; the researcher only if one external fact you cannot verify in 1 or 2 reads decides it.

## Steps

1. **Precommit, before grepping memory files** (an auto-memory index, if you use one, is already loaded; that is fine). Write:
   - what is being decided, in one line;
   - "My instinct is X.";
   - provisional criteria with weights, from CLAUDE.md only (the user's stated preferences, not your taste).
2. **Memory.** Search the memory files for past decisions and feedback on the topic; the index truncates, so grep the files:
   `grep -il -E '<2-4 keywords>' ~/.claude/projects/*/memory/*.md`
   Read the hits that matter. Feedback memories are the user's stated preferences and outweigh your taste. A memory that names a file, flag or system state is checked against the current state before you cite it. Then revise the criteria and weights, and say what changed and why.
3. **Options.** At most 4, including "do nothing / later" as one honest option (not the default), and any option the user missed.
4. **Facts.** Anything resting on external facts goes to the `researcher` agent, per the routing rules in CLAUDE.md. Facts only; it is not a critic.
5. **Steelman, then attack.** For each option: its strongest case, then a pre-mortem ("three months later this failed; why?").
6. **Questions.** List the assumptions the pick rests on and answer each from the user's files, memory and current state. A question that changes the outcome and that only the user can answer (taste, money, private facts) goes into one AskUserQuestion with all such questions together (inside brainstorming: one at a time). Without an answer, decide on a stated assumption.
7. **Independent check (full tier), after steps 4 and 6 are back.** Write your leading option and one-line reason in plain text, then call `advisor()` (needs an `advisorModel` setting; if there is none, skip this step and say so under Why); it only sees what is in the transcript, so the draft must be written out first. If it disagrees, do not silently switch: resolve with one more advisor call. If you still disagree after that, pick on the evidence and record the disagreement under Why.

## Output (about 12 lines)

```
DECISION: <option>   (tier: quick|full, confidence: high|medium|low)
Why: <top 2-3 reasons, citing memory files or sources>
Criteria: <final weights, and what changed from step 1>
Others lost because: <one line each>
Instinct vs result: <same or changed; if same, the strongest evidence it is not rationalization>
Reversible: <how, and what it costs to undo>   (required whenever any option is hard to undo)
Flips if: <the fact or answer that would change it>
```

A decision is never a go. If it leads to changes, end with the actual step list for that change, then "Go?", so one go covers it. Inside brainstorming, end with brainstorming's next step instead. The user can always override the decision.
