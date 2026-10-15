defmodule BadExternalRedirect do
  use Phoenix.Controller, formats: [:html]

  def go(conn, params), do: redirect(conn, external: params["url"])
end
