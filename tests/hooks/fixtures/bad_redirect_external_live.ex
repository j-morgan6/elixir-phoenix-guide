defmodule BadExternalRedirectLive do
  use Phoenix.LiveView

  @impl true
  def handle_event("leave", params, socket) do
    {:noreply, redirect(socket, external: params["return_to"])}
  end
end
