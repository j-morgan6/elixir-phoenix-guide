#!/usr/bin/env elixir
# Code Quality Analyzer for Elixir Phoenix Guide
#
# Automated detection of code quality issues:
#   - Code duplication across modules
#   - ABC complexity analysis
#   - Unused private function detection
#
# Usage:
#   elixir code_quality.exs duplication <file>
#   elixir code_quality.exs complexity <file>
#   elixir code_quality.exs unused <file>
#   elixir code_quality.exs all <file>
#   elixir code_quality.exs scan <directory>

defmodule CodeQuality do
  @similarity_threshold 0.7
  @min_body_size 50
  @complexity_threshold 30

  # ── Duplication Detection ──────────────────────────────────────────────

  def detect_duplication(file) do
    with {:ok, content} <- File.read(file),
         {:ok, ast} <- Code.string_to_quoted(content, columns: true, file: file) do
      target_funs = extract_functions(ast)

      if Enum.empty?(target_funs) do
        []
      else
        dir = Path.dirname(file)

        find_ex_files(dir, file)
        |> Enum.flat_map(fn sibling ->
          with {:ok, sib_content} <- File.read(sibling),
               {:ok, sib_ast} <- Code.string_to_quoted(sib_content, columns: true, file: sibling) do
            sib_funs = extract_functions(sib_ast)
            compare_functions(target_funs, sib_funs, file, sibling)
          else
            _ -> []
          end
        end)
      end
    else
      _ -> []
    end
  end

  defp extract_functions(ast) do
    {_, funs} =
      Macro.prewalk(ast, [], fn
        {:def, meta, [{name, _, args} | rest]} = node, acc when is_atom(name) ->
          arity = count_arity(args)
          body = extract_body(rest)
          body_str = if body, do: Macro.to_string(body), else: ""
          line = Keyword.get(meta, :line, 0)
          {node, [{name, arity, line, body_str} | acc]}

        {:defp, meta, [{name, _, args} | rest]} = node, acc when is_atom(name) ->
          arity = count_arity(args)
          body = extract_body(rest)
          body_str = if body, do: Macro.to_string(body), else: ""
          line = Keyword.get(meta, :line, 0)
          {node, [{name, arity, line, body_str} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(funs)
  end

  defp extract_body([%{} = kw | _]) do
    Map.get(kw, :do)
  rescue
    _ -> nil
  end

  defp extract_body([[do: body] | _]), do: body
  defp extract_body([body | _]) when is_tuple(body), do: body
  defp extract_body(_), do: nil

  defp compare_functions(funs1, funs2, file1, file2) do
    for {name1, arity1, line1, body1} <- funs1,
        {name2, arity2, line2, body2} <- funs2,
        name1 == name2,
        arity1 == arity2,
        byte_size(body1) > @min_body_size,
        sim = similarity(body1, body2),
        sim >= @similarity_threshold do
      %{
        name: name1,
        arity: arity1,
        file1: file1,
        line1: line1,
        file2: file2,
        line2: line2,
        similarity: sim
      }
    end
  end

  defp similarity(s1, s2) do
    t1 = trigrams(s1)
    t2 = trigrams(s2)
    intersection = MapSet.intersection(t1, t2) |> MapSet.size()
    union = MapSet.union(t1, t2) |> MapSet.size()
    if union == 0, do: 0.0, else: intersection / union
  end

  defp trigrams(str) do
    str
    |> String.codepoints()
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.map(&Enum.join/1)
    |> MapSet.new()
  end

  defp find_ex_files(dir, exclude) do
    Path.wildcard(Path.join(dir, "*.ex"))
    |> Enum.reject(&(&1 == exclude))
  end

  # ── ABC Complexity Analysis ────────────────────────────────────────────

  def analyze_complexity(file) do
    with {:ok, content} <- File.read(file),
         {:ok, ast} <- Code.string_to_quoted(content, columns: true, file: file) do
      extract_function_complexities(ast)
      |> Enum.filter(fn {_, _, _, complexity} -> complexity > @complexity_threshold end)
    else
      _ -> []
    end
  end

  defp extract_function_complexities(ast) do
    {_, funs} =
      Macro.prewalk(ast, [], fn
        {:def, meta, [{name, _, args} | rest]} = node, acc when is_atom(name) ->
          arity = count_arity(args)
          body = extract_body(rest)
          complexity = calculate_complexity(body)
          line = Keyword.get(meta, :line, 0)
          {node, [{name, arity, line, complexity} | acc]}

        {:defp, meta, [{name, _, args} | rest]} = node, acc when is_atom(name) ->
          arity = count_arity(args)
          body = extract_body(rest)
          complexity = calculate_complexity(body)
          line = Keyword.get(meta, :line, 0)
          {node, [{name, arity, line, complexity} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(funs)
  end

  defp calculate_complexity(nil), do: 0

  defp calculate_complexity(ast) do
    {_, counts} =
      Macro.prewalk(ast, %{a: 0, b: 0, c: 0}, fn
        # Assignments
        {:=, _, _} = node, acc ->
          {node, %{acc | a: acc.a + 1}}

        # Branches
        {:case, _, _} = node, acc ->
          {node, %{acc | b: acc.b + 1}}

        {:cond, _, _} = node, acc ->
          {node, %{acc | b: acc.b + 1}}

        {:if, _, _} = node, acc ->
          {node, %{acc | b: acc.b + 1}}

        {:unless, _, _} = node, acc ->
          {node, %{acc | b: acc.b + 1}}

        {:with, _, _} = node, acc ->
          {node, %{acc | b: acc.b + 1}}

        {:->, _, _} = node, acc ->
          {node, %{acc | b: acc.b + 1}}

        # Conditions
        {:&&, _, _} = node, acc ->
          {node, %{acc | c: acc.c + 1}}

        {:||, _, _} = node, acc ->
          {node, %{acc | c: acc.c + 1}}

        {:and, _, _} = node, acc ->
          {node, %{acc | c: acc.c + 1}}

        {:or, _, _} = node, acc ->
          {node, %{acc | c: acc.c + 1}}

        {:==, _, _} = node, acc ->
          {node, %{acc | c: acc.c + 1}}

        {:!=, _, _} = node, acc ->
          {node, %{acc | c: acc.c + 1}}

        {:>, _, _} = node, acc ->
          {node, %{acc | c: acc.c + 1}}

        {:<, _, _} = node, acc ->
          {node, %{acc | c: acc.c + 1}}

        {:>=, _, _} = node, acc ->
          {node, %{acc | c: acc.c + 1}}

        {:<=, _, _} = node, acc ->
          {node, %{acc | c: acc.c + 1}}

        {:when, _, _} = node, acc ->
          {node, %{acc | c: acc.c + 1}}

        node, acc ->
          {node, acc}
      end)

    # ABC = sqrt(A^2 + B^2 + C^2)
    :math.sqrt(counts.a * counts.a + counts.b * counts.b + counts.c * counts.c)
    |> round()
  end

  # ── Unused Private Function Detection ──────────────────────────────────

  def detect_unused(file) do
    with {:ok, content} <- File.read(file) do
      lines = String.split(content, "\n")

      # Find all defp definitions
      private_funs =
        lines
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {line, num} ->
          case Regex.run(~r/^\s*defp\s+(\w+)/, line) do
            [_, name] -> [{name, num}]
            _ -> []
          end
        end)
        |> Enum.uniq_by(fn {name, _} -> name end)

      # Check if each private function is called anywhere else in the file
      private_funs
      |> Enum.filter(fn {name, _def_line} ->
        call_pattern = ~r"(?:(?<!\.)#{Regex.escape(name)}\(|&#{Regex.escape(name)}/)"

        call_count =
          lines
          |> Enum.with_index(1)
          |> Enum.count(fn {line, _num} ->
            trimmed = String.trim(line)
            not String.starts_with?(trimmed, "#") and
              not Regex.match?(~r/^\s*defp\s+#{Regex.escape(name)}/, line) and
              Regex.match?(call_pattern, line)
          end)

        call_count == 0
      end)
      |> Enum.map(fn {name, line} -> {name, line} end)
    else
      _ -> []
    end
  end

  # ── Reporting ──────────────────────────────────────────────────────────

  def report(results, file) do
    {dupes, complex, unused} = results
    has_issues = dupes != [] or complex != [] or unused != []

    if has_issues do
      IO.puts("Code Quality Analysis: #{Path.relative_to_cwd(file)}")
      IO.puts("")

      unless dupes == [] do
        IO.puts("  Duplication Detected")

        for dup <- dupes do
          pct = round(dup.similarity * 100)
          IO.puts("   Function `#{dup.name}/#{dup.arity}` (#{pct}% similar)")
          IO.puts("     #{Path.relative_to_cwd(dup.file1)}:#{dup.line1}")
          IO.puts("     #{Path.relative_to_cwd(dup.file2)}:#{dup.line2}")
          IO.puts("   Suggestion: Extract to a shared module")
          IO.puts("")
        end
      end

      unless complex == [] do
        IO.puts("  High Complexity Detected")

        for {name, arity, line, score} <- complex do
          IO.puts("   Function `#{name}/#{arity}` — ABC complexity #{score} (threshold: #{@complexity_threshold})")
          IO.puts("     #{Path.relative_to_cwd(file)}:#{line}")
          IO.puts("   Suggestion: Break into smaller functions with single responsibilities")
          IO.puts("")
        end
      end

      unless unused == [] do
        IO.puts("  Unused Private Functions")

        for {name, line} <- unused do
          IO.puts("   `#{name}` defined at line #{line} but never called")
          IO.puts("   Suggestion: Remove if no longer needed")
          IO.puts("")
        end
      end

      :issues_found
    else
      :ok
    end
  end

  # ── Directory Scan ─────────────────────────────────────────────────────

  def scan_directory(dir) do
    files = Path.wildcard(Path.join(dir, "**/*.ex"))

    IO.puts("Scanning #{length(files)} Elixir files in #{dir}...")
    IO.puts("")

    results =
      files
      |> Enum.map(fn file ->
        dupes = detect_duplication(file)
        complex = analyze_complexity(file)
        unused = detect_unused(file)
        {file, dupes, complex, unused}
      end)
      |> Enum.filter(fn {_, d, c, u} ->
        d != [] or c != [] or u != []
      end)

    if results == [] do
      IO.puts("No code quality issues found")
      :ok
    else
      for {file, dupes, complex, unused} <- results do
        report({dupes, complex, unused}, file)
      end

      total =
        Enum.reduce(results, 0, fn {_, d, c, u}, acc ->
          acc + length(d) + length(c) + length(u)
        end)

      IO.puts("Found #{total} issue(s) across #{length(results)} file(s)")
      :issues_found
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp count_arity(nil), do: 0
  defp count_arity(args) when is_list(args), do: length(args)
  defp count_arity(_), do: 0

  # ── Main ───────────────────────────────────────────────────────────────

  def main(args) do
    result =
      case args do
        ["duplication", file] ->
          case detect_duplication(file) do
            [] -> :ok
            dupes -> report({dupes, [], []}, file)
          end

        ["complexity", file] ->
          case analyze_complexity(file) do
            [] -> :ok
            complex -> report({[], complex, []}, file)
          end

        ["unused", file] ->
          case detect_unused(file) do
            [] -> :ok
            unused -> report({[], [], unused}, file)
          end

        ["all", file] ->
          dupes = detect_duplication(file)
          complex = analyze_complexity(file)
          unused = detect_unused(file)
          report({dupes, complex, unused}, file)

        ["scan", dir] ->
          scan_directory(dir)

        _ ->
          IO.puts("Elixir Phoenix Guide — Code Quality Analyzer")
          IO.puts("")
          IO.puts("Usage:")
          IO.puts("  elixir code_quality.exs duplication <file>  — detect duplicated functions")
          IO.puts("  elixir code_quality.exs complexity <file>   — analyze ABC complexity")
          IO.puts("  elixir code_quality.exs unused <file>       — find unused private functions")
          IO.puts("  elixir code_quality.exs all <file>          — run all checks on a file")
          IO.puts("  elixir code_quality.exs scan <directory>    — scan all .ex files in directory")
          :ok
      end

    if result == :issues_found, do: System.halt(1)
  end
end

CodeQuality.main(System.argv())
