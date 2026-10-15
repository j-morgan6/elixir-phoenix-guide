defmodule GoodRepoQuery do
  alias MyApp.Repo
  @table "posts"

  def find(id), do: Repo.query!("SELECT * FROM users WHERE id = $1", [id])
  def count, do: Repo.query!("SELECT count(*) FROM #{@table}")
  def like(term), do: Repo.query!("SELECT id FROM posts WHERE title ILIKE $1", ["%#{term}%"])
end
