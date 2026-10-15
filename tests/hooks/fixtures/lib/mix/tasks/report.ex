defmodule Mix.Tasks.Report do
  use Mix.Task

  @impl Mix.Task
  def run(_args), do: IO.inspect(%{ok: true})
end
