---
name: ecto-nested-associations
description: MANDATORY for ALL nested association and multi-table work. Invoke before writing cast_assoc, cast_embed, Ecto.Multi, or cascade operations.
file_patterns:
  - "**/*.ex"
auto_suggest: true
---

# Ecto Nested Associations

## RULES — Follow these with no exceptions

1. **Use `cast_assoc/3` for has_many/has_one** — never manually insert children in a separate step; let Ecto manage the relationship
2. **Use `Ecto.Multi` for operations spanning multiple unrelated tables** — not nested changesets; Multi provides explicit rollback control
3. **Set `on_delete` explicitly in migrations** — `:delete_all` for owned children, `:nothing` for references to independent entities
4. **Always create indexes on foreign key columns** — missing FK indexes cause slow joins and lookups on the child table
5. **Use `on_replace: :delete` in `cast_assoc` for list management** — allows removing items by omitting them from the input
6. **Preload associations before updating them** — `cast_assoc` compares against currently loaded data; unloaded associations cause silent data loss

---

## cast_assoc for Nested Creates

Create parent and children in a single operation. Ecto sets foreign keys automatically.

```elixir
# Schema definitions
defmodule MyApp.Blog.Post do
  use Ecto.Schema
  import Ecto.Changeset

  schema "posts" do
    field :title, :string
    has_many :comments, MyApp.Blog.Comment

    timestamps()
  end

  def changeset(post, attrs) do
    post
    |> cast(attrs, [:title])
    |> validate_required([:title])
    |> cast_assoc(:comments, with: &MyApp.Blog.Comment.changeset/2)
  end
end

defmodule MyApp.Blog.Comment do
  use Ecto.Schema
  import Ecto.Changeset

  schema "comments" do
    field :body, :string
    belongs_to :post, MyApp.Blog.Post

    timestamps()
  end

  # Do NOT require :post_id — cast_assoc sets it automatically
  def changeset(comment, attrs) do
    comment
    |> cast(attrs, [:body])
    |> validate_required([:body])
  end
end

# Usage — create post with comments in one operation
Blog.create_post(%{
  title: "My Post",
  comments: [
    %{body: "First comment"},
    %{body: "Second comment"}
  ]
})
```

---

## cast_assoc for Updates with on_replace

When updating a has_many, `on_replace: :delete` removes children that are omitted from the input.

```elixir
defmodule MyApp.Recipes.Recipe do
  schema "recipes" do
    field :name, :string
    has_many :ingredients, MyApp.Recipes.Ingredient, on_replace: :delete

    timestamps()
  end

  def changeset(recipe, attrs) do
    recipe
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> cast_assoc(:ingredients, with: &MyApp.Recipes.Ingredient.changeset/2)
  end
end

# Update — send the full list; omitted items are deleted
def update_recipe(recipe, attrs) do
  recipe
  |> Repo.preload(:ingredients)  # MUST preload before cast_assoc
  |> Recipe.changeset(attrs)
  |> Repo.update()
end

# Example: recipe has ingredients A, B, C
# Sending %{ingredients: [%{id: a.id, name: "A"}, %{name: "D"}]}
# Result: A is updated, B and C are deleted, D is created
```

### Why Preloading Matters

```elixir
# Bad — ingredients not preloaded, cast_assoc can't compare
recipe = Repo.get!(Recipe, id)
Recipe.changeset(recipe, attrs)  # ingredients is %Ecto.Association.NotLoaded{}
|> Repo.update()  # Silently ignores association changes!

# Good — preload before updating
recipe = Repo.get!(Recipe, id) |> Repo.preload(:ingredients)
Recipe.changeset(recipe, attrs)  # ingredients is [%Ingredient{}, ...]
|> Repo.update()  # Correctly diffs and applies changes
```

---

## cast_embed for Embedded Schemas

Use `cast_embed` for data stored as JSON in a single column (no separate table).

```elixir
defmodule MyApp.Profiles.Profile do
  use Ecto.Schema
  import Ecto.Changeset

  schema "profiles" do
    field :name, :string
    embeds_many :social_links, SocialLink, on_replace: :delete

    timestamps()
  end

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [:name])
    |> cast_embed(:social_links, with: &SocialLink.changeset/2)
  end
end

defmodule MyApp.Profiles.Profile.SocialLink do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :platform, :string
    field :url, :string
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:platform, :url])
    |> validate_required([:platform, :url])
    |> validate_format(:url, ~r/^https?:\/\//)
  end
end
```

---

## Ecto.Multi for Multi-Table Operations

When operations span unrelated tables or need explicit control over transaction steps:

```elixir
defmodule MyApp.Orders do
  alias Ecto.Multi

  def place_order(user, cart_items) do
    Multi.new()
    |> Multi.insert(:order, build_order(user))
    |> Multi.insert_all(:line_items, LineItem, fn %{order: order} ->
      Enum.map(cart_items, fn item ->
        %{
          order_id: order.id,
          product_id: item.product_id,
          quantity: item.quantity,
          price: item.price,
          inserted_at: DateTime.utc_now(:second),
          updated_at: DateTime.utc_now(:second)
        }
      end)
    end)
    |> Multi.update(:decrement_stock, fn %{order: _order} ->
      decrement_stock_changeset(cart_items)
    end)
    |> Repo.transaction()
  end
end

# Handling Multi results
case Orders.place_order(user, cart_items) do
  {:ok, %{order: order, line_items: {count, _}, decrement_stock: _}} ->
    # All operations succeeded
    {:ok, order}

  {:error, :order, changeset, _changes_so_far} ->
    # Order insert failed — nothing committed
    {:error, changeset}

  {:error, :decrement_stock, changeset, _changes_so_far} ->
    # Stock update failed — order and line items rolled back
    {:error, changeset}
end
```

### Multi with Run for Custom Logic

```elixir
Multi.new()
|> Multi.run(:validate_stock, fn _repo, _changes ->
  if sufficient_stock?(cart_items) do
    {:ok, :valid}
  else
    {:error, :insufficient_stock}
  end
end)
|> Multi.insert(:order, fn %{validate_stock: :valid} ->
  build_order(user)
end)
|> Repo.transaction()
```

---

## Migration Patterns for Associations

### Foreign Keys with Cascade

```elixir
defmodule MyApp.Repo.Migrations.CreateComments do
  use Ecto.Migration

  def change do
    create table(:comments) do
      add :body, :text, null: false

      # Child — cascade delete when parent is deleted
      add :post_id, references(:posts, on_delete: :delete_all), null: false

      # Reference — don't cascade (user deletion shouldn't delete comments)
      add :user_id, references(:users, on_delete: :nothing), null: false

      timestamps()
    end

    # Always index foreign keys
    create index(:comments, [:post_id])
    create index(:comments, [:user_id])
  end
end
```

### Cascade Decision Guide

```elixir
# :delete_all — child cannot exist without parent
add :comment_id, references(:comments, on_delete: :delete_all)  # Reply → Comment
add :line_item_id, references(:orders, on_delete: :delete_all)  # LineItem → Order
add :ingredient_id, references(:recipes, on_delete: :delete_all)  # Ingredient → Recipe

# :nothing — resource is referenced but independent
add :user_id, references(:users, on_delete: :nothing)  # Post → User
add :category_id, references(:categories, on_delete: :nothing)  # Post → Category

# :nilify_all — remove reference but keep the record
add :team_id, references(:teams, on_delete: :nilify_all)  # User → Team (user keeps account)
```

---

## Foreign Key Indexes

Every `references()` column needs an index. Without it, deleting a parent scans the entire child table.

```elixir
# Bad — foreign key without index
create table(:comments) do
  add :post_id, references(:posts, on_delete: :delete_all)
end
# Deleting a post requires full table scan of comments to find children

# Good — always add an index
create table(:comments) do
  add :post_id, references(:posts, on_delete: :delete_all)
end
create index(:comments, [:post_id])
```

---

## Testing Nested Associations

```elixir
describe "create_post/1 with comments" do
  test "creates post with nested comments" do
    attrs = %{
      title: "My Post",
      comments: [
        %{body: "Comment 1"},
        %{body: "Comment 2"}
      ]
    }

    assert {:ok, post} = Blog.create_post(attrs)
    assert post.title == "My Post"

    post = Repo.preload(post, :comments)
    assert length(post.comments) == 2
    assert Enum.any?(post.comments, &(&1.body == "Comment 1"))
  end

  test "rejects invalid nested comments" do
    attrs = %{
      title: "My Post",
      comments: [%{body: nil}]
    }

    assert {:error, changeset} = Blog.create_post(attrs)
    assert errors_on(changeset)[:comments]
  end
end

describe "update_recipe/2 with on_replace: :delete" do
  test "removes omitted ingredients" do
    recipe = recipe_fixture(ingredients: [%{name: "Salt"}, %{name: "Pepper"}])
    recipe = Repo.preload(recipe, :ingredients)

    # Only send Salt — Pepper should be deleted
    attrs = %{ingredients: [%{id: hd(recipe.ingredients).id, name: "Salt"}]}
    assert {:ok, updated} = Recipes.update_recipe(recipe, attrs)

    updated = Repo.preload(updated, :ingredients, force: true)
    assert length(updated.ingredients) == 1
    assert hd(updated.ingredients).name == "Salt"
  end
end

describe "place_order/2 with Ecto.Multi" do
  test "creates order and line items atomically" do
    user = user_fixture()
    product = product_fixture(stock: 10)
    items = [%{product_id: product.id, quantity: 2, price: 999}]

    assert {:ok, %{order: order, line_items: {1, _}}} =
             Orders.place_order(user, items)

    assert order.user_id == user.id
  end

  test "rolls back on failure" do
    user = user_fixture()
    items = [%{product_id: -1, quantity: 2, price: 999}]

    assert {:error, _step, _changeset, _changes} =
             Orders.place_order(user, items)
  end
end
```

---

See `ecto-essentials` skill for schema and migration fundamentals.
See `ecto-changeset-patterns` skill for changeset composition and validation.
See `testing-essentials` skill for comprehensive testing patterns.
