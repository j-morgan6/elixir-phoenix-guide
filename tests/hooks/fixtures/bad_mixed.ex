defmodule BadMixed do
  def go(conn, params), do: redirect(conn, external: params["next"])
  def name(x), do: String.to_atom(x)
end
