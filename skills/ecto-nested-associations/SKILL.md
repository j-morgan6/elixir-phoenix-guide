---
name: ecto-nested-associations
description: "Use when one form or operation manages parent and child records together — cast_assoc/cast_embed, inputs_for with sort/drop params, on_replace, Ecto.Multi across tables, FK cascade design."
---

# Ecto Nested Associations

> Verified against Elixir 1.20, Phoenix 1.8, LiveView 1.2, Ecto 3.14 — October 2026

## RULES — Follow these with no exceptions

1. **Use `cast_assoc/3` / `cast_embed/3` for children edited with their parent** — never insert children in a separate step; Ecto sets the foreign key
2. **Child changesets never cast or require the parent's foreign key** — `cast_assoc` sets it after the parent is inserted; requiring it gives "can't be blank"
3. **`on_replace` is an option on the association, not on `cast_assoc`** — `has_many :items, Item, on_replace: :delete`. The default is `:raise`: omitting an existing child from the params raises
4. **Load the parent through the scope and preload before casting** — `cast_assoc/3` raises on `%Ecto.Association.NotLoaded{}`
5. **Edit child lists from `<.inputs_for>` with `:sort_param` / `:drop_param`** — plus `on_replace: :delete`, and a `with:` function of arity 3 when order must persist
6. **`Repo.transact/2` + `with` for a fixed set of steps; `Ecto.Multi` when the steps depend on input** (one step per cart item)
7. **Never read-check-write a counter** — decrement with `update_all` guarded by `where: p.stock >= ^qty` and check the affected count is 1
8. **Choose `on_delete` deliberately** — `:delete_all` for owned children, `:nilify_all` (nullable column) to keep them, `:restrict` + `no_assoc_constraint/3` to block; the default `:nothing` also blocks the delete
9. **Index every foreign key column** — deleting a parent otherwise scans the child table

---

## Schemas for a Nested Form

```elixir
defmodule MyApp.Recipes.Recipe do
  use Ecto.Schema
  import Ecto.Changeset

  alias MyApp.Recipes.Ingredient

  schema "recipes" do
    field :name, :string
    field :user_id, :id

    has_many :ingredients, Ingredient,
      on_replace: :delete,
      preload_order: [asc: :position]

    timestamps(type: :utc_datetime)
  end

  def changeset(recipe, attrs, scope) do
    recipe
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> cast_assoc(:ingredients,
      with: &Ingredient.changeset/3,
      sort_param: :ingredients_sort,
      drop_param: :ingredients_drop
    )
    |> put_change(:user_id, scope.user.id)
  end
end

defmodule MyApp.Recipes.Ingredient do
  use Ecto.Schema
  import Ecto.Changeset

  schema "ingredients" do
    field :name, :string
    field :quantity, :string
    field :position, :integer
    belongs_to :recipe, MyApp.Recipes.Recipe

    timestamps(type: :utc_datetime)
  end

  # Arity 3: cast_assoc passes the item's final position (nil when it is being replaced).
  # This third argument is the position, not the 1.8 scope; children get ownership via the parent.
  def changeset(ingredient, attrs, position) do
    ingredient
    |> cast(attrs, [:name, :quantity])
    |> validate_required([:name])
    |> change(position: position)
  end
end
```

<!-- epg:bad -->
```elixir
# Child changeset that casts and requires the parent FK: "recipe_id can't be blank" on create,
# and a client could re-parent an ingredient onto someone else's recipe
def changeset(ingredient, attrs) do
  ingredient
  |> cast(attrs, [:name, :quantity, :recipe_id])
  |> validate_required([:name, :recipe_id])
end
```

<!-- epg:bad -->
```elixir
# on_replace is not a cast_assoc option — the association keeps its :raise default
|> cast_assoc(:ingredients, on_replace: :delete)
```

## Context: Create and Update

```elixir
def get_recipe!(%Scope{} = scope, id) do
  Recipe
  |> Repo.get_by!(id: id, user_id: scope.user.id)
  |> Repo.preload(:ingredients)
end

# A new %Recipe{} needs no preload — built structs cast children against []
def create_recipe(%Scope{} = scope, attrs) do
  %Recipe{}
  |> Recipe.changeset(attrs, scope)
  |> Repo.insert()
end

def update_recipe(%Scope{} = scope, %Recipe{} = recipe, attrs) do
  true = recipe.user_id == scope.user.id

  recipe
  |> Repo.preload(:ingredients)
  |> Recipe.changeset(attrs, scope)
  |> Repo.update()
end
```

With `on_replace: :delete`, children are matched by `id`: given ingredients A, B, C and params `%{"ingredients" => [%{"id" => a.id, "name" => "A2"}, %{"name" => "D"}]}`, A is updated, B and C are deleted, D is inserted.

<!-- epg:bad -->
```elixir
recipe = Repo.get_by!(Recipe, id: id, user_id: scope.user.id)
# ingredients is %Ecto.Association.NotLoaded{} — cast_assoc inside Recipe.changeset/3 raises
# "attempting to cast or change association `ingredients` ... that was not loaded",
# before Repo.update/1 is ever called
recipe |> Recipe.changeset(attrs, scope) |> Repo.update()
```

## Editing Child Lists with `<.inputs_for>`

The supported way to add, remove and reorder children from a LiveView form. Ecto reads `ingredients_sort` / `ingredients_drop` from the params (names must match the `cast_assoc` options):

```heex
<.form for={@form} id="recipe-form" phx-change="validate" phx-submit="save">
  <.input field={@form[:name]} type="text" label="Name" />

  <.inputs_for :let={f_ing} field={@form[:ingredients]}>
    <input type="hidden" name="recipe[ingredients_sort][]" value={f_ing.index} />
    <.input field={f_ing[:name]} type="text" placeholder="Ingredient" />
    <.input field={f_ing[:quantity]} type="text" placeholder="Quantity" />
    <button
      type="button"
      name="recipe[ingredients_drop][]"
      value={f_ing.index}
      phx-click={JS.dispatch("change")}
    >
      Remove
    </button>
  </.inputs_for>

  <input type="hidden" name="recipe[ingredients_drop][]" />

  <button
    type="button"
    name="recipe[ingredients_sort][]"
    value="new"
    phx-click={JS.dispatch("change")}
  >
    Add ingredient
  </button>

  <.button phx-disable-with="Saving...">Save</.button>
</.form>
```

- `value="new"` in the sort param appends an empty child; a dropped index removes that child. `JS.dispatch("change")` routes the click through `phx-change`, so the `validate` handler re-renders the list — no add/remove events needed.
- The empty hidden `..._drop[]` input outside `inputs_for` is required: without it, removing the last child sends no `ingredients` key and nothing is deleted.
- Both buttons need `type="button"`, or they submit the form.
- `:drop_param` requires `on_replace: :delete` on the association. For `has_many`, persisted order needs the `position` field set by the arity-3 `with:` (embeds keep list order on their own).

## cast_embed for Embedded Schemas

Same API, stored as JSON in one column (no table, no foreign key):

```elixir
defmodule MyApp.Profiles.Profile do
  use Ecto.Schema
  import Ecto.Changeset

  alias MyApp.Profiles.SocialLink

  schema "profiles" do
    field :name, :string
    embeds_many :social_links, SocialLink, on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [:name])
    |> cast_embed(:social_links,
      with: &SocialLink.changeset/2,
      sort_param: :social_links_sort,
      drop_param: :social_links_drop
    )
  end
end

defmodule MyApp.Profiles.SocialLink do
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

## Multi-Table Writes: `Repo.transact` or `Ecto.Multi`

For a fixed sequence of steps, a `with` inside `Repo.transact/2` is simpler (see the `ecto-essentials` skill). `Ecto.Multi` earns its place when the number of steps depends on the input — here, one stock reservation per cart line:

```elixir
defmodule MyApp.Orders do
  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias MyApp.Accounts.Scope
  alias MyApp.Catalog.Product
  alias MyApp.Orders.{LineItem, Order}
  alias MyApp.Repo

  # cart_items: [%{product_id: id, quantity: qty}] — prices are read from the database
  def place_order(%Scope{} = scope, cart_items) do
    Multi.new()
    |> Multi.insert(:order, Order.changeset(%Order{}, %{}, scope))
    |> reserve_stock(cart_items)
    |> Multi.insert_all(:line_items, LineItem, &line_item_rows/1)
    |> Repo.transact()
  end

  defp reserve_stock(multi, cart_items) do
    cart_items
    |> Enum.with_index()
    |> Enum.reduce(multi, fn {%{product_id: product_id, quantity: qty}, i}, multi ->
      Multi.run(multi, {:reserve, i}, fn repo, _changes -> reserve(repo, product_id, qty) end)
    end)
  end

  defp reserve(_repo, _product_id, qty) when not is_integer(qty) or qty <= 0,
    do: {:error, :invalid_quantity}

  defp reserve(repo, product_id, qty) do
    query =
      from p in Product,
        where: p.id == ^product_id and p.stock >= ^qty,
        select: p.price

    # Check and decrement in one statement: no row matches when stock is short,
    # so two concurrent orders can't both take the last item
    case repo.update_all(query, inc: [stock: -qty]) do
      {1, [price]} -> {:ok, %{product_id: product_id, quantity: qty, price: price}}
      {0, _} -> {:error, :insufficient_stock}
    end
  end

  defp line_item_rows(%{order: order} = changes) do
    now = DateTime.utc_now(:second)

    for {{:reserve, _}, item} <- changes do
      Map.merge(item, %{order_id: order.id, inserted_at: now, updated_at: now})
    end
  end
end
```

Handling the result — a failed Multi returns `{:error, step_name, value, changes_so_far}` and nothing is committed:

```elixir
case Orders.place_order(scope, cart_items) do
  {:ok, %{order: order}} -> {:ok, order}
  {:error, :order, %Ecto.Changeset{} = changeset, _changes} -> {:error, changeset}
  {:error, {:reserve, _index}, reason, _changes} -> {:error, reason}
end
```

<!-- epg:bad -->
```elixir
# Race: two requests both read stock = 1, both pass, both decrement → stock = -1
|> Multi.run(:check, fn _repo, _ -> if sufficient_stock?(items), do: {:ok, :ok}, else: {:error, :out} end)
|> Multi.update(:decrement_stock, fn _ -> decrement_stock_changeset(items) end)
```

- `insert_all`/`update_all` skip changesets and autogenerated timestamps — set `inserted_at`/`updated_at` yourself (`DateTime` for `:utc_datetime` schemas).
- They also don't turn constraint violations into errors: a bad foreign key in `insert_all` **raises** `Postgrex.Error` out of `Repo.transact/2` rather than returning `{:error, ...}`. Make failures you expect go through a step that returns `{:error, reason}`, as `reserve/3` does.
- Duplicate step names raise, which is why the steps are keyed `{:reserve, index}`.

## Foreign Keys and `on_delete`

```elixir
defmodule MyApp.Repo.Migrations.CreateComments do
  use Ecto.Migration

  def change do
    create table(:comments) do
      add :body, :text, null: false

      # Owned child — deleted with its post
      add :post_id, references(:posts, on_delete: :delete_all), null: false

      # Author — the comment survives account deletion without an author (column must be nullable)
      add :user_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:comments, [:post_id])
    create index(:comments, [:user_id])
  end
end
```

| `on_delete` | Deleting the parent… | Use for |
|---|---|---|
| `:delete_all` | deletes the children | Owned children: line items, ingredients, replies |
| `:nilify_all` | sets the FK to `NULL` (column must allow it) | Keep the child, drop the link: author, team |
| `:restrict` | fails while children exist | Parents that must be emptied first: a category with posts |
| `:nothing` (default) | **also fails** while children exist (`NO ACTION`, checked at statement end) | Rarely what you want — it does not "keep" the children |

To make a blocked delete a form error instead of an `Ecto.ConstraintError`, declare it on the parent's delete changeset:

```elixir
def delete_category(%Scope{} = scope, %Category{} = category) do
  true = category.user_id == scope.user.id

  category
  |> Ecto.Changeset.change()
  |> Ecto.Changeset.no_assoc_constraint(:posts)
  |> Repo.delete()
end
# => {:error, changeset} with posts: "are still associated with this entry"
```

## Foreign Key Indexes

`references/2` creates the constraint but **not** an index. Postgres checks child rows on every parent delete, so without `create index(:comments, [:post_id])` each delete scans the whole `comments` table.

## Testing Nested Associations

Test the rollback through a step that returns an error:

```elixir
describe "place_order/2" do
  test "rolls back the order when stock runs out" do
    scope = user_scope_fixture()
    product = product_fixture(stock: 1)

    assert {:error, {:reserve, 0}, :insufficient_stock, _changes} =
             Orders.place_order(scope, [%{product_id: product.id, quantity: 2}])

    assert Repo.aggregate(Order, :count) == 0
    assert Repo.reload!(product).stock == 1
  end
end
```

A bad foreign key in an `insert_all` step raises; test that with `assert_raise Postgrex.Error, fn -> ... end`, not by matching `{:error, _, _, _}`.

---

See the `ecto-essentials` skill for scoped contexts, transactions and migrations.
See the `ecto-changeset-patterns` skill for changeset composition and validation.
See the `testing-essentials` skill for comprehensive testing patterns.
