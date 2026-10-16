---
name: phoenix-pubsub-patterns
description: "Use when adding real-time updates to LiveViews with Phoenix.PubSub — scoped topics, broadcasting from contexts, handle_info with streams, Presence in LiveView. Not for raw WebSocket APIs (use phoenix-channels-essentials)."
---

# Phoenix PubSub Patterns

> Verified against Elixir 1.20, Phoenix 1.8, LiveView 1.2, Ecto 3.14 — October 2026

## RULES — Follow these with no exceptions

1. **Scope every topic to who may see the data.** A global `"posts"` topic delivers every user's records to every subscriber. Use the 1.8 generator's shape, `"user:#{scope.user.id}:posts"`, or the shared boundary (`"org:#{scope.org.id}:posts"`) when data is shared.
2. **Wrap topics in context functions that take the scope** — `Blog.subscribe_posts(scope)` and a private `broadcast_post(scope, message)`. LiveViews never build topic strings.
3. **Broadcast from contexts, after the write succeeds.** LiveViews only subscribe and react.
4. **Subscribe in `mount/3` behind `if connected?(socket)`.** The disconnected render is a short-lived process. Subscribing in `handle_params/3` adds a duplicate subscription on every `push_patch`.
5. **Handle PubSub messages in `handle_info/2`** and match the payload struct (`{type, %Post{}} when type in [...]`), as the generators do.
6. **Collections are streams.** Re-stream with `stream(socket, :posts, list_posts(scope), reset: true)` (what `phx.gen.live` does), or apply one change with `stream_insert/4` / `stream_delete/3`.
7. **Subscribing to a single record's topic needs a scoped load first** — `get_post!(scope, id)` before subscribing to `"post:#{post.id}"`.
8. **Test the full cycle:** call the context with a scope, assert the LiveView re-rendered, and assert another user's change does **not** appear.

---

## Context: scoped subscribe and broadcast

This is what `mix phx.gen.live Blog Post posts ...` generates in Phoenix 1.8:

```elixir
defmodule MyApp.Blog do
  alias MyApp.Accounts.Scope
  alias MyApp.Blog.Post
  alias MyApp.Repo

  @doc """
  Subscribes to scoped notifications about post changes:
  `{:created, %Post{}}`, `{:updated, %Post{}}`, `{:deleted, %Post{}}`.
  """
  def subscribe_posts(%Scope{} = scope) do
    Phoenix.PubSub.subscribe(MyApp.PubSub, "user:#{scope.user.id}:posts")
  end

  defp broadcast_post(%Scope{} = scope, message) do
    Phoenix.PubSub.broadcast(MyApp.PubSub, "user:#{scope.user.id}:posts", message)
  end

  def list_posts(%Scope{} = scope), do: Repo.all_by(Post, user_id: scope.user.id)

  def create_post(%Scope{} = scope, attrs) do
    with {:ok, post = %Post{}} <-
           %Post{}
           |> Post.changeset(attrs, scope)
           |> Repo.insert() do
      broadcast_post(scope, {:created, post})
      {:ok, post}
    end
  end

  def update_post(%Scope{} = scope, %Post{} = post, attrs) do
    true = post.user_id == scope.user.id

    with {:ok, post = %Post{}} <-
           post
           |> Post.changeset(attrs, scope)
           |> Repo.update() do
      broadcast_post(scope, {:updated, post})
      {:ok, post}
    end
  end

  def delete_post(%Scope{} = scope, %Post{} = post) do
    true = post.user_id == scope.user.id

    with {:ok, post = %Post{}} <- Repo.delete(post) do
      broadcast_post(scope, {:deleted, post})
      {:ok, post}
    end
  end
end
```

If you broadcast inside `Repo.transact/2`, subscribers can receive the message before the commit and re-query stale data. Broadcast after `transact` returns `{:ok, _}`.

---

## LiveView: subscribe in mount, update the stream

The generated index re-fetches through the subscriber's own scope and resets the stream. It's simple and always correct; it costs one query per event.

```elixir
defmodule MyAppWeb.PostLive.Index do
  use MyAppWeb, :live_view

  alias MyApp.Blog

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Blog.subscribe_posts(socket.assigns.current_scope)
    end

    {:ok,
     socket
     |> assign(:page_title, "Listing Posts")
     |> stream(:posts, Blog.list_posts(socket.assigns.current_scope))}
  end

  @impl true
  def handle_info({type, %MyApp.Blog.Post{}}, socket)
      when type in [:created, :updated, :deleted] do
    {:noreply,
     stream(socket, :posts, Blog.list_posts(socket.assigns.current_scope), reset: true)}
  end
end
```

```heex
<div id="posts" phx-update="stream">
  <div :for={{id, post} <- @streams.posts} id={id}>{post.title}</div>
</div>
```

For large lists, apply the single change instead of re-fetching:

```elixir
@impl true
def handle_info({:created, %Post{} = post}, socket),
  do: {:noreply, stream_insert(socket, :posts, post, at: 0)}

def handle_info({:updated, %Post{} = post}, socket),
  do: {:noreply, stream_insert(socket, :posts, post)}

def handle_info({:deleted, %Post{} = post}, socket),
  do: {:noreply, stream_delete(socket, :posts, post)}
```

`stream_insert/4` on an existing DOM id updates that item in place. Streams aren't kept in server memory, so there is no `update(socket, :posts, ...)` over a list to maintain.

### Show page: match the record you're displaying

The topic carries all of the user's posts, so the show page pattern-matches on its own id and ignores the rest (generator `show.ex`):

```elixir
@impl true
def handle_info({:updated, %Post{id: id} = post}, %{assigns: %{post: %{id: id}}} = socket) do
  {:noreply, assign(socket, :post, post)}
end

def handle_info({:deleted, %Post{id: id}}, %{assigns: %{post: %{id: id}}} = socket) do
  {:noreply,
   socket
   |> put_flash(:error, "The current post was deleted.")
   |> push_navigate(to: ~p"/posts")}
end

def handle_info({type, %Post{}}, socket) when type in [:created, :updated, :deleted] do
  {:noreply, socket}
end
```

---

## Topic Naming

| Topic | Who may subscribe |
|---|---|
| `"user:#{scope.user.id}:posts"` | that user (generator default) |
| `"org:#{scope.org.id}:posts"` | members of the org, if your scope carries one |
| `"post:#{post.id}:comments"` | only after `get_post!(scope, id)` succeeded for this user |

The topic prefix is the scope's config entry name (`user`, `org`); see the `phoenix-scopes-and-generators` skill to add an org entry.

Topic names are not secrets, and `Phoenix.PubSub.subscribe/2` has no access control. The only guard is that your code decides which topics a process subscribes to, after authorizing.

```elixir
@impl true
def mount(%{"id" => id}, _session, socket) do
  # Raises (404) unless the post belongs to this scope.
  post = Blog.get_post!(socket.assigns.current_scope, id)

  if connected?(socket), do: Blog.subscribe_comments(post)

  {:ok, socket |> assign(:post, post) |> stream(:comments, Blog.list_comments(post))}
end
```

---

## Broadcast Variants

| Function | Delivers to |
|---|---|
| `Phoenix.PubSub.broadcast/3` | every subscriber on every node |
| `Phoenix.PubSub.broadcast_from/4` | everyone except the given pid (skip the sender's own LiveView) |
| `Phoenix.PubSub.local_broadcast/3` | subscribers on this node only |
| `MyAppWeb.Endpoint.broadcast/3` | channel subscribers, wrapped in `%Phoenix.Socket.Broadcast{}` |

Use `local_broadcast` when every node produces the event itself, such as per-node cache invalidation or Presence's `handle_metas/4` callback; a cluster-wide broadcast would deliver it N times. For Presence in a LiveView, see below.

---

## Presence in a LiveView

Generate `MyAppWeb.Presence` with `mix phx.gen.presence` and supervise it (see the `phoenix-channels-essentials` skill). Track the LiveView process itself and subscribe to the same topic. Presence diffs arrive as `%Phoenix.Socket.Broadcast{event: "presence_diff"}`:

```elixir
@impl true
def mount(%{"id" => id}, _session, socket) do
  scope = socket.assigns.current_scope
  room = MyApp.Chat.get_room!(scope, id)
  topic = "room_presence:#{room.id}"

  if connected?(socket) do
    {:ok, _} = MyAppWeb.Presence.track(self(), topic, to_string(scope.user.id), %{email: scope.user.email})
    Phoenix.PubSub.subscribe(MyApp.PubSub, topic)
  end

  {:ok, socket |> assign(room: room, presence_topic: topic) |> assign_online()}
end

@impl true
def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
  {:noreply, assign_online(socket)}
end

defp assign_online(socket) do
  online =
    for {_user_id, %{metas: [meta | _]}} <- MyAppWeb.Presence.list(socket.assigns.presence_topic),
        do: meta.email

  assign(socket, :online, online)
end
```

The presence is removed when the LiveView process exits. Re-listing on each diff is fine for small rooms; for large ones apply `joins`/`leaves` from the diff payload to a stream.

---

## Testing PubSub

```elixir
describe "real-time updates" do
  setup :register_and_log_in_user

  test "a new post appears", %{conn: conn, scope: scope} do
    {:ok, lv, _html} = live(conn, ~p"/posts")

    post_fixture(scope, %{title: "New Post"})

    assert has_element?(lv, "#posts", "New Post")
  end

  test "a deleted post disappears", %{conn: conn, scope: scope} do
    post = post_fixture(scope, %{title: "To Delete"})
    {:ok, lv, _html} = live(conn, ~p"/posts")

    {:ok, _} = Blog.delete_post(scope, post)

    refute has_element?(lv, "#posts", "To Delete")
  end

  test "another user's post does not appear", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/posts")

    post_fixture(user_scope_fixture(), %{title: "Not yours"})

    refute has_element?(lv, "#posts", "Not yours")
  end
end
```

`Phoenix.PubSub.broadcast/3` puts the message in the LiveView's mailbox before it returns, and `has_element?/3` (like `render/1`) is a call to that process, so the assertion sees the update without sleeping.

See the `phoenix-liveview-essentials` skill for LiveView lifecycle patterns and the `testing-essentials` skill before writing any `_test.exs` file.
