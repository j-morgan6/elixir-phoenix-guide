defmodule SomeDep.Bad do
  def go(x), do: String.to_atom(x) |> IO.inspect()
end
