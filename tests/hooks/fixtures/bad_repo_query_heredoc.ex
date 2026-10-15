defmodule BadRepoQueryHeredoc do
  alias MyApp.Repo

  def search(term) do
    Repo.query("""
    SELECT id FROM posts
    WHERE title ILIKE '%#{term}%'
    """)
  end
end
