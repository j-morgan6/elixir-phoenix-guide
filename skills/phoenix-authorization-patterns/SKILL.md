---
name: phoenix-authorization-patterns
description: "Use when deciding who may do what to which record — scoping context calls with %Scope{}, ownership checks, policy modules, roles, mass-assignment safety in LiveViews and controllers. Not for login/session plumbing (use phoenix-liveview-auth)."
---

# Phoenix Authorization Patterns

> Verified against Elixir 1.20, Phoenix 1.8, LiveView 1.2, Ecto 3.14 — October 2026

## RULES — Follow these with no exceptions

1. **Pass `current_scope` as the first argument to every context call** — `Blog.get_post!(socket.assigns.current_scope, id)`, never `Blog.get_post!(id)` or `Repo.get!(Post, id)` with an id from params. Loading by a client id without the scope is an IDOR.
2. **Scope the query, not just the check** — `get_post!(%Scope{} = scope, id)` is `Repo.get_by!(Post, id: id, user_id: scope.user.id)`: another user's record raises `Ecto.NoResultsError` (a 404), so existence isn't leaked and no separate check can be forgotten.
3. **Authorize inside the context function** — mutations re-check ownership or call the policy (`true = post.user_id == scope.user.id`, as the 1.8 generator does), so every caller (LiveView, controller, job) is covered.
4. **Authorize in `handle_params/3` as well as `mount/3`** — `push_patch` re-runs `handle_params` but not `mount`; load any record whose id arrives in the URL through the scope where the params arrive.
5. **Authorize every `handle_event/3` on the server** — hiding a button is UX, not security; events can be crafted with any params.
6. **Never `cast` ownership or privileged fields** — `:user_id`, `:org_id`, `:role`, `:confirmed_at`, `:deleted_at`. Set them with `put_change/3` or `Ecto.build_assoc/3` from the scope, as the generator's `changeset(post, attrs, scope)` does.
7. **Policies take `%Scope{}`, not `%User{}`** — the scope is what the web layer has, and it can carry org and role.
8. **Put roles and orgs on the `Scope` struct** — extend the generated `Scope` (its moduledoc says to) and fill it once in an `on_mount` hook / plug, instead of threading extra arguments.
9. **Scope PubSub topics too** — subscribe and broadcast on `"user:#{scope.user.id}:posts"` (the generator's `subscribe_posts(scope)`), never a global topic.
10. **Test the unauthorized path** — another user's id must raise `Ecto.NoResultsError` (or return `{:error, :unauthorized}`); every mutating event needs a test proving that.

---

## Scoped Contexts (the 1.8 generator pattern)

`mix phx.gen.live Blog Post posts title:string body:text` in an app with `phx.gen.auth` generates scoped contexts (the generated module, with its broadcasts, is in the `phoenix-pubsub-patterns` skill). Follow the shape for hand-written contexts. The two authorization points:

```elixir
# Reads: the owner filter is part of the query
def get_post!(%Scope{} = scope, id) do
  Repo.get_by!(Post, id: id, user_id: scope.user.id)
end

# Writes: re-check ownership of the struct the caller passes in
def update_post(%Scope{} = scope, %Post{} = post, attrs) do
  true = post.user_id == scope.user.id

  post
  |> Post.changeset(attrs, scope)
  |> Repo.update()
end
```

The `true = ...` match crashes on a mismatch — correct when the caller should already have loaded the post through `get_post!/2`; a crash there means a bug, not a user error.

### Mass assignment: ownership comes from the scope

The generator's changeset never casts the owner; it sets it from the scope:

```elixir
post
|> cast(attrs, [:title, :body])
|> put_change(:user_id, user_scope.user.id)
```

For the bad/good pair and foreign keys the user chooses (`folder_id`), see the `ecto-changeset-patterns` skill.

---

## LiveViews

```elixir
defmodule MyAppWeb.PostLive.Index do
  use MyAppWeb, :live_view

  alias MyApp.Blog

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div id="posts" phx-update="stream">
        <div :for={{id, post} <- @streams.posts} id={id}>
          {post.title}
          <.link
            phx-click={JS.push("delete", value: %{id: post.id}) |> hide("##{id}")}
            data-confirm="Are you sure?"
          >
            Delete
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, stream(socket, :posts, Blog.list_posts(socket.assigns.current_scope))}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    post = Blog.get_post!(scope, id)
    {:ok, _} = Blog.delete_post(scope, post)

    {:noreply, stream_delete(socket, :posts, post)}
  end
end
```

The `id` comes from the client, but `get_post!/2` only finds the caller's own posts. `data-confirm` is a UX guard against misclicks, nothing more.

### handle_params: patches skip mount

<!-- epg:bad -->
```elixir
# Bad — mount checks, but a push_patch to /posts/OTHER_ID/edit only runs handle_params
def handle_params(%{"id" => id}, _uri, socket) do
  {:noreply, assign(socket, :post, Repo.get!(Post, id))}
end
```

```elixir
@impl true
def handle_params(%{"id" => id}, _uri, socket) do
  post = Blog.get_post!(socket.assigns.current_scope, id)
  {:noreply, assign(socket, post: post, form: to_form(Blog.change_post(socket.assigns.current_scope, post)))}
end

def handle_params(_params, _uri, socket) do
  {:noreply, assign(socket, post: nil, form: nil)}
end
```

---

## Roles and Orgs on the Scope

Extend the generated struct; keep `for_user/1` (it still returns `nil` for guests).

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

Fill it after authentication, from a membership lookup — never from a param or a cast field:

```elixir
defmodule MyAppWeb.OrgHooks do
  use MyAppWeb, :verified_routes

  alias MyApp.Accounts.Scope
  alias MyApp.Orgs

  def on_mount(:assign_org, %{"org_slug" => slug}, _session, socket) do
    scope = socket.assigns.current_scope

    # returns the caller's %Membership{org: org, role: role}, or nil
    case Orgs.get_membership(scope, slug) do
      %{org: org, role: role} ->
        {:cont, Phoenix.Component.assign(socket, :current_scope, Scope.put_org(scope, org, role))}

      nil ->
        {:halt,
         socket
         |> Phoenix.LiveView.put_flash(:error, "Not found")
         |> Phoenix.LiveView.redirect(to: ~p"/")}
    end
  end
end
```

```elixir
live_session :org,
  on_mount: [{MyAppWeb.UserAuth, :require_authenticated}, {MyAppWeb.OrgHooks, :assign_org}] do
  live "/orgs/:org_slug/projects", ProjectLive.Index, :index
end
```

Put this `live_session` in a `scope` that pipes through `[:browser, :require_authenticated_user]`, and give controllers an equivalent plug. Org-owned queries then filter on `scope.org.id`. To make `phx.gen.live`/`phx.gen.context` generate org-scoped code, add an entry to `config :my_app, :scopes` (same keys as the generated `user` entry: `module`, `assign_key`, `access_path: [:org, :id]`, `schema_key: :org_id`, ...) and pass `--scope org`.

A global role (site admin) belongs on the user as a non-cast field (see the `phoenix-auth-customization` skill) and is read as `scope.user.role`.

---

## Policy Modules

When rules go beyond "owner only" (admins, org roles, published content), centralize them in a policy that takes the scope, and call it from the context.

```elixir
defmodule MyApp.Blog.Policy do
  alias MyApp.Accounts.{Scope, User}
  alias MyApp.Blog.Post

  # assumes a non-cast `role` field on User
  def authorize(%Scope{user: %User{role: :admin}}, _action, %Post{}), do: :ok

  def authorize(%Scope{user: %User{id: id}}, action, %Post{user_id: id})
      when action in [:update, :delete],
      do: :ok

  def authorize(%Scope{org: %{id: org_id}, org_role: :editor}, :update, %Post{org_id: org_id}),
    do: :ok

  def authorize(_scope, :view, %Post{published: true}), do: :ok
  def authorize(_scope, _action, _resource), do: {:error, :unauthorized}
end
```

```elixir
# In the context — replaces the owner-only `true = ...` check
def delete_post(%Scope{} = scope, %Post{} = post) do
  with :ok <- Policy.authorize(scope, :delete, post) do
    Repo.delete(post)
  end
end
```

The catch-all also covers guests (`nil` scope). For an admin who may load any post, give the context an explicit query for that case (`get_post_for_admin!/2` that pattern-matches the admin scope) rather than unscoping `get_post!/2`.

---

## Controllers

Same rules; the plug assigns the same `current_scope`.

```elixir
def delete(conn, %{"id" => id}) do
  scope = conn.assigns.current_scope
  post = Blog.get_post!(scope, id)
  {:ok, _post} = Blog.delete_post(scope, post)

  conn
  |> put_flash(:info, "Post deleted.")
  |> redirect(to: ~p"/posts")
end
```

`Ecto.NoResultsError` renders as a 404 (via `phoenix_ecto`), so a guessed id looks like a missing page.

---

## Testing Authorization

```elixir
describe "authorization" do
  setup :register_and_log_in_user

  test "a user cannot load another user's post", %{conn: conn} do
    other_post = post_fixture(user_scope_fixture())

    assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/posts/#{other_post}") end
  end

  test "context refuses another scope", %{scope: scope} do
    other_scope = user_scope_fixture()
    post = post_fixture(scope)

    assert_raise Ecto.NoResultsError, fn -> Blog.get_post!(other_scope, post.id) end
    assert_raise MatchError, fn -> Blog.delete_post(other_scope, post) end
  end

  test "list is scoped", %{scope: scope} do
    post = post_fixture(scope)
    _other = post_fixture(user_scope_fixture())

    assert Blog.list_posts(scope) == [post]
  end
end
```

`register_and_log_in_user/1` puts `conn`, `user` and `scope` in the test context; `post_fixture/2` takes the scope first.

---

See the `phoenix-liveview-auth` skill for authentication (`on_mount`, `live_session`, sudo mode).
See the `phoenix-pubsub-patterns` skill for scoped topics.
See the `ecto-changeset-patterns` skill for changeset composition.
