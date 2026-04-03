---
name: summarizer
description: 'Use for summarizing a conversation, debugging session, or task thread. Produces a concise consolidated markdown summary with primary intent, technical context, file references, errors, fixes, problem solving, verbatim user messages, pending tasks, current work, and the next step.'
argument-hint: 'Summarize the current task or conversation'
user-invocable: true
disable-model-invocation: false
---

# Summarizer

## When to Use
- Summarize the current conversation, work session, or debugging thread.
- Preserve intent, decisions, and progress in a compact format.
- Capture exact user language when intent tracking matters.

## Output Contract
- Return one consolidated markdown block only.
- Wrap the entire response in 4 backticks.
- Include these sections in this order:
  1. Primary Request and Intent
  2. Key Technical Concepts
  3. Files and Code Sections (with code snippets)
  4. Errors and Fixes
  5. Problem Solving
  6. All User Messages (verbatim — critical for intent tracking)
  7. Pending Tasks
  8. Current Work
  9. Optional Next Step
- Keep the summary concise but complete.
- If there are no relevant files, errors, or pending tasks, say so explicitly.

## Procedure
1. Identify the main request and any implied constraints.
2. Extract technical concepts, files, and code sections relevant to the work.
3. Capture errors, fixes, and problem-solving decisions.
4. Reproduce user messages verbatim in the message section.
5. List unfinished tasks and current work state.
6. End with one practical next step when appropriate.

## Formatting Rules
- Use clear section headings.
- Prefer short paragraphs or bullets inside the block.
- Include code snippets only when they clarify the work.
- Keep quoted user messages exact and complete.
- Do not add commentary outside the single fenced block.
