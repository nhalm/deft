# Phoenix Minimal Fixture

Synthetic Phoenix app for E2E loop safety evals.

## Status

**TODO:** This fixture needs to be implemented with:
- A minimal Phoenix 1.7+ application
- Mix dependencies (phoenix, ecto, phoenix_ecto, postgrex)
- A simple schema (e.g., User with name and email fields)
- A controller with basic CRUD actions
- Integration tests
- Git repository initialized

## Purpose

Used by `test/eval/e2e/loop_safety_test.exs` to test the overnight loop against realistic code changes.

## Issues Supported

The fixture should support these 5 issue types:
1. Fix a failing test
2. Add a schema field with migration
3. Add a controller action
4. Refactor a module
5. Fix a bug with constraint
