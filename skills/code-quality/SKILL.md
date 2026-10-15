---
name: code-quality
description: "Use when refactoring or reviewing Elixir code quality — compiler warnings and Credo first, then the plugin's on-demand duplication and branch-complexity scans. Not for style rules while writing code (use elixir-essentials)."
---

# Code Quality

> Verified against Elixir 1.20, Phoenix 1.8, LiveView 1.2, Credo 1.7 — October 2026

On-demand checks for duplication and complexity. Nothing here runs automatically: the plugin's hooks check security and deprecated-API patterns on the lines Claude writes, not duplication, complexity or templates.

## RULES — Follow these with no exceptions

1. **Run `mix compile --warnings-as-errors` first** — the compiler reports unused private functions, variables, aliases and imports exactly; fix those before anything else
2. **Then run `mix credo --strict`** when the project has Credo — its `.credo.exs` thresholds override the numbers in this skill
3. **Extract duplicated function bodies** — when 2+ functions share a body that differs only in names or literals, keep one function and pass the differences as arguments
4. **Keep branch complexity low** — split functions the analyzer flags (above 15) or Credo flags (`CyclomaticComplexity`, default max 9) into pattern-matched clauses or helpers
5. **Take a baseline before a large refactor** — run the analyzer before and after, and compare
6. **Address duplication before complexity** — extracting shared code often removes branches too
7. **Share code through plain modules** — callers `alias` or `import` the shared module; don't build `__using__` base modules just to share functions
8. **Repeated HEEx markup becomes a function component** — a manual guideline; no tool checks templates

---

## Order of tools

1. `mix compile --warnings-as-errors` — unused code (the plugin no longer has its own unused-function check; the compiler is exact)
2. `mix credo --strict` — the standard style and complexity checks. `Refactor.CyclomaticComplexity` is on by default (max 9); `Design.DuplicatedCode` and `Refactor.ABCSize` are opt-in in Credo's default config
3. `mix xref callers MyApp.Mod.fun/2` and `mix xref graph` — who uses a function or module across the project
4. The plugin's analyzer (below) — duplication with renamed variables and changed literals across the whole tree, and a branch-complexity count for projects without Credo

## Running the analyzer

The scripts ship with the plugin. They need only `elixir` (no deps, no compilation) and exit 1 when they find something. `${CLAUDE_SKILL_DIR}` is this skill's own directory; Claude Code fills it in, and in other agents it means the folder containing this file.

```bash
# Whole project
elixir "${CLAUDE_SKILL_DIR}/../../scripts/code_quality.exs" scan lib/

# Umbrella: scan all apps in one pass so duplication across apps is found
elixir "${CLAUDE_SKILL_DIR}/../../scripts/code_quality.exs" scan apps/*/lib

# One file: complexity of that file, duplication against its whole lib/ tree
elixir "${CLAUDE_SKILL_DIR}/../../scripts/code_quality.exs" all lib/my_app_web/live/post_live/index.ex

# One check only
elixir "${CLAUDE_SKILL_DIR}/../../scripts/code_quality.exs" duplication lib/
elixir "${CLAUDE_SKILL_DIR}/../../scripts/code_quality.exs" complexity lib/my_app/reports.ex

# Wrapper: picks lib/ or apps/*/lib and reminds you of compile/credo first
bash "${CLAUDE_SKILL_DIR}/../../scripts/run_analysis.sh" .
```

---

## Duplication

Two function bodies count as duplicates when their ASTs are identical after variable names are replaced and string/number literals are erased. Function names, arity, module and directory don't matter. Atoms, calls and structure must match. Bodies under 25 AST nodes are ignored.

**Example output** (from a fresh `mix phx.gen.auth` app):
```
Duplicated function bodies (identical after renaming variables and literals)

   deliver_update_email_instructions/2  lib/demo/accounts/user_notifier.ex:24
   deliver_magic_link_instructions/2  lib/demo/accounts/user_notifier.ex:51
   deliver_confirmation_instructions/2  lib/demo/accounts/user_notifier.ex:68

   Suggestion: extract one shared function (parameterize what differs).
```

Generated code like this is often fine to leave as it is. In your own code, extract the shared body:

```elixir
defmodule MyApp.Reports.Summary do
  @moduledoc "Totals shared by the daily and weekly reports."

  def summarize(rows, label, precision) do
    {count, sum} = Enum.reduce(rows, {0, 0}, fn row, {c, s} -> {c + 1, s + row.amount} end)
    average = if count > 0, do: sum / count, else: 0
    %{total: sum, average: Float.round(average * 1.0, precision), label: label}
  end
end

# Callers:
#   MyApp.Reports.Summary.summarize(rows, "daily", 2)
#   MyApp.Reports.Summary.summarize(entries, "weekly", 3)
```

**Limits:** only exact matches after normalization are found, so a copy with one added line is missed (Credo's opt-in `DuplicatedCode` check with a `mass_threshold` catches near-copies). Each clause of a multi-clause function is compared on its own. Only `.ex` files are scanned.

## Branch complexity

Branch complexity is 1, plus 1 for each `if`/`unless`, each `->` clause (in `case`, `cond`, `receive`, `fn` and `with ... else`), each `with`, and each `&&`, `||`, `and`, `or`. It approximates cyclomatic complexity. The threshold is 15. Credo's `Refactor.CyclomaticComplexity` is the standard check, and the project's `.credo.exs` limit takes precedence.

**Example output:**
```
High branch complexity (threshold 15)
   classify/3  lib/my_app/classifier.ex:2  branch complexity 16

   Suggestion: split into smaller functions or pattern-matched clauses.
```

**How to fix:** move each decision into a function head.

```elixir
defmodule MyApp.Classifier do
  @moduledoc "Classifies pairs of numbers."

  def classify(a, b, _c) when a > 10 and b > 10, do: :both_big
  def classify(a, b, _c) when a > 10 or b > 10, do: :one_big
  def classify(a, a, :x), do: :same
  def classify(a, _b, c) when c == :y or a < 0, do: :odd
  def classify(a, b, _c), do: compare(a, b)

  defp compare(0, 0), do: :zero
  defp compare(0, _), do: :left_zero
  defp compare(_, 0), do: :right_zero
  defp compare(a, b) when a > b, do: :left
  defp compare(a, b) when a < b, do: :right
  defp compare(_, _), do: :tie
end
```

## Repeated markup (manual)

No tool compares templates. When you notice the same block of markup in two or more templates, move it into a function component with declared attributes and slots:

```elixir
defmodule MyAppWeb.MetricComponents do
  use Phoenix.Component

  attr :title, :string, required: true
  attr :range, :string, default: "7d"
  slot :inner_block, required: true

  def metric_panel(assigns) do
    ~H"""
    <section class="metric-panel">
      <h2>{@title} <span class="text-sm">({@range})</span></h2>
      {render_slot(@inner_block)}
    </section>
    """
  end
end
```

Use it in each template as `<.metric_panel title="Cycle time" range={@range}>...</.metric_panel>`.

---

## Testing

For testing guidance, see the `testing-essentials` skill. When you extract shared code:
- Keep the existing tests for every caller passing
- Give the new shared module its own test file
- Run `mix test` and `mix compile --warnings-as-errors` again afterwards: functions that are now unused show up as compiler warnings
