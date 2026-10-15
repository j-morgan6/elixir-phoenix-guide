defmodule Repo.Migrations.TwoRefsOneIndex do
  use Ecto.Migration

  def change do
    create table(:comments) do
      add :post_id, references(:posts, on_delete: :delete_all)
      add :author_id, references(:users, on_delete: :nilify_all)
    end

    create index(:comments, [:post_id])
  end
end
