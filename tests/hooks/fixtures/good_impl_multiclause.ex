defmodule GoodMultiClause do
  use Phoenix.LiveView

  @impl true
  def handle_event("a", _p, s), do: {:noreply, s}

  def handle_event("b", _p, s), do: {:noreply, s}

  # trailing clause after a comment
  def handle_event("c", _p, s), do: {:noreply, s}

  @impl true
  @doc false
  def handle_info(:tick, s), do: {:noreply, s}

  def handle_info(_msg, s) do
    {:noreply, s}
  end
end
