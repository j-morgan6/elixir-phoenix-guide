---
name: phoenix-scopes-and-generators
description: "Use when running phx.gen.live/html/json/context with scopes (--scope, --no-scope), editing config :my_app, :scopes, extending the %Scope{} struct with an org, or adopting scopes in a pre-1.8 app. Not for login plumbing (phoenix-liveview-auth) or permission rules (phoenix-authorization-patterns)."
---

# Phoenix Scopes and Generators

> Verified against Elixir 1.20, Phoenix 1.8, LiveView 1.2, Ecto 3.14 — October 2026

## RULES — Follow these with no exceptions

1. **Check `config :my_app, :scopes` before generating.** Generators read it at mix-task time; with no default entry (no `phx.gen.auth` yet) they silently emit unscoped contexts with no PubSub topic and no owner column. Run `phx.gen.auth` first, or add the entry.
2. **Take the default scope unless the data is truly global.** `--no-scope` (lookup tables, public content) drops the scope argument, the owner column, the `subscribe_*/broadcast_*` functions and the cross-scope tests. `--scope name` only accepts a configured entry, and combining the two flags raises.
3. **Don't pass the owner as a field.** With the default scope, `user_id:references:users` aborts the generator ("same name as the scope schema key"); the scope already adds `field :user_id` and the migration column.
4. **Keep the generated ownership checks.** `update_*`, `delete_*` and `change_*` all start with `true = post.user_id == scope.user.id`. A hand-written "new" form must build `%Post{user_id: scope.user.id}`, or `change_post/2` raises `MatchError`.
5. **Extend the one `Scope` struct; don't add a second assign.** Add fields (`org`, `org_role`) plus a builder (`put_org/3`), and a second config entry that points at the **same** `module` and `assign_key` with a different `access_path` and `schema_key`.
6. **Fill extra scope fields with a plug *and* an `on_mount` hook.** The plug covers the HTTP render and controllers; the hook covers the websocket mount and live navigation. Both look up membership through the current scope and never trust the slug alone.
7. **Write the test helpers before generating against a new entry.** Generated tests call `<name>_scope_fixture/0` from `test_data_fixture` and `setup :<test_setup_helper>`. Both must exist, and the setup helper must return `scope:`.
8. **Scoped controllers need a pipeline that assigns the scope.** `phx.gen.json` output reads `conn.assigns.current_scope`, but the generated `:api` pipeline never sets it, so every action fails with `KeyError`.
9. **Pass the scope down; never rebuild it from params.** Contexts pass it to other contexts. Background jobs store ids and rebuild it in `perform/1`.
10. **Adopt scopes in a pre-1.8 app in this order:** Scope module, then config, then assign `:current_scope`, then test helpers, then owner columns, then generate or convert contexts one at a time.

---

## The Two Pieces `phx.gen.auth` Adds

`lib/my_app/accounts/scope.ex` is a plain struct with `for_user/1` (`nil` in gives `nil` out; guests have no scope). Its moduledoc asks you to extend it. The config entry tells every later generator how to use it:

```elixir
config :my_app, :scopes,
  user: [
    default: true,
    module: MyApp.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: MyApp.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]
```

Keys accepted by `Mix.Phoenix.Scope` (an unknown key raises):

| Key | Drives |
|---|---|
| `default` | used when no flag is given; only one entry may be `true` (more raises) |
| `module` | the struct pattern-matched in context heads (`%Scope{} = scope`) |
| `assign_key` | `socket.assigns.current_scope` / `conn.assigns.current_scope` in generated web code |
| `access_path` | the owner value: `[:user, :id]` becomes `scope.user.id` in queries, `put_change` and topics |
| `schema_key` | the owner field added to the schema and migration (`:user_id`) |
| `schema_type` | that field's type (`:id`, `:binary_id`) |
| `schema_table` | `references(:users, on_delete: :delete_all)`; `nil` gives a plain column with no FK |
| `schema_migration_type` | overrides the migration column type (defaults to `schema_type` unless it is `:id`) |
| `route_prefix` | e.g. `"/orgs/:org_slug"`, prepended to every generated path; at most one `:param` |
| `route_access_path` | what fills that param, e.g. `[:org, :slug]` (defaults to `access_path` minus its last element) |
| `test_data_fixture` | the module generated tests import `<name>_scope_fixture/0` from |
| `test_setup_helper` | the `setup :helper` in generated LiveView and controller tests |

The **entry name** (`user`, `org`) is also the PubSub topic prefix (`"user:#{key}:posts"`) and the changeset's argument name (`user_scope`). The config must be in `config/config.exs` (or a file it imports). Generators never load `runtime.exs`.

`phx.gen.auth` takes `--scope name` and `--assign-key key` to rename its entry. It marks the entry `default: true` only if no default exists yet.

---

## Running the Generators

| Command | Result |
|---|---|
| `mix phx.gen.live Blog Post posts title:string` | default scope |
| `mix phx.gen.live Projects Project projects name:string --scope org` | the `org` entry |
| `mix phx.gen.html Pages Page pages title:string --no-scope` | unscoped |
| `--scope missing` | `** (Mix) Scope :missing not configured!` |

`phx.gen.live`, `phx.gen.html`, `phx.gen.json`, `phx.gen.context` and `phx.gen.schema` all take `--scope` / `--no-scope`.

A scoped run changes these files:

- **Schema:** `field :user_id, :id` (not `belongs_to`) and `changeset(post, attrs, user_scope)`, which casts only your fields and ends with `put_change(:user_id, user_scope.user.id)`.
- **Migration:** `add :user_id, references(:users, on_delete: :delete_all)` and `create index(:posts, [:user_id])`.
- **Context:** every function takes `%Scope{}` first. `list_*` uses `Repo.all_by(Post, user_id: ...)` and `get_*!` uses `Repo.get_by!(Post, id: id, user_id: ...)`. Writes assert ownership and broadcast `{:created | :updated | :deleted, post}` on `"user:#{scope.user.id}:posts"` (the full module is in the `phoenix-pubsub-patterns` skill).
- **LiveViews and controllers:** every context call passes `socket.assigns.current_scope`, and layouts get `current_scope={@current_scope}`. The router hint ends with *"Ensure the routes are defined in a block that sets the `:current_scope` assign"*.
- **Tests and fixtures:** `post_fixture(scope, attrs \\ %{})` and `setup :register_and_log_in_user`. Context tests create posts under two `user_scope_fixture()` scopes and assert that `get_post!(other_scope, id)` raises `Ecto.NoResultsError`.

Put generated LiveView routes in the existing authenticated `live_session` (see the `phoenix-liveview-auth` skill).

---

## Adding an Org to the Scope

The plumbing for org-owned data. Roles, policies and who may do what are covered in the `phoenix-authorization-patterns` skill.

### 1. Struct and builder

```elixir
defmodule MyApp.Accounts.Scope do
  alias MyApp.Accounts.User
  alias MyApp.Orgs.Org

  defstruct user: nil, org: nil, org_role: nil

  def for_user(%User{} = user), do: %__MODULE__{user: user}
  def for_user(nil), do: nil

  def put_org(%__MODULE__{} = scope, %Org{} = org, role) do
    %{scope | org: org, org_role: role}
  end
end
```

### 2. A second config entry for the generators

```elixir
config :my_app, :scopes,
  user: [
    default: true,
    # ... unchanged
  ],
  org: [
    module: MyApp.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:org, :id],
    route_prefix: "/orgs/:org_slug",
    route_access_path: [:org, :slug],
    schema_key: :org_id,
    schema_type: :id,
    schema_table: :orgs,
    test_data_fixture: MyApp.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user_with_org
  ]
```

### 3. Fill it: plug + on_mount

```elixir
defmodule MyAppWeb.OrgScope do
  use MyAppWeb, :verified_routes

  import Plug.Conn

  alias MyApp.Accounts.Scope
  alias MyApp.Orgs

  # Plug: the HTTP render and controllers
  def assign_org(conn, _opts) do
    scope = conn.assigns.current_scope

    # {org, role} if the scope's user is a member, else nil
    case Orgs.get_membership(scope, conn.params["org_slug"]) do
      {org, role} ->
        assign(conn, :current_scope, Scope.put_org(scope, org, role))

      nil ->
        conn
        |> Phoenix.Controller.put_flash(:error, "Organization not found.")
        |> Phoenix.Controller.redirect(to: ~p"/")
        |> halt()
    end
  end

  # on_mount: the websocket mount and each live navigation into the session
  def on_mount(:assign_org, %{"org_slug" => slug}, _session, socket) do
    scope = socket.assigns.current_scope

    case Orgs.get_membership(scope, slug) do
      {org, role} ->
        {:cont, Phoenix.Component.assign(socket, :current_scope, Scope.put_org(scope, org, role))}

      nil ->
        {:halt,
         socket
         |> Phoenix.LiveView.put_flash(:error, "Organization not found.")
         |> Phoenix.LiveView.redirect(to: ~p"/")}
    end
  end
end
```

```elixir
# router.ex — add `import MyAppWeb.OrgScope, only: [assign_org: 2]`
scope "/orgs/:org_slug", MyAppWeb do
  pipe_through [:browser, :require_authenticated_user, :assign_org]

  live_session :require_org_member,
    on_mount: [{MyAppWeb.UserAuth, :require_authenticated}, {MyAppWeb.OrgScope, :assign_org}] do
    live "/projects", ProjectLive.Index, :index
    live "/projects/new", ProjectLive.Form, :new
    live "/projects/:id", ProjectLive.Show, :show
    live "/projects/:id/edit", ProjectLive.Form, :edit
  end
end
```

The plug runs after `:require_authenticated_user`, so `current_scope.user` is always set. The hook runs on every mount, but a `push_patch` to another org's URL inside the same LiveView does not re-run it. Generated code never patches across orgs; if yours does, re-check the org in `handle_params/3`.

### 4. Test helpers (before generating)

```elixir
# test/support/fixtures/accounts_fixtures.ex
def org_scope_fixture, do: org_scope_fixture(user_scope_fixture())

def org_scope_fixture(%Scope{} = user_scope) do
  n = System.unique_integer([:positive])
  {:ok, org} = MyApp.Orgs.create_org_for(user_scope, %{name: "Org #{n}", slug: "org-#{n}"})
  Scope.put_org(user_scope, org, :admin)
end
```

```elixir
# test/support/conn_case.ex
def register_and_log_in_user_with_org(context) do
  %{scope: scope} = context = register_and_log_in_user(context)
  Map.put(context, :scope, MyApp.AccountsFixtures.org_scope_fixture(scope))
end
```

### 5. Generate

`mix phx.gen.live Projects Project projects name:string --scope org` produces:

- `field :org_id, :id` and `put_change(:org_id, org_scope.org.id)`;
- the topic `"org:#{scope.org.id}:projects"`, shared by every member;
- routes `~p"/orgs/#{@current_scope.org.slug}/projects"`;
- the new form building `%Project{org_id: socket.assigns.current_scope.org.id}`;
- tests using `org_scope_fixture()` and `setup :register_and_log_in_user_with_org`.

It stores **no `user_id`**, because the org owns the row. To record the author as well, add a non-cast `field :created_by_id, :id` and `put_change(:created_by_id, scope.user.id)` in the changeset.

Calling an org-scoped function with a user-only scope crashes deep inside with `BadMapError` (`scope.org` is `nil`). For a clear failure at the call site, tighten the head to `%Scope{org: %Org{}} = scope`.

---

## Threading the Scope

- **Hand-written context functions** follow the generated shape: scope first, owner filter in the query, ownership assert before writes. The rules are in the `ecto-essentials` skill.
- **Context calling context:** pass the same scope (`Billing.charge(scope, ...)`), never `scope.user` or a bare id.
- **Background jobs:** a scope isn't JSON. Enqueue ids and rebuild the scope in the worker.

```elixir
@impl Oban.Worker
def perform(%Oban.Job{args: %{"user_id" => user_id, "post_id" => post_id}}) do
  scope = MyApp.Accounts.Scope.for_user(MyApp.Accounts.get_user!(user_id))
  post = MyApp.Blog.get_post!(scope, post_id)
  MyApp.Blog.publish_post(scope, post)
end
```

## Scoped JSON Endpoints

The generated JSON controller test uses `setup :register_and_log_in_user`, which logs in through the session. Behind a Bearer-token pipeline, those tests fail until you swap that `setup` for a helper that creates a token and sets the `authorization` header. The token plug that assigns `:current_scope` is in the `phoenix-json-api` skill.

---

## Adopting Scopes in a Pre-1.8 App

A 1.7 `phx.gen.auth` app assigns `:current_user` (`fetch_current_user`, `on_mount :mount_current_user`, `:ensure_authenticated`), and its `register_and_log_in_user` returns no `scope`. After bumping to Phoenix 1.8:

1. **Scope module.** Copy the 1.8 `accounts/scope.ex` (above, without the org fields).
2. **Config.** Add the `:scopes` entry shown at the top (`default: true`, your fixture module, your setup helper name).
3. **Assign `:current_scope` next to `:current_user`.** Keep both until every caller has moved:

```elixir
def fetch_current_user(conn, _opts) do
  {user_token, conn} = ensure_user_token(conn)
  user = user_token && Accounts.get_user_by_session_token(user_token)

  conn
  |> assign(:current_user, user)
  |> assign(:current_scope, Scope.for_user(user))
end

defp mount_current_user(socket, session) do
  socket
  |> Phoenix.Component.assign_new(:current_user, fn ->
    if user_token = session["user_token"] do
      Accounts.get_user_by_session_token(user_token)
    end
  end)
  |> Phoenix.Component.assign_new(:current_scope, fn %{current_user: user} ->
    Scope.for_user(user)
  end)
end
```

4. **Test helpers.** Add `user_scope_fixture/0` to `AccountsFixtures`, and have `register_and_log_in_user/1` return `scope: Scope.for_user(user)` too.
5. **Owner columns.** Add `user_id` (FK and index) to existing tables, backfill it, then make it `NOT NULL` before scoping their contexts. On tables with live traffic, follow the steps in the `ecto-migrations-safety` skill.
6. **Convert contexts one at a time.** Add the scope argument and the owner filter. The arity change makes the compiler list every caller you still have to fix.
7. **Web layer.** 1.8 templates render `<Layouts.app flash={@flash} current_scope={@current_scope}>` and use 1.8 components (`<.button variant="primary">`). A 1.7 app has neither: its `app.html.heex` is a layout using `{@inner_content}`, and its `button/1` has no `:variant`. Port the 1.8 `Layouts.app/1` and `core_components.ex` first, or generate into a scratch 1.8 app and copy over only the context, schema, migration and tests.

---

## Common Mistakes

<!-- epg:bad -->
```elixir
# Bad — unscoped calls and a global topic in a scoped app
posts = Blog.list_posts()
post = Repo.get!(Post, id)
Phoenix.PubSub.broadcast(MyApp.PubSub, "posts", {:updated, post})

def update_post(%Scope{} = _scope, %Post{} = post, attrs) do
  post |> Post.changeset(attrs) |> Repo.update()
end
```

```elixir
# Good — scope in, owner filter in the query, ownership asserted, scoped topic
posts = Blog.list_posts(scope)
post = Blog.get_post!(scope, id)

def update_post(%Scope{} = scope, %Post{} = post, attrs) do
  true = post.user_id == scope.user.id

  with {:ok, post = %Post{}} <- post |> Post.changeset(attrs, scope) |> Repo.update() do
    broadcast_post(scope, {:updated, post})
    {:ok, post}
  end
end
```

| Symptom | Cause |
|---|---|
| Generated context has no scope argument | no default `:scopes` entry, or `--no-scope` |
| `KeyError :current_scope` in a generated controller | its pipeline doesn't assign the scope (`:api`) |
| `undefined function org_scope_fixture/0` in generated tests | the helper for the new entry wasn't written first |
| `MatchError` opening a "new" form | struct built without the owner (`%Post{}` instead of `%Post{user_id: ...}`) |
| Another user's records appear live | a global topic, or a hand-written broadcast that skips `broadcast_*` |
| `There can only be one default scope` | two entries have `default: true` (often a copy-pasted `user` entry) |

See the `testing-essentials` skill for the generated fixtures in tests, and the `phoenix-authorization-patterns` skill for policies and roles on top of the scope.
