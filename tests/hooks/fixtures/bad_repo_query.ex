defmodule BadRepoQuery do
  alias MyApp.Repo

  def find(id), do: Repo.query!("SELECT * FROM users WHERE id = #{id}")
end
