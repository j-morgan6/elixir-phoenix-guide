defmodule BadSQL do
  def find(id) do
    Ecto.Adapters.SQL.query!(Repo, "SELECT * FROM users WHERE id = #{id}")
  end
end
