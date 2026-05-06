---
name: memfile
description: 'Use for creating or updating a session memfile that captures task state, workflow, errors, learnings, and worklog for an active conversation or project thread.'
argument-hint: 'Create or update the current memfile'
user-invocable: true
disable-model-invocation: false
---

# Memfile

## When to Use
- Record the current session state in a structured memory file.
- Track task intent, files, workflow, corrections, and progress.
- Preserve short-lived project context that may be useful later.

## Output Contract
- Return one consolidated markdown block only.
- Wrap the entire response in 4 backticks.
- Use these sections in this order:
  1. Session Title
  2. Current State
  3. Task specification
  4. Files and Functions
  5. Workflow
  6. Errors & Corrections
  7. Codebase and System Documentation
  8. Learnings
  9. Key results
  10. Worklog
- Keep the content concise and factual.
- If a section has no useful content, say so explicitly.

## Procedure
1. Identify the session title and the active task.
2. Summarize the current state and what the user asked to build.
3. List the most relevant files, functions, commands, and system notes.
4. Capture errors, fixes, and practical learnings.
5. End with a brief worklog that reflects what was attempted and done.

## Formatting Rules
- Use short headings matching the output contract.
- Prefer bullets or compact paragraphs.
- Keep the result self-contained and easy to paste into a session note.
- Do not add commentary outside the single fenced block.
