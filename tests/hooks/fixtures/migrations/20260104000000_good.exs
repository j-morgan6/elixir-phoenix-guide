defmodule Repo.Migrations.Good do
  use Ecto.Migration

  def change do
    create table(:comments) do
      add :post_id, references(:posts, on_delete: :delete_all)
      add :author_id,
          references(:users,
            on_delete: :nilify_all
          )
    end

    create index(:comments, [:post_id])
    create unique_index(:comments, [:author_id, :post_id])
  end
end
