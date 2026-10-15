defmodule GoodComments do
  @moduledoc """
  Never call String.to_atom(input) or raw(html) on user input.
  IO.inspect(x) is for debugging only; form_for( is gone.
  """

  @doc ~S"""
  Example: Repo.query!("SELECT #{id}")
  """
  def ok(x), do: x

  @doc "Avoid String.to_atom(x)."
  def also_ok(x), do: x
  # IO.inspect(x)
  # Logger.info("password #{password}")
  def trailing(x), do: x + 1 # String.to_atom(y)
end
