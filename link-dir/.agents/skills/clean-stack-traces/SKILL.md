---
name: clean-stack-traces
group: writing-format
summary: "Condenses noisy exception-frame data into a readable, copy-pasteable stack trace."
description: Use when the user provides a stack trace, structured exception frames, Keycloak exception JSON, Java frame objects, or similar noisy error output and asks to clean it up, simplify it, make it readable, or format it for copy-paste.
---

# Clean Stack Traces

Convert noisy Java exception data into a compact stack trace that preserves the useful execution path without inventing details.

## Output contract

When the user asks for copy-pasteable output, return exactly one fenced `text` block and no surrounding explanation.

Use this order:

1. Exception type, if supplied or unambiguously inferable.
2. Exception message.
3. The first 2–5 frames, prioritizing application/project frames.
4. A blank line and `... N frames omitted ...` when frames were removed.
5. The last 1–3 frames, retaining the thread/runtime boundary.

Use standard Java notation:

```text
at fully.qualified.Class.method(File.java:line)
```

For frames without a line number, omit the location rather than guessing it. Preserve nested-class `$` names. Use `Unknown source` only when the input explicitly says so.

## Selecting frames

- Treat the input order as stack order unless the input identifies a cause chain.
- Keep the first application frames intact; these usually locate the defect.
- Keep the final runtime frames intact; these show the request/thread boundary.
- Remove repetitive framework plumbing from the middle.
- Count omitted frames accurately. If the count is uncertain, use `... frames omitted ...` without a number.
- Do not add a cause, exception type, or diagnosis that is not present in the input.

If the input contains structured fields such as `class`, `method`, and `line`, transform each field mechanically. Do not include the JSON objects in the cleaned result.

## Exception type handling

Only label an exception as `NoSuchMethodError` when the input explicitly supplies that type or the surrounding data clearly identifies it. A message such as:

```text
java.lang.Boolean org.keycloak.models.IdentityProviderModel.isHideOnLogin()
```

is a method-signature message, not by itself proof of the exception type. If no type is supplied, begin with the message instead of inventing `NoSuchMethodError`.

## Example

Input: structured frames with application frames followed by framework/runtime frames, plus a method-signature message.

Output shape:

```text
<exception type, if provided>:
  <message>

at <first application frame>
at <next application frame>
at <remaining selected first frames>

... <number> frames omitted ...

at <selected final runtime frame>
at <last runtime frame>
```

## Common mistakes

- Do not explain the likely root cause when the request is only for cleaned output.
- Do not preserve every repetitive framework frame.
- Do not use `... 15 more` unless exactly 15 frames were omitted.
- Do not turn a method-signature message into a definitive exception type.
- Do not put prose before or after the code fence when copy-paste output was requested.

