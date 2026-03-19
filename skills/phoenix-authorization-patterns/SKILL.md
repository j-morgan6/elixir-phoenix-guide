---
name: phoenix-authorization-patterns
description: MANDATORY for ALL authorization and access control work. Invoke before writing permission checks, policy modules, or role-based access.
file_patterns:
  - "**/*_live.ex"
  - "**/*_live/*.ex"
  - "**/controllers/**/*.ex"
auto_suggest: true
---

# Phoenix Authorization Patterns

## RULES — Follow these with no exceptions

1. **Always authorize on the server in event handlers** — UI-only checks (hiding buttons) are not security; always verify in `handle_event/3`
2. **Verify resource ownership by comparing `current_scope.user.id` against the resource's `user_id`** — never trust client-sent user IDs
3. **Use policy modules for complex authorization** — don't inline permission checks in LiveViews or controllers
4. **Add `data-confirm` attribute for destructive UI actions** — client-side confirmation before server round-trip
5. **Test both authorized and unauthorized paths** — every `handle_event` that mutates data needs an authz test proving unauthorized access is rejected
6. **Scope queries to the current user in contexts** — `where(user_id: ^user_id)` prevents IDOR vulnerabilities

---

## Server-Side Authorization in LiveViews

UI checks prevent accidental clicks. Server checks prevent attacks. You need both.

```elixir
defmodule MyAppWeb.PostLive.Show do
  use MyAppWeb, :live_view

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    post = Blog.get_post!(id)
    {:ok, assign(socket, :post, post)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1><%= @post.title %></h1>

    <%!-- UI check — hide button if not owner --%>
    <%= if @current_scope.user.id == @post.user_id do %>
      <.button phx-click="delete" data-confirm="Are you sure?">
        Delete
      </.button>
    <% end %>
    """
  end

  # Server check — ALWAYS verify ownership
  @impl true
  def handle_event("delete", _params, socket) do
    post = socket.assigns.post

    if socket.assigns.current_scope.user.id == post.user_id do
      {:ok, _} = Blog.delete_post(post)
      {:noreply, push_navigate(socket, to: ~p"/posts")}
    else
      {:noreply, put_flash(socket, :error, "Not authorized")}
    end
  end
end
```

---

## Owner-Only Pattern

The simplest and most common authorization pattern. Extract it for reuse.

```elixir
defmodule MyAppWeb.PostLive.Edit do
  use MyAppWeb, :live_view

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    post = Blog.get_post!(id)

    if authorized?(socket, post) do
      changeset = Blog.change_post(post)
      {:ok, assign(socket, post: post, form: to_form(changeset))}
    else
      {:ok,
       socket
       |> put_flash(:error, "Not authorized")
       |> push_navigate(to: ~p"/posts")}
    end
  end

  @impl true
  def handle_event("save", %{"post" => params}, socket) do
    post = socket.assigns.post

    if authorized?(socket, post) do
      case Blog.update_post(post, params) do
        {:ok, post} ->
          {:noreply, push_navigate(socket, to: ~p"/posts/#{post}")}
        {:error, changeset} ->
          {:noreply, assign(socket, :form, to_form(changeset))}
      end
    else
      {:noreply, put_flash(socket, :error, "Not authorized")}
    end
  end

  defp authorized?(socket, resource) do
    socket.assigns.current_scope.user.id == resource.user_id
  end
end
```

---

## Scoped Queries in Contexts

The strongest authorization pattern: queries only return data the user owns. No separate check needed.

```elixir
defmodule MyApp.Blog do
  import Ecto.Query

  # Scoped — only returns posts owned by this user
  def list_user_posts(%Scope{user: user}) do
    Post
    |> where(user_id: ^user.id)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  # Scoped get — returns nil if not owned by user
  def get_user_post(%Scope{user: user}, id) do
    Post
    |> where(user_id: ^user.id)
    |> Repo.get(id)
  end

  # Scoped update — only updates if owned
  def update_user_post(%Scope{user: user}, %Post{} = post, attrs) do
    if post.user_id == user.id do
      post
      |> Post.changeset(attrs)
      |> Repo.update()
    else
      {:error, :unauthorized}
    end
  end

  # Scoped delete — only deletes if owned
  def delete_user_post(%Scope{user: user}, %Post{} = post) do
    if post.user_id == user.id do
      Repo.delete(post)
    else
      {:error, :unauthorized}
    end
  end
end
```

### Using Scoped Contexts in LiveViews

```elixir
@impl true
def mount(_params, _session, socket) do
  scope = socket.assigns.current_scope
  posts = Blog.list_user_posts(scope)
  {:ok, assign(socket, :posts, posts)}
end

@impl true
def handle_event("delete", %{"id" => id}, socket) do
  scope = socket.assigns.current_scope
  post = Blog.get_user_post(scope, id)

  case Blog.delete_user_post(scope, post) do
    {:ok, _} -> {:noreply, update(socket, :posts, &Enum.reject(&1, fn p -> p.id == post.id end))}
    {:error, :unauthorized} -> {:noreply, put_flash(socket, :error, "Not authorized")}
  end
end
```

---

## Policy Modules

For applications with complex permissions (roles, teams, org-level access), extract authorization into policy modules.

```elixir
defmodule MyApp.Policy do
  alias MyApp.Accounts.User
  alias MyApp.Blog.Post

  def authorize(%User{role: :admin}, _action, _resource), do: :ok

  def authorize(%User{id: user_id}, :edit, %Post{user_id: user_id}), do: :ok
  def authorize(%User{id: user_id}, :delete, %Post{user_id: user_id}), do: :ok
  def authorize(%User{}, :view, %Post{published: true}), do: :ok

  def authorize(_user, _action, _resource), do: {:error, :unauthorized}
end

# Usage in LiveView
@impl true
def handle_event("delete", %{"id" => id}, socket) do
  user = socket.assigns.current_scope.user
  post = Blog.get_post!(id)

  case Policy.authorize(user, :delete, post) do
    :ok ->
      {:ok, _} = Blog.delete_post(post)
      {:noreply, push_navigate(socket, to: ~p"/posts")}

    {:error, :unauthorized} ->
      {:noreply, put_flash(socket, :error, "Not authorized")}
  end
end
```

---

## Controller Authorization

Same principles apply in traditional controllers.

```elixir
defmodule MyAppWeb.PostController do
  use MyAppWeb, :controller

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_scope.user
    post = Blog.get_post!(id)

    if user.id == post.user_id do
      {:ok, _} = Blog.delete_post(post)
      redirect(conn, to: ~p"/posts")
    else
      conn
      |> put_flash(:error, "Not authorized")
      |> redirect(to: ~p"/posts")
    end
  end
end
```

---

## data-confirm for Destructive Actions

Always use `data-confirm` on buttons that delete or irreversibly modify data.

```elixir
# In HEEx template
<.button phx-click="delete" phx-value-id={post.id} data-confirm="Are you sure?">
  Delete
</.button>

# For links
<.link href={~p"/posts/#{post}"} method="delete" data-confirm="Delete this post?">
  Delete
</.link>
```

---

## Testing Authorization

Test that unauthorized users cannot perform actions, not just that authorized users can.

```elixir
describe "authorization" do
  test "owner can delete their post", %{conn: conn} do
    user = user_fixture()
    post = post_fixture(user_id: user.id)
    conn = log_in_user(conn, user)

    {:ok, lv, _html} = live(conn, ~p"/posts/#{post}")

    lv |> element("button", "Delete") |> render_click()
    assert_redirect(lv, ~p"/posts")
  end

  test "non-owner cannot delete post", %{conn: conn} do
    owner = user_fixture()
    other_user = user_fixture()
    post = post_fixture(user_id: owner.id)
    conn = log_in_user(conn, other_user)

    {:ok, lv, _html} = live(conn, ~p"/posts/#{post}")

    # Delete button should not be visible
    refute render(lv) =~ "Delete"

    # Even if they craft the event, server rejects it
    assert render_click(lv, "delete") =~ "Not authorized"
  end

  test "scoped query returns only user's posts" do
    user1 = user_fixture()
    user2 = user_fixture()
    post1 = post_fixture(user_id: user1.id)
    _post2 = post_fixture(user_id: user2.id)

    scope = %Scope{user: user1}
    posts = Blog.list_user_posts(scope)

    assert length(posts) == 1
    assert hd(posts).id == post1.id
  end
end
```

---

See `phoenix-liveview-auth` skill for authentication (who you are).
See `testing-essentials` skill for comprehensive testing patterns.
