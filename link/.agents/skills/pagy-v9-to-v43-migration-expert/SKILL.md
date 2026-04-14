---
name: pagy-v9-to-v43-migration-expert
description: Migrate Ruby on Rails projects from Pagy v9 legacy APIs to Pagy v43 modern APIs. Use when a codebase still uses `Pagy::Backend`, `Pagy::Frontend`, legacy helpers such as `pagy_nav(@pagy)`, old initializer settings, old extras-specific entrypoints, or Pagy v9 option names and needs a systematic upgrade to Pagy v43.
---

# Skill-Pagy v9 to v43 Migration Expert

## Overview

Upgrade Pagy by treating v43 as an API redesign, not a normal gem bump. Prefer a repo-wide migration that updates the initializer, backend integration, view calls, renamed options, extras usage, and validation in one pass.

## Migration Workflow

1. Inspect the repo for Pagy usage before changing code.
2. Update the initializer shape and option names.
3. Replace backend and frontend integration patterns.
4. Convert view helpers to instance-method calls on `@pagy`.
5. Migrate extras-specific entrypoints and overflow handling.
6. Check custom URL parameter logic, CSS, and JavaScript.
7. Run focused tests, then broader app validation.

## Inspect First

Search for these patterns before editing:

- `Pagy::Backend`
- `Pagy::Frontend`
- `pagy_nav(`
- `pagy_nav_js(`
- `pagy_info(`
- `pagy_prev_url(`
- `pagy_next_url(`
- `pagy_bootstrap_nav(`
- `Pagy::DEFAULT`
- `@pagy.vars`
- `page_param`
- `limit_param`
- `size:`
- `ends:`
- `VariableError`
- `OverflowError`
- `pagy_array(`
- `pagy_arel(`
- `pagy_searchkick(`
- `params:` inside Pagy config or pagination calls

Treat the results as a migration inventory. Update all matching call sites so the project does not mix legacy and modern Pagy styles.

## Rebuild the Initializer

Rename the old initializer to keep it available during migration:

- `config/initializers/pagy.rb` -> `config/initializers/pagy-old.rb`

Install a fresh v43-style initializer and migrate settings into it.

Apply these naming changes while rebuilding it:

- Replace `Pagy::DEFAULT[...]` with `Pagy::OPTIONS[...]`
- Replace `@pagy.vars` with `@pagy.options`

Delete `pagy-old.rb` only after the migrated options have been verified.

## Replace Framework Integration

Update controller-side integration:

- Replace `include Pagy::Backend` with `include Pagy::Method`

Update view-side integration:

- Remove `include Pagy::Frontend`
- Call methods on the `@pagy` instance instead of global frontend helpers

## Convert Helper Calls

Convert legacy helper calls to v43 instance methods:

- `pagy_nav(@pagy)` -> `@pagy.series_nav`
- `pagy_nav_js(@pagy)` -> `@pagy.series_nav_js`
- `pagy_info(@pagy)` -> `@pagy.info_tag`
- `pagy_prev_url(@pagy)` -> `@pagy.page_url(:previous)`
- `pagy_next_url(@pagy)` -> `@pagy.page_url(:next)`
- `pagy_bootstrap_nav(@pagy)` -> `@pagy.series_nav(:bootstrap)`

When touching ERB or helper modules, update surrounding conditionals and HTML wrappers only as needed. Do not preserve helper wrappers that exist solely for legacy Pagy helper signatures.

## Rename Options and Errors

Pagy v43 removes several abbreviations and renames common options.

Apply these conversions:

- `prev` -> `previous`
- `page_param` -> `page_key`
- `limit_param` -> `limit_key`
- `size` -> `slots`
- `ends: false` -> `compact: true`
- `VariableError` -> `OptionError`
- `Pagy::OverflowError` -> `Pagy::RangeError`

Use string keys where v43 expects them:

- `page_key` should be a string
- `limit_key` should be a string

## Migrate Extras and Collection Modes

Pagy v43 folds much of the old extras behavior into core APIs.

Convert collection helpers:

- `pagy_array(...)` -> `pagy(:offset, ...)`
- `pagy_arel(...)` -> `pagy(:offset, count_over: true, ...)`

Convert search integrations to the unified style:

- `pagy_searchkick(...)` -> `pagy(:searchkick, ...)`

Do not keep legacy custom search method variable names such as `:searchkick_pagy_search`. Use the standard `pagy_search` flow expected by v43.

## Update Overflow Behavior

Assume overflow behavior changed even when no explicit option is set.

Key differences:

- `Pagy::OverflowError` becomes `Pagy::RangeError`
- Pagy now rescues `RangeError` by default and returns an empty page
- `overflow: :last_page` is discontinued

If the application depended on old overflow semantics, inspect controllers, user flows, and tests for changed behavior around out-of-range pages.

## Replace `params` with `querify`

Convert high-level query param injection to `querify` lambdas.

Convert patterns like:

```ruby
params: { a: 1, b: 2 }
```

To:

```ruby
querify: ->(p) { p.merge!('a' => 1, 'b' => 2) }
```

Preserve any existing dynamic behavior when rewriting lambdas. Use string keys when constructing query params unless the codebase proves symbol keys are required elsewhere.

## Check CSS and JavaScript

Inspect frontend assets after helper conversion.

Focus on:

- custom CSS that targets legacy Pagy classes
- any code that relies on `prev`-named classes or selectors
- JavaScript integrations that should move to `Pagy.sync`
- builder-managed asset setups such as Webpacker or Esbuild

If the project uses custom pagination styling, verify selectors and variable names against Pagy v43 stylesheets documentation before declaring the migration complete.

## Validate the Migration

After code changes, validate in this order:

1. Run targeted tests for controllers, helpers, components, and views that render pagination.
2. Run broader test coverage for the affected app area.
3. Verify representative paginated pages in the browser if a manual app run is available.
4. Confirm previous/next links, page counts, info text, compact mode, and overflow behavior.
5. Remove `config/initializers/pagy-old.rb` only after the migrated app is stable.

## Final Checklist

- Rename `pagy.rb` to `pagy-old.rb`
- Install a new v43 initializer
- Replace `include Pagy::Backend` with `include Pagy::Method`
- Remove `include Pagy::Frontend`
- Replace legacy helper calls with `@pagy` instance methods
- Replace legacy option and error names
- Convert `params` usage to `querify`
- Migrate extras-specific entrypoints to unified v43 APIs
- Re-check CSS and JavaScript integration
- Delete `pagy-old.rb` after validation
