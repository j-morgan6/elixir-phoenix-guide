defmodule Complex do
  def classify(a, b, c) do
    cond do
      a > 10 and b > 10 -> :both_big
      a > 10 or b > 10 -> :one_big
      c == :x && a == b -> :same
      c == :y || a < 0 -> :odd
      true ->
        case {a, b} do
          {0, 0} -> :zero
          {0, _} -> :left_zero
          {_, 0} -> :right_zero
          _ ->
            if a > b do
              :left
            else
              unless a == b, do: :right, else: :tie
            end
        end
    end
  end
end
