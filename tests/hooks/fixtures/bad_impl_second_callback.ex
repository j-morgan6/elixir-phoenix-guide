defmodule BadSecondCallback do
  use Phoenix.LiveView

  @impl true
  def handle_event("a", _p, s), do: {:noreply, s}

  def handle_info(_msg, s), do: {:noreply, s}
end
