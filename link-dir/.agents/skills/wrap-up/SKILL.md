---
name: wrap-up
description: >
  Scan the current conversation and produce a structured session close-out: deferred items,
  open questions, decisions made, and the single clearest next action. Ends with a ready-to-paste
  "next session opener" prompt.
  Use this skill whenever the user says "/wrap-up", "/deferred", "wrap up this session",
  "what did we defer", "what's left", "close out this session", "end of session summary",
  or asks what to pick up next time.
user-invocable: true
argument-hint: 'Wrap up the current session'
---

# Wrap-Up

Scan the full conversation and produce a compact, structured close-out. The goal is to make the
next session frictionless: someone reading only the output block should know exactly what happened,
what was left open, and what to do first.

## Procedure

1. **Read the whole conversation** — scan from the first message to the most recent. Do not rely on memory; read the actual exchange.
2. **Extract four categories** (see Output Contract below).
3. **Write the next session opener** — a single ready-to-paste prompt that re-establishes context and states the next action in one message.
4. Output the entire result as one fenced markdown block (4 backticks) so it is easy to copy.

## Output Contract

Return exactly one fenced block with these five sections in this order:

### 1. Deferred Items
Things the user or assistant explicitly set aside ("we'll do that later", "not now", "skip for now",
or any task that was started but not finished). If none, write "None."

### 2. Open Questions
Unresolved ambiguities, questions asked but not answered, decisions still pending, or things that
need external input. If none, write "None."

### 3. Decisions Made
Choices locked in during this session — architecture picks, naming conventions, approach selections,
rejected alternatives. Write each as a one-liner: what was decided and why (if stated). If none, write "None."

### 4. Next Action
The single most important thing to do next. One sentence. Concrete and actionable — not "continue
working on X" but "implement Y in file Z" or "answer the open question about A before touching B."

### 5. Next Session Opener
A ready-to-paste prompt the user can send at the start of the next session. It must:
- Re-establish the project/task context in 1–2 sentences
- Reference the most important decision or constraint from this session
- State the next action from section 4 as a direct instruction
- Fit in one paragraph (no headers or bullets inside it)

## Formatting Rules

- Wrap the entire output in 4 backticks.
- Use `##` headings for each of the five sections inside the block.
- Keep bullets short — one line each.
- Do not add commentary outside the fenced block.
- If a section is empty, say so explicitly ("None.") — do not omit the heading.

## Example Shape

````
## Deferred Items
- Migrate tests to the new runner (decided to skip for this session)
- Review error-handling edge cases in `fetch.ts`

## Open Questions
- Should the cache TTL be configurable per-route or global?
- Is the staging environment ready for the new schema migration?

## Decisions Made
- Use `zod` for runtime validation (chosen over `io-ts` for simpler syntax)
- Keep the existing REST endpoints; GraphQL layer is a follow-up project
- Rejected server-side rendering for the dashboard (too much complexity for current scale)

## Next Action
Implement the `zod` schema for the `/users` endpoint in `src/routes/users.ts` before touching any other route.

## Next Session Opener
We're adding `zod` runtime validation to the REST API in this repo. We chose `zod` over `io-ts` for
its simpler syntax, and the plan is to validate each route one at a time starting with `/users`.
Pick up by implementing the `zod` schema for the `/users` endpoint in `src/routes/users.ts`.
````
