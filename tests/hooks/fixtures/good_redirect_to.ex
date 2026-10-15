defmodule BadController do
  def go(conn, params), do: redirect(conn, to: params["next"])
end
