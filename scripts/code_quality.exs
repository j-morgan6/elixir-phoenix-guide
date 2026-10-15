#!/usr/bin/env elixir
# Code Quality Analyzer for the elixir-phoenix-guide plugin.
#
# On-demand, AST-based checks that complement (not replace) the compiler and
# Credo:
#   - duplication: function bodies that are identical once variable names and
#     string/number literals are erased, across every function in the scanned
#     tree, whatever their name, arity or directory
#   - complexity: "branch complexity" = 1 + if/unless + each -> clause
#     (case/cond/receive/fn/with-else) + with + &&/||/and/or. An approximation
#     of cyclomatic complexity; Credo's Refactor.CyclomaticComplexity is the
#     standard check and the project's .credo.exs thresholds win.
#
# Unused private functions are not checked here: `mix compile
# --warnings-as-errors` reports unused defp exactly, and `mix xref` covers
# cross-module usage.
#
# Usage:
#   elixir code_quality.exs scan <dir> [<dir> ...]   all checks over a tree
#   elixir code_quality.exs all <file>               file vs. its lib/ tree
#   elixir code_quality.exs duplication <file|dir>
#   elixir code_quality.exs complexity <file|dir>
# Exit status: 0 = nothing found, 1 = issues found.

defmodule CodeQuality do
  # Normalized-AST node count a body needs before it is worth reporting.
  @min_nodes 25
  @complexity_threshold 15

  # ── Function extraction ────────────────────────────────────────────────

  def functions_in(file) do
    with {:ok, content} <- File.read(file),
         {:ok, ast} <- Code.string_to_quoted(content, file: file) do
      {_, funs} = Macro.prewalk(ast, [], &collect(&1, &2, file))
      Enum.reverse(funs)
    else
      _ -> []
    end
  end

  defp collect({kind, meta, [head | rest]} = node, acc, file) when kind in [:def, :defp] do
    case fun_head(head) do
      {name, args} ->
        fun = %{
          name: name,
          arity: length(args || []),
          file: file,
          line: Keyword.get(meta, :line, 0),
          body: body(rest)
        }

        {node, [fun | acc]}

      nil ->
        {node, acc}
    end
  end

  defp collect(node, acc, _file), do: {node, acc}

  defp fun_head({:when, _, [head | _guards]}), do: fun_head(head)
  defp fun_head({name, _, args}) when is_atom(name) and (is_list(args) or is_nil(args)), do: {name, args}
  defp fun_head(_), do: nil

  defp body([[{:do, body} | _] | _]), do: body
  defp body([kw | _]) when is_list(kw), do: Keyword.get(kw, :do)
  defp body(_), do: nil

  # ── Duplication ────────────────────────────────────────────────────────

  # Variables become :_var, strings/numbers/charlists become placeholders,
  # metadata is dropped. Atoms, calls and structure are kept.
  def normalize(ast) do
    Macro.prewalk(ast, fn
      {name, _meta, ctx} when is_atom(name) and is_atom(ctx) -> {:_var, [], nil}
      {form, _meta, args} -> {form, [], args}
      bin when is_binary(bin) -> :_str
      num when is_number(num) -> :_num
      other -> other
    end)
  end

  defp node_count(ast) do
    {_, n} = Macro.prewalk(ast, 0, fn node, acc -> {node, acc + 1} end)
    n
  end

  # Groups of >= 2 functions with identical normalized bodies.
  def duplicate_groups(funs) do
    funs
    |> Enum.reject(&is_nil(&1.body))
    |> Enum.map(fn f -> {normalize(f.body), f} end)
    |> Enum.filter(fn {norm, _} -> node_count(norm) >= @min_nodes end)
    |> Enum.group_by(fn {norm, _} -> norm end, fn {_, f} -> f end)
    |> Map.values()
    |> Enum.filter(&match?([_, _ | _], &1))
    |> Enum.map(fn group -> Enum.sort_by(group, &{&1.file, &1.line}) end)
    |> Enum.sort_by(fn [f | _] -> {f.file, f.line} end)
  end

  # ── Branch complexity ──────────────────────────────────────────────────

  @branch_forms [:if, :unless, :with, :->, :&&, :||, :and, :or]

  def complexity(nil), do: 1

  def complexity(ast) do
    {_, n} =
      Macro.prewalk(ast, 1, fn
        {form, _, args} = node, acc when form in @branch_forms and is_list(args) -> {node, acc + 1}
        node, acc -> {node, acc}
      end)

    n
  end

  def complex_functions(funs) do
    funs
    |> Enum.map(&Map.put(&1, :score, complexity(&1.body)))
    |> Enum.filter(&(&1.score > @complexity_threshold))
  end

  # ── Files ──────────────────────────────────────────────────────────────

  def ex_files(path) do
    cond do
      File.dir?(path) -> Path.wildcard(Path.join(path, "**/*.ex"))
      File.regular?(path) -> [path]
      true -> []
    end
    |> Enum.reject(&String.contains?(&1, ["/deps/", "/_build/", "/node_modules/"]))
  end

  # The tree a single file is compared against: its nearest lib/ ancestor.
  def tree_for(file) do
    file
    |> Path.expand()
    |> Path.dirname()
    |> Stream.iterate(&Path.dirname/1)
    |> Enum.take_while(&(&1 != Path.dirname(&1)))
    |> Enum.find(Path.dirname(Path.expand(file)), &(Path.basename(&1) == "lib"))
  end

  # ── Reporting ──────────────────────────────────────────────────────────

  defp rel(path), do: Path.relative_to_cwd(path)

  def report(dupes, complex) do
    unless dupes == [] do
      IO.puts("Duplicated function bodies (identical after renaming variables and literals)")

      for group <- dupes do
        IO.puts("")
        for f <- group, do: IO.puts("   #{f.name}/#{f.arity}  #{rel(f.file)}:#{f.line}")
      end

      IO.puts("")
      IO.puts("   Suggestion: extract one shared function (parameterize what differs).")
      IO.puts("")
    end

    unless complex == [] do
      IO.puts("High branch complexity (threshold #{@complexity_threshold})")

      for f <- complex do
        IO.puts("   #{f.name}/#{f.arity}  #{rel(f.file)}:#{f.line}  branch complexity #{f.score}")
      end

      IO.puts("")
      IO.puts("   Suggestion: split into smaller functions or pattern-matched clauses.")
      IO.puts("   Credo's Refactor.CyclomaticComplexity is the standard check; follow .credo.exs.")
      IO.puts("")
    end

    if dupes == [] and complex == [] do
      IO.puts("No code quality issues found")
      :ok
    else
      IO.puts("Found #{length(dupes)} duplicate group(s), #{length(complex)} complex function(s)")
      :issues_found
    end
  end

  # ── Commands ───────────────────────────────────────────────────────────

  defp scan(paths, checks) do
    files = Enum.flat_map(paths, &ex_files/1) |> Enum.uniq()
    IO.puts("Scanning #{length(files)} Elixir file(s) in #{Enum.join(paths, ", ")}...")
    IO.puts("")
    funs = Enum.flat_map(files, &functions_in/1)
    dupes = if :duplication in checks, do: duplicate_groups(funs), else: []
    complex = if :complexity in checks, do: complex_functions(funs), else: []
    report(dupes, complex)
  end

  # A single file: complexity for that file; duplication of its functions
  # against every function in its lib/ tree.
  defp single(file, checks) do
    target = Path.expand(file)
    own = functions_in(file)

    dupes =
      if :duplication in checks do
        tree = ex_files(tree_for(file)) |> Enum.map(&Path.expand/1) |> Enum.reject(&(&1 == target))
        others = Enum.flat_map(tree, &functions_in/1)

        (Enum.map(own, &%{&1 | file: target}) ++ others)
        |> duplicate_groups()
        |> Enum.filter(fn group -> Enum.any?(group, &(&1.file == target)) end)
      else
        []
      end

    complex = if :complexity in checks, do: complex_functions(own), else: []
    report(dupes, complex)
  end

  defp run(checks, [path]) do
    if File.regular?(path), do: single(path, checks), else: scan([path], checks)
  end

  defp run(checks, paths) when paths != [], do: scan(paths, checks)

  def main(args) do
    result =
      case args do
        ["scan" | [_ | _] = dirs] -> scan(dirs, [:duplication, :complexity])
        ["all" | [_ | _] = paths] -> run([:duplication, :complexity], paths)
        ["duplication" | [_ | _] = paths] -> run([:duplication], paths)
        ["complexity" | [_ | _] = paths] -> run([:complexity], paths)
        ["unused" | _] -> unused_moved()
        _ -> usage()
      end

    if result == :issues_found, do: System.halt(1)
  end

  defp unused_moved do
    IO.puts("The unused-function check was removed. Use the compiler and xref instead:")
    IO.puts("  mix compile --warnings-as-errors   # reports every unused private function")
    IO.puts("  mix xref callers Mod.fun/arity     # who calls a public function")
    :ok
  end

  defp usage do
    IO.puts("""
    elixir-phoenix-guide code quality analyzer

    Usage:
      elixir code_quality.exs scan <dir> [<dir> ...]   duplication + complexity over a tree
      elixir code_quality.exs all <file|dir>           both checks (a file is compared with its lib/ tree)
      elixir code_quality.exs duplication <file|dir>
      elixir code_quality.exs complexity <file|dir>
    """)

    :ok
  end
end

CodeQuality.main(System.argv())
