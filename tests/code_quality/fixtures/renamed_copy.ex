defmodule Reports.Daily do
  def summarize(rows) do
    totals = Enum.reduce(rows, %{count: 0, sum: 0}, fn row, acc ->
      %{acc | count: acc.count + 1, sum: acc.sum + row.amount}
    end)

    average = if totals.count > 0, do: totals.sum / totals.count, else: 0
    %{total: totals.sum, average: Float.round(average * 1.0, 2), label: "daily"}
  end
end

defmodule Reports.Weekly.Helpers do
  def build_week_summary(entries) do
    acc0 = Enum.reduce(entries, %{count: 0, sum: 0}, fn e, a ->
      %{a | count: a.count + 1, sum: a.sum + e.amount}
    end)

    avg = if acc0.count > 0, do: acc0.sum / acc0.count, else: 0
    %{total: acc0.sum, average: Float.round(avg * 1.0, 3), label: "weekly"}
  end
end
