# v1.3.0 Design: testing-essentials Skill

**Date:** 2026-02-22
**Version:** 1.3.0
**Status:** Approved

## Problem

The plugin has no proactive testing guidance. `testing-guide.md` exists as a passive reference
but is never invoked automatically. Developers writing test files get no skill-enforced guidance
on setup, coverage, or assertions. The plugin also cannot be assumed to run alongside
`superpowers`, so it must stand alone as the only testing touchpoint.

## Approach

Option C: Add `testing-essentials` skill + refactor `testing-guide.md` into a deep reference
companion. Eliminates duplication, makes the skill the proactive trigger, and keeps the agent
doc as the detailed example reference.

Rejected alternatives:
- **Option A (skill only):** Leaves overlap between skill and agent doc; maintenance burden.
- **Option B (skill + cross-references):** Same duplication problem, just with pointers added.

## Components

### 1. New skill: `skills/testing-essentials/SKILL.md`

**Description:** `MANDATORY for ALL test files. Invoke before writing any _test.exs file.`

**RULES (non-negotiable, visible in 10 seconds):**
1. Use `DataCase` for database tests, `ConnCase` for LiveView/controller tests — never mix them
2. Test both happy path AND error/invalid cases for every function
3. Use `async: true` only when tests don't touch shared state or external services
4. Define test data in fixtures (`test/support/`) — never build it inline across multiple tests
5. Use `has_element?/2` and `element/2` for LiveView assertions — not `html =~ "text"` for structure
6. Always test the unauthorized case for any protected resource
7. Test the public context interface, not internal implementation details
8. Use `describe` blocks to group tests by function or behavior

**Content sections:**
- TDD guidance: 2-3 sentences — write the failing test first, implement until it passes
- Quick patterns: DataCase/ConnCase setup, fixture skeleton, LiveView test skeleton, context test skeleton
- Pointer to `testing-guide.md` for full examples

### 2. Refactor `agents/testing-guide.md`

- Add header: "Reference companion to `elixir-phoenix-guide:testing-essentials` — invoke the skill first"
- Remove structural/introductory content that now lives in the skill's RULES
- Keep all detailed code examples organized by category
- No duplication with the skill's RULES section

### 3. Update existing 4 skills

- `phoenix-liveview-essentials`: Replace existing testing section with pointer to `testing-essentials`
- `elixir-essentials`: Add one-liner pointer to `testing-essentials` for test files
- `ecto-essentials`: Add one-liner pointer to `testing-essentials` for test files
- `phoenix-uploads`: Add one-liner pointer to `testing-essentials` for test files

### 4. Metadata updates

- `VERSION`: `1.2.0` → `1.3.0`
- `CHANGELOG.md`: Add `[1.3.0]` entry
- `ROADMAP.md`: Mark v1.3.0 as completed, add to version mapping

## Success Criteria

- `testing-essentials` skill is invoked before any `_test.exs` file is written
- No testing content is duplicated between the skill and `testing-guide.md`
- All 4 existing skills point to `testing-essentials` for test files
- `testing-guide.md` works as a standalone reference doc
