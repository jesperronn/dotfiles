---
name: save-plan-docs
group: writing-format
summary: "Turn a suggestion into a plan doc with metadata and a tool-tagged filename."
description: Use when the user wants an idea, prompt, request, or suggestion turned into a saved plan document in a `docs/` folder, especially when they want metadata such as start time, source question, creation duration, or the tool name recorded in both the file body and filename.
---

# Save Plan Docs

Create a plan document from the user's suggestion and save it under a `docs/` directory.

This skill is general-purpose. It is not tied to any one repository or project layout beyond creating or using a `docs/` folder in the working area.

## What to capture

For each plan, record:

- `start_time`
- `input_question`
- `creation_time_seconds` or `creation_duration`
- `tool_name`

Also include the tool name inside the plan content itself.

## File placement

Save the output in `docs/`. If `docs/` does not exist, create it.

Use a filename that includes the tool name. Prefer this pattern:

`docs/YYYY-MM-DD_HHMMSS_<tool-name>_plan.md`

If the user wants a different naming convention, keep the tool name in the filename anyway.

## Working method

1. Record the start timestamp before drafting.
2. Read the user's suggestion or question carefully.
3. Convert it into a concrete plan.
4. Measure how long the drafting took.
5. Save the finished plan to `docs/` using a tool-tagged filename.

## Plan structure

Use this structure unless the user asks for another format:

```markdown
# Plan

## Metadata
- start_time: <ISO-8601 timestamp>
- input_question: <user input, normalized only if needed for readability>
- creation_time_seconds: <elapsed seconds>
- tool_name: <tool name>

## Plan
1. <step>
2. <step>
3. <step>

## Notes
- <assumptions, constraints, or follow-ups>
```

## Tool name

Use the executing assistant or tool name when it is clear from context. If no better value is available, use `codex`.

## Output quality

Make the plan actionable. Prefer short steps, explicit assumptions, and minimal filler.
