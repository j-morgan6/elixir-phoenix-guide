---
name: elixir-essentials
description: "Use when writing, refactoring or reviewing any Elixir code, even a small function or a quick question about idioms — replacing nested if/case with pattern matching and guards, chaining {:ok, _}/{:error, _} steps with `with`, modern Elixir 1.18+ (type checker, JSON, dbg), Phoenix project layout. Not for OTP, Ecto, LiveView or tests (use the specific skill)."
---

# Elixir Essentials

> Verified against Elixir 1.20, Phoenix 1.8, Ecto 3.14 — October 2026

Not for: OTP, Ecto, LiveView, tests — use the specific skill (`otp-essentials`, `ecto-essentials`, `phoenix-liveview-essentials`, `testing-essentials`).

Phoenix project layout: see [project-structure.md](project-structure.md).

## RULES — Follow these with no exceptions

1. **Branch with multi-clause functions, pattern matching and `case`** — never nest `if`; `unless` is soft-deprecated, write `if !cond`
2. **A fallible function returns `{:ok, value} | {:error, reason}` on every path** — never a bare value from one clause and a tuple from another
3. **Error reasons are atoms (or a changeset), not strings** — translate them to messages at the edge (controller, LiveView)
4. **End a `with` on the last call itself, and no catch-all `else`** — `{:ok, x} <- f() do {:ok, x} end` is redundant (Credo `RedundantWithClauseResult`)
5. **Multi-step writes go inside `Repo.transact/2`** — a `with` alone does not roll back the first write when a later step fails
6. **Call `!` functions only when failure is a bug** — never wrap a bang call in `try/rescue`; call the non-bang version and `case` on it
7. **A struct pattern matches `nil` fields** — `%User{name: name}` binds `nil`; add `when is_binary(name)` when you rely on the value
8. **Treat compiler type warnings as bugs** — fix the code; don't add guards or `_ =` just to silence them
9. **Logging: put values you'll filter on in Logger metadata; a human-readable message may interpolate** — every module that logs has `require Logger`
10. **`@impl true` on every callback, clauses of one function grouped together** — split clauses fail `--warnings-as-errors`, and so does a callback without `@impl` once another callback has one

---

## Return shapes

<!-- epg:bad -->
```elixir
# Mixed shapes: callers can't pattern match on the result
def calculate(x) when is_integer(x) and x > 0, do: x * 2
def calculate(_), do: {:error, :invalid_input}
```

```elixir
def calculate(x) when is_integer(x) and x > 0, do: {:ok, x * 2}
def calculate(_), do: {:error, :invalid_input}

@doc """
Fetches a post owned by the scope's user. Returns `{:ok, post}` or `{:error, :not_found}`.
"""
def fetch_post(%Scope{} = scope, id) do
  case Repo.get_by(Post, id: id, user_id: scope.user.id) do
    nil -> {:error, :not_found}
    post -> {:ok, post}
  end
end
```

If invalid input can only come from a bug, drop the fallback clause and let `FunctionClauseError` crash.

## `with`

<!-- epg:bad -->
```elixir
with {:ok, attrs} <- validate(params),
     {:ok, post} <- Blog.create_post(scope, attrs) do
  {:ok, post}
end
```

```elixir
with {:ok, attrs} <- validate(params) do
  Blog.create_post(scope, attrs)
end
```

Writes that must succeed or fail together run in one transaction, return atom reasons, and let every error fall through unchanged:

```elixir
def transfer(%Scope{} = scope, from_id, to_id, amount) do
  Repo.transact(fn ->
    with {:ok, from} <- fetch_own_account(scope, from_id),
         {:ok, to} <- fetch_account(to_id),
         :ok <- ensure_funds(from, amount),
         {:ok, _from} <- debit(from, amount),
         {:ok, _to} <- credit(to, amount) do
      {:ok, :transferred}
    end
  end)
end
# => {:ok, :transferred} | {:error, :not_found | :insufficient_funds | Ecto.Changeset.t()}
```

A catch-all `else error -> {:error, "failed: #{inspect(error)}"}` hides new error shapes and turns them into strings nobody can match on. Add an `else` only to translate specific reasons, and list each one. (Row locking for the balance check: see the `ecto-essentials` skill.)

## Bang functions and exceptions

<!-- epg:bad -->
```elixir
def parse(body) do
  try do
    {:ok, Jason.decode!(body)}
  rescue
    Jason.DecodeError -> {:error, :invalid_json}
  end
end
```

```elixir
def parse(body) do
  case JSON.decode(body) do
    {:ok, %{"id" => id}} -> {:ok, id}
    {:ok, _other} -> {:error, :missing_id}
    {:error, _reason} -> {:error, :invalid_json}
  end
end
```

- `Repo.get_by!/2` / `get_post!/2` are right when a missing record should 404: phoenix_ecto maps `Ecto.NoResultsError` to a 404 page. Use the non-bang version plus `case` when absence is a normal outcome.
- Reserve `try/rescue` for code you don't control that only raises (no tuple-returning variant exists).

## Pattern-matching traps

- `%{}` matches **any** map, not an empty one; use `map_size(m) == 0`.
- Params and decoded JSON have **string** keys: match `%{"id" => id}`. Never `String.to_atom/1` on input (atoms are never garbage collected); map strings to atoms explicitly or use `String.to_existing_atom/1`.
- `map.key` raises `KeyError` when the key is missing; `map[:key]` returns `nil`. Structs don't implement `Access`, so use `struct.key`.
- `==`, `<` and `>` on `DateTime`, `Date`, `Decimal` compare struct fields, not values. Use `DateTime.compare/2`, `Date.before?/2`, `Decimal.compare/2`.

```elixir
def display_name(%User{name: name}) when is_binary(name), do: name
def display_name(%User{email: email}), do: email
```

## Enum pipelines and `for`

A 2–3 step `Enum` pipeline is idiomatic. A `for` comprehension is an alternative when you want a single pass, filters, or `into:`/`reduce:`:

```elixir
for item <- items, transformed = transform(item), valid?(transformed), do: format(transformed)
```

## Logging

```elixir
defmodule MyApp.Uploads do
  require Logger

  def process_upload(%Scope{} = scope, file) do
    case save_file(file) do
      {:ok, path} ->
        create_record(scope, path)

      {:error, reason} = error ->
        Logger.warning("upload failed: #{inspect(reason)}", user_id: scope.user.id)
        error
    end
  end
end
```

`user_id` goes in metadata so log search can filter on it. Phoenix's `Plug.RequestId` already sets `request_id` metadata on every request. A custom key only shows up in the output once the formatter lists it: the generated `config :logger, :default_formatter, metadata: [:request_id]` needs `:user_id` added (see the `telemetry-essentials` skill).

## Modern Elixir (1.18+)

- **Type checker.** 1.18 type-checks patterns and calls; 1.20 infers types from whole function bodies and guards, narrows types across `case`/`cond`/`with` clauses, and warns on redundant clauses. A type warning is a proven bug or dead code: fix the code. Keep `mix compile --warnings-as-errors` in CI.
- **`dbg/1`** prints each step of a pipeline with its result. Remove before committing (Credo's default `Warning.Dbg` check flags it).
- **`then/2`** pipes into a non-first argument; **`tap/2`** runs a side effect and passes the value through:
  ```elixir
  params |> normalize_attrs() |> then(&Blog.create_post(scope, &1)) |> tap(&log_result/1)
  ```
- **`JSON` (stdlib, 1.18+)**: `JSON.decode/1` returns `{:ok, term} | {:error, reason}`, `JSON.encode!/1`. Phoenix 1.8 still generates Jason (`config :phoenix, :json_library, Jason`, also Phoenix's default). For structs rendered by `json/2` or channels, implement the configured library's protocol (`@derive {Jason.Encoder, only: [...]}`); `@derive JSON.Encoder` alone isn't used by Phoenix. Plain decoding can use either.
- **`mix format --migrate`** rewrites deprecated forms (`unless` → `if !`, `'abc'` → `~c"abc"`, bitstring modifiers, and since 1.19 parens on piped calls). Run it in its own commit.
- **Structs:** `@enforce_keys [:id]` before `defstruct` turns a missing key into a compile error. Write `@spec` on public functions for docs and Dialyzer; the 1.20 checker infers types without them.
- **`defguard`** makes a reusable guard: `defguard is_amount(x) when is_integer(x) and x > 0`.
- **`Process.set_label/1`** (1.17+) names a Task or spawned process in Observer and crash logs: `Process.set_label({:import, import_id})`.
- **`to_timeout/1`** (1.17+): `to_timeout(minute: 5)` instead of `5 * 60 * 1000`.
