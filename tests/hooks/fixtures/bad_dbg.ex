defmodule BadDbg do
  def total(items), do: items |> Enum.sum() |> dbg()
end
