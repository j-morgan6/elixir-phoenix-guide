---
name: phoenix-pubsub-patterns
description: MANDATORY for ALL PubSub and real-time broadcast work. Invoke before writing PubSub.subscribe, broadcast, or handle_info for real-time updates.
file_patterns:
  - "**/*_live.ex"
  - "**/*_live/*.ex"
  - "**/contexts/**/*.ex"
auto_suggest: true
---

# Phoenix PubSub Patterns

## RULES — Follow these with no exceptions

1. **Always guard subscriptions with `if connected?(socket)`** — prevents duplicate subscriptions on static render (LiveView mounts twice: once static, once connected)
2. **Broadcast from contexts, not LiveViews** — keeps real-time logic in the business layer; LiveViews only subscribe and react
3. **Use consistent topic naming** — `"resource:id"` for specific resources, `"resource:action"` for collection-wide events
4. **Handle PubSub messages in `handle_info/2`** — never in `handle_event/3`; PubSub messages are process messages, not client events
5. **Update assigns immutably with `update/3`** — never replace the full list; use `update(socket, :items, &[new | &1])`
6. **Test PubSub by calling context functions and asserting LiveView updates** — don't test `PubSub.broadcast` directly; test the full cycle

---

## Subscription Pattern

Subscribe in `mount/3` only when connected. The static render doesn't need real-time updates.

```elixir
defmodule MyAppWeb.PostLive.Index do
  use MyAppWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(MyApp.PubSub, "posts")
    end

    {:ok, assign(socket, :posts, list_posts())}
  end

  @impl true
  def handle_info({:post_created, post}, socket) do
    {:noreply, update(socket, :posts, fn posts -> [post | posts] end)}
  end

  @impl true
  def handle_info({:post_updated, post}, socket) do
    {:noreply,
     update(socket, :posts, fn posts ->
       Enum.map(posts, fn
         p when p.id == post.id -> post
         p -> p
       end)
     end)}
  end

  @impl true
  def handle_info({:post_deleted, post}, socket) do
    {:noreply,
     update(socket, :posts, fn posts ->
       Enum.reject(posts, &(&1.id == post.id))
     end)}
  end
end
```

---

## Broadcasting from Contexts

Broadcast after successful database operations. The context owns the business logic — LiveViews are just subscribers.

```elixir
defmodule MyApp.Blog do
  alias MyApp.Blog.Post
  alias MyApp.Repo

  def create_post(attrs) do
    %Post{}
    |> Post.changeset(attrs)
    |> Repo.insert()
    |> broadcast(:post_created)
  end

  def update_post(%Post{} = post, attrs) do
    post
    |> Post.changeset(attrs)
    |> Repo.update()
    |> broadcast(:post_updated)
  end

  def delete_post(%Post{} = post) do
    post
    |> Repo.delete()
    |> broadcast(:post_deleted)
  end

  # Only broadcast on success
  defp broadcast({:ok, post}, event) do
    Phoenix.PubSub.broadcast(MyApp.PubSub, "posts", {event, post})
    {:ok, post}
  end

  defp broadcast({:error, changeset}, _event) do
    {:error, changeset}
  end
end
```

---

## Topic Naming Conventions

Use a consistent naming scheme so subscribers know what to expect.

```elixir
# Collection-wide — all posts
topic = "posts"
# Events: {:post_created, post}, {:post_updated, post}, {:post_deleted, post}

# Specific resource — one post
topic = "posts:#{post.id}"
# Events: {:post_updated, post}, {:post_deleted, post}, {:comment_added, comment}

# User-scoped — all activity for a user
topic = "users:#{user.id}"
# Events: {:notification, notification}, {:message_received, message}
```

### Subscribing to Specific Resources

```elixir
@impl true
def mount(%{"id" => id}, _session, socket) do
  post = Blog.get_post!(id)

  if connected?(socket) do
    Phoenix.PubSub.subscribe(MyApp.PubSub, "posts:#{post.id}")
  end

  {:ok, assign(socket, :post, post)}
end
```

---

## Scoped Broadcasting

When events should only reach specific users or resources:

```elixir
# In context — broadcast to resource-specific topic
defp broadcast({:ok, comment}, :comment_added) do
  Phoenix.PubSub.broadcast(
    MyApp.PubSub,
    "posts:#{comment.post_id}",
    {:comment_added, comment}
  )
  {:ok, comment}
end

# In context — broadcast to user-specific topic
defp broadcast({:ok, notification}, :new_notification) do
  Phoenix.PubSub.broadcast(
    MyApp.PubSub,
    "users:#{notification.user_id}",
    {:new_notification, notification}
  )
  {:ok, notification}
end
```

---

## Immutable Assign Updates

Always use `update/3` to modify list assigns. Never replace the entire list unless you're refreshing from the database.

```elixir
# Bad — replaces the list, loses any local state
def handle_info({:post_created, post}, socket) do
  {:noreply, assign(socket, :posts, [post | socket.assigns.posts])}
end

# Good — uses update/3 for immutable prepend
def handle_info({:post_created, post}, socket) do
  {:noreply, update(socket, :posts, fn posts -> [post | posts] end)}
end

# Good — update a specific item in the list
def handle_info({:post_updated, updated_post}, socket) do
  {:noreply,
   update(socket, :posts, fn posts ->
     Enum.map(posts, fn
       post when post.id == updated_post.id -> updated_post
       post -> post
     end)
   end)}
end

# Good — remove an item from the list
def handle_info({:post_deleted, deleted_post}, socket) do
  {:noreply,
   update(socket, :posts, fn posts ->
     Enum.reject(posts, &(&1.id == deleted_post.id))
   end)}
end
```

---

## Testing PubSub

Test the full cycle: call a context function, assert the LiveView updates. Don't test `PubSub.broadcast` in isolation.

```elixir
describe "real-time updates" do
  test "new post appears in list", %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)

    {:ok, lv, _html} = live(conn, ~p"/posts")

    # Create a post through the context (triggers broadcast)
    {:ok, post} = Blog.create_post(%{title: "New Post", user_id: user.id})

    # Assert the LiveView received and rendered the update
    assert render(lv) =~ "New Post"
  end

  test "updated post reflects changes", %{conn: conn} do
    user = user_fixture()
    post = post_fixture(user_id: user.id, title: "Original")
    conn = log_in_user(conn, user)

    {:ok, lv, _html} = live(conn, ~p"/posts")
    assert render(lv) =~ "Original"

    {:ok, _post} = Blog.update_post(post, %{title: "Updated"})

    assert render(lv) =~ "Updated"
    refute render(lv) =~ "Original"
  end

  test "deleted post disappears from list", %{conn: conn} do
    user = user_fixture()
    post = post_fixture(user_id: user.id, title: "To Delete")
    conn = log_in_user(conn, user)

    {:ok, lv, _html} = live(conn, ~p"/posts")
    assert render(lv) =~ "To Delete"

    {:ok, _post} = Blog.delete_post(post)

    refute render(lv) =~ "To Delete"
  end
end
```

---

See `phoenix-liveview-essentials` skill for LiveView lifecycle patterns.
See `testing-essentials` skill for comprehensive testing patterns.
