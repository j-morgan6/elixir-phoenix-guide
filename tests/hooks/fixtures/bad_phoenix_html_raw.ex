defmodule BadPhoenixHtmlRaw do
  def render_bio(user), do: Phoenix.HTML.raw(user.bio)
end
