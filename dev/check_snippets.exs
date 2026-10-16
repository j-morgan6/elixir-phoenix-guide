# Maintainer tool: syntax-checks every fenced ```elixir and ```heex block in
# skills/ (SKILL.md and supporting files) and flags patterns that regressed
# before (pre-1.8 names, removed APIs).
#
# Blocks preceded by `<!-- epg:bad -->` (deliberately bad examples) are skipped
# for both checks.
#
# HEEx blocks need Phoenix LiveView on the code path, so run this from inside
# a Phoenix 1.8 app:
#
#     mix phx.new ci_app --no-install && cd ci_app && mix deps.get
#     mix run --no-start /path/to/elixir-phoenix-guide/dev/check_snippets.exs /path/to/elixir-phoenix-guide
#
# Without LiveView loaded (plain `elixir dev/check_snippets.exs .`), HEEx
# blocks are skipped with a notice and only Elixir blocks are checked; set
# EPG_REQUIRE_HEEX=1 (as CI does) to make that an error instead.
#
# This parses snippets; it does not compile them against real modules.

defmodule EPG.CheckSnippets do
  # {regex, message}. Checked on every line outside epg:bad blocks.
  @forbidden [
    # The plug and live_session keep the _user name; only the hook changed.
    {~r/on_mount\(:require_authenticated_user|UserAuth, :require_authenticated_user\}/,
     "Phoenix 1.8 on_mount hook is :require_authenticated"},
    {~r/text_to_html/, "removed in phoenix_html 4"},
    {~r/<\.label[\s>]/, "Phoenix 1.8 core_components has no label/1"},
    {~r/<\.simple_form/, "simple_form was removed from 1.8 core_components"},
    {~r/Repo\.transaction\(/, "use Repo.transact/2 (Ecto 3.13+)"},
    {~r/~p"\/(login|register)"/, "Phoenix 1.8 auth routes are /users/log-in and /users/register"},
    {~r/live_redirect\(|live_patch\(|<\.live_(redirect|patch)/, "removed; use <.link navigate/patch> or push_navigate/push_patch"},
    {~r/<%= for /, "use the :for attribute"},
    {~r/config :logger, :console/, "ignored when :default_formatter is set (Phoenix 1.8 config)"}
  ]

  # {regex, message}. Checked against each whole elixir/heex block body.
  @forbidden_in_block [
    # <.header> has a real :actions slot; only <.form> lacks one.
    {~r/<\.form\b(?:(?!<\/\.form>).)*<:actions>/s,
     "<.form> has no :actions slot; put <.button> inside the form"}
  ]

  def run([root]) do
    files =
      Path.wildcard(Path.join(root, "skills/**/*.md"))
      |> Enum.sort()

    heex? = Code.ensure_loaded?(Phoenix.LiveView.TagEngine)

    cond do
      heex? ->
        :ok

      System.get_env("EPG_REQUIRE_HEEX") == "1" ->
        IO.puts(:stderr, "Phoenix LiveView not loaded but EPG_REQUIRE_HEEX=1 — run from a Phoenix app")
        System.halt(2)

      true ->
        IO.puts("note: Phoenix LiveView not loaded — skipping HEEx blocks")
    end

    errors = Enum.flat_map(files, &check_file(&1, root, heex?))

    Enum.each(errors, &IO.puts/1)
    IO.puts("\n#{length(files)} files, #{length(errors)} problem(s)")
    if errors != [], do: System.halt(1)
  end

  def run(_) do
    IO.puts(:stderr, "usage: check_snippets.exs <repo_root>")
    System.halt(2)
  end

  defp check_file(path, root, heex?) do
    rel = Path.relative_to(path, root)
    lines = path |> File.read!() |> String.split("\n")

    {blocks, bad_ranges, code_ranges} = blocks(lines)

    block_errors =
      for {lang, start, body} <- blocks,
          error = check_block(lang, body, heex?),
          do: "#{rel}:#{start}: #{lang} block does not parse: #{error}"

    block_pattern_errors =
      for {lang, start, body} <- blocks,
          {re, msg} <- @forbidden_in_block,
          Regex.match?(re, body),
          do: "#{rel}:#{start}: #{lang} block: #{msg}"

    pattern_errors =
      for {line, n} <- Enum.with_index(lines, 1),
          Enum.any?(code_ranges, &(n in &1)),
          not Enum.any?(bad_ranges, &(n in &1)),
          {re, msg} <- @forbidden,
          Regex.match?(re, line),
          do: "#{rel}:#{n}: #{msg}: #{String.trim(line)}"

    block_errors ++ block_pattern_errors ++ pattern_errors
  end

  # Returns {[{lang, start_line, body}], [bad_line_range], [code_line_range]}.
  # Pattern rules only apply inside fenced code, so prose may name bad APIs.
  defp blocks(lines) do
    indexed = Enum.with_index(lines, 1)

    {blocks, bad, code, _state} =
      Enum.reduce(indexed, {[], [], [], nil}, fn {line, n}, {blocks, bad, code, state} ->
        trimmed = String.trim(line)

        case state do
          nil ->
            case Regex.run(~r/^```(\w+)/, trimmed) do
              [_, lang] -> {blocks, bad, code, {lang, n, [], bad_marker?(lines, n)}}
              _ -> {blocks, bad, code, nil}
            end

          {lang, start, acc, bad?} ->
            if String.starts_with?(trimmed, "```") do
              body = acc |> Enum.reverse() |> Enum.join("\n")
              bad = if bad?, do: [start..n | bad], else: bad

              blocks =
                if not bad? and lang in ["elixir", "heex"],
                  do: [{lang, start, body} | blocks],
                  else: blocks

              {blocks, bad, [start..n | code], nil}
            else
              {blocks, bad, code, {lang, start, [line | acc], bad?}}
            end
        end
      end)

    {Enum.reverse(blocks), bad, code}
  end

  defp bad_marker?(lines, fence_line) do
    lines
    |> Enum.take(fence_line - 1)
    |> Enum.reverse()
    |> Enum.find(&(String.trim(&1) != ""))
    |> case do
      nil -> false
      prev -> String.trim(prev) == "<!-- epg:bad -->"
    end
  end

  defp check_block("elixir", body, _heex?) do
    case Code.string_to_quoted(body, columns: true) do
      {:ok, _} -> nil
      {:error, {meta, msg, token}} -> "line #{meta[:line]}: #{format(msg)}#{token}"
    end
  end

  defp check_block("heex", _body, false), do: nil

  defp check_block("heex", body, true) do
    Phoenix.LiveView.TagEngine.compile(body,
      file: "snippet.heex",
      line: 1,
      caller: __ENV__,
      indentation: 0,
      tag_handler: Phoenix.LiveView.HTMLEngine
    )

    nil
  rescue
    e -> e |> Exception.message() |> String.split("\n") |> hd()
  end

  defp format({a, b}), do: "#{a}#{b}"
  defp format(msg), do: to_string(msg)
end

EPG.CheckSnippets.run(System.argv())
