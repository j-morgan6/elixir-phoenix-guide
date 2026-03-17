---
name: code-quality
description: Automated code quality detection — duplication, complexity, unused functions. Invoke when analyzing or refactoring Elixir code.
file_patterns:
  - "**/*.ex"
  - "**/*.heex"
auto_suggest: true
---

# Code Quality Automation

Automated detection of code quality issues in Elixir projects. These checks run automatically via hooks when files are written, and can be run on-demand for full project analysis.

## RULES — Follow these with no exceptions

1. **Duplicated functions must be extracted** — when 2+ modules share >70% identical function implementations, create a shared module
2. **Functions must stay below ABC complexity 30** — break complex functions into smaller helpers with single responsibilities
3. **Unused private functions must be removed** — dead code increases maintenance burden and confusion
4. **Duplicated templates must become components** — when 2+ HEEx files share >40% identical markup, extract to a function component
5. **Run full analysis before major refactors** — use `run_analysis.sh` to establish a baseline before and after
6. **Address duplication before complexity** — extracting shared code often reduces complexity as a side effect
7. **Prefer composition over inheritance** — extract shared functions into modules imported/used where needed, not into base modules

---

## What Gets Detected

### Code Duplication

Detects when the same function appears in multiple modules with >70% body similarity.

**How it works:** AST-based analysis parses function bodies and compares them using trigram similarity. Functions with the same name, arity, and similar bodies are flagged.

**Example output:**
```
  Duplication Detected
   Function `format_time/1` (85% similar)
     lib/app_web/live/cycle_time.ex:45
     lib/app_web/live/lead_time.ex:52
   Suggestion: Extract to a shared module
```

**How to fix:**
```elixir
# Create: lib/app_web/live/helpers.ex
defmodule AppWeb.Live.Helpers do
  def format_time(%Decimal{} = seconds) do
    seconds |> Decimal.to_float() |> format_time()
  end

  def format_time(seconds) when is_number(seconds) do
    # shared formatting logic
  end
end

# In each LiveView:
import AppWeb.Live.Helpers, only: [format_time: 1]
```

### ABC Complexity

Measures function complexity using the ABC metric (Assignments, Branches, Conditions).

- **A (Assignments):** `=` operators
- **B (Branches):** `case`, `cond`, `if`, `unless`, `with`, `->` clauses
- **C (Conditions):** `&&`, `||`, `and`, `or`, `==`, `!=`, `>`, `<`, `>=`, `<=`, `when` guards

**ABC = sqrt(A² + B² + C²)** — threshold is 30.

**Example output:**
```
  High Complexity Detected
   Function `calculate_trend_line/1` — ABC complexity 41 (threshold: 30)
     lib/app_web/live/helpers.ex:45
   Suggestion: Break into smaller functions with single responsibilities
```

**How to fix:**
```elixir
# Before: one large function (complexity 41)
def calculate_trend_line(data) do
  # 50 lines of assignments, branches, conditions
end

# After: composed smaller functions (complexity <20 each)
def calculate_trend_line(data) do
  sums = calculate_regression_sums(data)
  slope = calculate_slope(sums)
  intercept = calculate_intercept(sums, slope)
  build_trend_points(data, slope, intercept)
end
```

### Unused Private Functions

Detects `defp` functions that are defined but never called within the module.

**Example output:**
```
  Unused Private Functions
   `old_format_date` defined at line 123 but never called
   Suggestion: Remove if no longer needed
```

**Common after refactoring** — when you extract code to a shared module, the original private functions may become dead code.

### Template Duplication

Detects when HEEx templates in the same directory share >40% identical markup.

**Example output:**
```
Template Duplication Detected
   86 identical lines (72%) between:
     cycle_time.html.heex
     lead_time.html.heex
   Suggestion: Extract shared markup to a function component
```

**How to fix:**
```elixir
# Create a function component for the shared markup
defmodule AppWeb.Live.Components do
  use Phoenix.Component

  def metric_filters(assigns) do
    ~H"""
    <div class="filters">
      <!-- shared filter markup -->
    </div>
    """
  end
end
```

---

## Running Analysis

### Automatic (via hooks)

Code quality checks run automatically when files are written or edited:
- `.ex`/`.exs` files trigger duplication, complexity, and unused function checks
- `.heex` files trigger template duplication checks

### On-Demand (full project)

Run a complete analysis from the project root:

```bash
bash ~/.claude/scripts/elixir-phoenix-guide/run_analysis.sh
```

Or target specific checks:

```bash
# Single file analysis
elixir ~/.claude/scripts/elixir-phoenix-guide/code_quality.exs all lib/app_web/live/my_live.ex

# Specific check
elixir ~/.claude/scripts/elixir-phoenix-guide/code_quality.exs complexity lib/app_web/live/my_live.ex
elixir ~/.claude/scripts/elixir-phoenix-guide/code_quality.exs duplication lib/app_web/live/my_live.ex
elixir ~/.claude/scripts/elixir-phoenix-guide/code_quality.exs unused lib/app_web/live/my_live.ex

# Scan entire lib/ directory
elixir ~/.claude/scripts/elixir-phoenix-guide/code_quality.exs scan lib/
```

---

## Testing

For testing guidance, see `testing-essentials`. When writing tests for refactored shared modules, ensure:
- Original test coverage is maintained
- New shared module has its own test file
- All callers still pass their tests after extraction
