defmodule Predicates do
  use Phoenix.Component

  def can_edit?(user, post), do: admin?(user) or owner?(user, post)
  def load!(id), do: fetch!(id)

  def page(assigns) do
    ~H"""
    <.feed_group items={@items} />
    """
  end

  defp admin?(user), do: user.role == :admin
  defp owner?(user, post), do: user.id == post.user_id
  defp fetch!(id), do: {:ok, id}

  defp feed_group(assigns) do
    ~H"""
    <ul><li :for={item <- @items}>{item}</li></ul>
    """
  end
end
