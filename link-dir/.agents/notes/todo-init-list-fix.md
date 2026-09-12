# `todo init` rejects a string (and array-of-strings) `list`

## Symptom

Calling the `todo` tool with `op: "init"` and `list` as a plain string fails:

```
Invalid todo arguments: list must be phased task list (init) (was a string)
```

Passing `list` as an array of strings also fails, with a *different* error:

```
Invalid todo arguments: list[0] must be an object (was a string)
list[1] must be an object (was a string)
...
```

The phased-object form works fine:

```json
{"op": "init", "list": [
  {"phase": "Foundation", "items": ["a", "b"]},
  {"phase": "Verify", "items": ["c"]}
]}
```

## Cause

The `todo.init` schema declares `list` as:

```
type: ["array", "string"]
oneOf:
  - $ref: task_list          # array of { phase, items } objects
  - { items: { type: string }, type: array }   # "flattened single-phase"
```

Two mismatches between schema and implementation:

1. **String `list`**: the outer `type` allows a string, but neither `oneOf`
   branch accepts a bare string (branch 1 is an object, branch 2 is an array).
   So a string fails `oneOf` → "was a string".
2. **Array-of-strings `list`**: the schema's second branch claims a flattened
   single-phase init is supported, but the *implementation* validates that
   every `list[i]` is an object (a phase). So each string element is rejected
   → "list[N] must be an object (was a string)".

Net: the "flattened single-phase" branch is dead code — the implementation
only ever accepts an array of `{ phase, items }` objects.

## Fix / workaround

Always pass `list` as an **array of phase objects**, never a string or
array-of-strings:

```json
{"op": "init", "list": [
  {"phase": "Foundation", "items": ["task one", "task two"]},
  {"phase": "Verify", "items": ["run suite"]}
]}
```

This is the only `init` form that currently succeeds.

## To actually fix the tool (harness side)

The schema is wrong for two reasons and should be corrected in the harness
tool definition:

- Remove the misleading `oneOf` array-of-strings branch (or make the
  implementation honor it if flattened single-phase init is intended).
- Decide whether a bare string `list` should be allowed (and if so, add a
  matching `oneOf` branch); otherwise keep the type as `array` only.

Until then, callers must use the phased-object form.
