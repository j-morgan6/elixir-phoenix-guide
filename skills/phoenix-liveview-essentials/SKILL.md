---
name: phoenix-liveview-essentials
description: "Use when writing LiveView modules or HEEx templates — mount/handle_params lifecycle, forms with to_form and phx-change, streams, assign_async/start_async, JS commands, hooks, function components."
---

# Phoenix LiveView Essentials

> Verified against Elixir 1.20, Phoenix 1.8, LiveView 1.2 — October 2026

## RULES — Follow these with no exceptions

1. **`@impl true` before every callback** — `mount`, `handle_params`, `handle_event`, `handle_info`, `handle_async`, `render`.
2. **Pass `socket.assigns.current_scope` as the first argument to every context call** — `Blog.get_post!(scope, id)`, never `Blog.get_post!(id)`. Loading, updating or deleting by a client-supplied id without the scope is an IDOR. LiveViews call contexts, never `Repo`.
3. **Set every assign `render/1` reads before the first render** — static defaults in `mount/3`, URL-dependent ones (filter, sort, page) in `handle_params/3`.
4. **Subscribe and start timers in `mount/3` inside `if connected?(socket)`** — never in `handle_params/3`, which re-runs on every `push_patch` and stacks duplicate subscriptions.
5. **Load slow data with `assign_async`, `stream_async` or `start_async`** — not with `if connected?(socket)` branches or blocking queries in `mount/3`.
6. **Collections are streams** — `stream/4`, `stream_insert/4`, `stream_delete/3`, `stream(..., reset: true)` to refilter. The container needs an `id` and `phx-update="stream"`.
7. **Forms:** `to_form/2` into `@form`; `<.form for={@form} id="..." phx-change="validate" phx-submit="save">`; `<.button>` directly inside the form (`<.form>` declares only `inner_block` — an actions slot is silently dropped, so the button never renders). Validate with `to_form(changeset, action: :validate)`.
8. **Expected failures don't crash** — on `{:error, %Ecto.Changeset{}}` re-assign the form; let only bugs raise.
9. **Function components declare `attr`/`slot`**, with `default:` for optional attrs — never `Map.get(assigns, :x, default)` or `assigns[:x]`.
10. **HEEx:** `{@x}` in text and attributes, `:for`/`:if` attributes, `<%!-- --%>` comments; add `:key` to `:for` over plain lists.
11. **JS:** reach for `Phoenix.LiveView.JS` commands first, then colocated hooks; every `phx-hook` element needs a unique DOM `id`.
12. **Reuse `core_components.ex`** (`<.input>`, `<.button>`, `<.table>`, `<.header>`, `<.list>`, `<.icon>`) before writing new components.

Before finishing or reviewing a LiveView, walk through [the LiveView checklist](checklist.md). For hook callbacks, `push_event` payloads, `ColocatedJS`/`ColocatedCSS` setup and runtime hooks, read [the JS interop reference](js-interop.md).

Related skills: `phoenix-liveview-auth` (`live_session`, `on_mount` auth), `phoenix-pubsub-patterns` (broadcasting), `phoenix-uploads` (`allow_upload`, consuming entries), `testing-essentials` (LiveView tests).

---

## Lifecycle

```text
HTTP GET       mount/3 -> handle_params/3 -> render/1   connected?(socket) == false, static HTML
WebSocket      mount/3 -> handle_params/3 -> render/1   connected?(socket) == true, now live
push_patch     handle_params/3 -> render/1              same process; mount/3 does NOT run
push_navigate  new LiveView mounts over the same socket (same live_session); no page reload
redirect/2     full HTTP page load
```

`mount/3` runs twice per page load, so synchronous work in it runs twice. Async tasks only start once connected — that's why `assign_async` replaces the old `if connected?` loading pattern. `push_navigate` to a route in a *different* `live_session` falls back to a full page load.

### A complete index LiveView

Based on `mix phx.gen.live` output (scoped context calls, subscription in `mount`, streams), plus a URL filter and single-item stream updates instead of the generator's re-fetch.

```elixir
defmodule MyAppWeb.PostLive.Index do
  use MyAppWeb, :live_view

  alias MyApp.Blog
  alias MyApp.Blog.Post

  @impl true
  def mount(_params, _session, socket) do
    # Once per LiveView process. handle_params/3 re-runs on every push_patch.
    if connected?(socket) do
      Blog.subscribe_posts(socket.assigns.current_scope)
    end

    {:ok, assign(socket, :page_title, "Listing Posts")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    status = params["status"] || "all"
    # list_posts/2 is the generated list_posts/1 plus a filter option
    posts = Blog.list_posts(socket.assigns.current_scope, status: status)

    {:noreply,
     socket
     |> assign(:status, status)
     |> stream(:posts, posts, reset: true)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    # Scoped lookup: another user's id raises Ecto.NoResultsError instead of deleting
    post = Blog.get_post!(scope, id)
    {:ok, _} = Blog.delete_post(scope, post)

    {:noreply, stream_delete(socket, :posts, post)}
  end

  @impl true
  def handle_info({:created, %Post{} = post}, socket) do
    if visible?(post, socket.assigns.status) do
      {:noreply, stream_insert(socket, :posts, post, at: 0)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:updated, %Post{} = post}, socket) do
    # Existing DOM id -> updated in place; an edit can also move it out of the filter
    if visible?(post, socket.assigns.status) do
      {:noreply, stream_insert(socket, :posts, post)}
    else
      {:noreply, stream_delete(socket, :posts, post)}
    end
  end

  def handle_info({:deleted, %Post{} = post}, socket) do
    {:noreply, stream_delete(socket, :posts, post)}
  end

  # Broadcasts carry every post in the scope; keep the stream matching the URL filter.
  defp visible?(_post, "all"), do: true
  defp visible?(%Post{status: status}, filter), do: to_string(status) == filter
end
```

```heex
<Layouts.app flash={@flash} current_scope={@current_scope}>
  <.link patch={~p"/posts?status=draft"}>Drafts</.link>

  <div id="posts" phx-update="stream">
    <%!-- Non-stream child: needs its own id; shown only when it is the only child --%>
    <p id="posts-empty" class="hidden only:block">No posts yet.</p>
    <div :for={{dom_id, post} <- @streams.posts} id={dom_id}>
      <.link navigate={~p"/posts/#{post}"}>{post.title}</.link>
      <.link
        phx-click={JS.push("delete", value: %{id: post.id}) |> hide("##{dom_id}")}
        data-confirm="Are you sure?"
      >
        Delete
      </.link>
    </div>
  </div>
</Layouts.app>
```

The generated `<.table rows={@streams.posts}>` from `core_components.ex` handles the stream container for you.

### Streams vs plain lists

- Stream items aren't kept in server memory, so you can't `Enum` over `@streams.posts`. Keep counts or "is empty" state in a separate assign, or use the `only:` CSS trick above.
- `stream(socket, :posts, items, reset: true)` replaces the client list (refiltering, pagination). `limit: -50` keeps the last 50.
- `stream_delete(socket, :posts, post)` needs the struct; with only a DOM id use `stream_delete_by_dom_id/3`.
- Small, bounded lists (tabs, a few options) can stay plain assigns. Give the comprehension a `:key` so appending doesn't re-send every item:

```heex
<li :for={tag <- @tags} :key={tag.id}>{tag.name}</li>
```

`:key` has no effect on streams and isn't supported on slots.

## Navigation

| Call | Use it for |
|---|---|
| `push_patch(socket, to: ~p"/posts?page=2")` / `<.link patch={...}>` | Same LiveView, new params → `handle_params/3` only |
| `push_navigate(socket, to: ~p"/posts/#{post}")` / `<.link navigate={...}>` | Another LiveView in the same `live_session`, over the existing socket |
| `redirect(socket, to: ~p"/users/log-in")` / `<.link href={...}>` | Full page load (controllers, other `live_session`s, logout) |

Assigns set before `push_navigate` are lost — the new LiveView mounts fresh. Flash survives.

## Forms

Mirrors `mix phx.gen.live`'s `Form` LiveView.

```heex
<.form for={@form} id="post-form" phx-change="validate" phx-submit="save">
  <.input field={@form[:title]} type="text" label="Title" phx-debounce="300" />
  <.input field={@form[:body]} type="textarea" label="Body" phx-debounce="blur" />
  <.button phx-disable-with="Saving..." variant="primary">Save Post</.button>
</.form>
```

```elixir
@impl true
def mount(%{"id" => id}, _session, socket) do
  post = Blog.get_post!(socket.assigns.current_scope, id)

  {:ok,
   socket
   |> assign(:post, post)
   |> assign(:form, to_form(Blog.change_post(socket.assigns.current_scope, post)))}
end

@impl true
def handle_event("validate", %{"post" => post_params}, socket) do
  changeset = Blog.change_post(socket.assigns.current_scope, socket.assigns.post, post_params)
  {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
end

def handle_event("save", %{"post" => post_params}, socket) do
  case Blog.update_post(socket.assigns.current_scope, socket.assigns.post, post_params) do
    {:ok, post} ->
      {:noreply,
       socket
       |> put_flash(:info, "Post updated")
       |> push_navigate(to: ~p"/posts/#{post}")}

    {:error, %Ecto.Changeset{} = changeset} ->
      {:noreply, assign(socket, :form, to_form(changeset))}
  end
end
```

- **Assign `:form`, not `:changeset`.** Templates read `@form[:field]`; `to_form/2` also accepts a plain map for schemaless forms: `to_form(%{"q" => ""}, as: :search)`.
- **`action: :validate`** is what makes errors show during `phx-change`; without an action the changeset's errors are hidden.
- **`used_input?/1`** hides errors on fields the user hasn't touched yet. The generated `<.input>` already calls it — call it yourself only in custom inputs.
- **Every form gets a unique `id`.** Form recovery after a reconnect needs it, and LiveView 1.2 tests warn about `phx-change` forms without one.
- **`phx-debounce="300"`** (ms) or `"blur"` on inputs that trigger server work; `phx-throttle` for rate-limiting clicks/keys.
- **Buttons go directly inside `<.form>`:**

<!-- epg:bad -->
```heex
<.form for={@form} id="post-form" phx-submit="save">
  <.input field={@form[:title]} />
  <:actions>
    <.button>Save</.button>
  </:actions>
</.form>
```

That compiles with only a warning and renders no submit button. Phoenix 1.8 removed `simple_form`, which had that slot.

## Async Loading

Each async task starts only when connected, runs in a linked process, and catches crashes into a `:failed` state.

```elixir
@impl true
def mount(%{"id" => id}, _session, socket) do
  # Copy what the task needs out of the socket first. Referencing `socket`
  # inside the fn copies the whole socket into the task (LiveView warns).
  scope = socket.assigns.current_scope

  {:ok,
   socket
   |> assign(:post, Blog.get_post!(scope, id))
   |> assign_async(:stats, fn -> {:ok, %{stats: Analytics.post_stats(scope, id)}} end)
   |> stream_async(:comments, fn -> {:ok, Blog.list_comments(scope, id), limit: 50} end)}
end
```

```heex
<.async_result :let={stats} assign={@stats}>
  <:loading>Loading stats...</:loading>
  <:failed :let={_reason}>Couldn't load stats.</:failed>
  {stats.views} views
</.async_result>

<div id="comments" phx-update="stream">
  <p :for={{dom_id, comment} <- @streams.comments} id={dom_id}>{comment.body}</p>
</div>
<p :if={@comments.loading}>Loading comments...</p>
```

- `assign_async(socket, keys, fn)` — the fn returns `{:ok, %{key => value}}` (every key listed) or `{:error, reason}`. The assign is a `Phoenix.LiveView.AsyncResult` (`.ok?`, `.loading`, `.failed`, `.result`).
- `stream_async(socket, :name, fn)` — the fn returns `{:ok, enumerable}` or `{:ok, enumerable, stream_opts}`; `@streams.name` exists immediately and `@name` holds the `AsyncResult`.
- `start_async/3` + `handle_async/3` — when you need to control the result (user-triggered work, replacing a running task):

```elixir
alias Phoenix.LiveView.AsyncResult

@impl true
def handle_event("summarize", _params, socket) do
  %{current_scope: scope, post: post} = socket.assigns

  {:noreply,
   socket
   |> assign(:summary, AsyncResult.loading())
   |> start_async(:summary, fn -> Blog.summarize(scope, post) end)}
end

@impl true
def handle_async(:summary, {:ok, summary}, socket) do
  {:noreply, update(socket, :summary, &AsyncResult.ok(&1, summary))}
end

def handle_async(:summary, {:exit, reason}, socket) do
  {:noreply, update(socket, :summary, &AsyncResult.failed(&1, {:exit, reason}))}
end
```

A second `start_async` with the same name wins and the earlier result is ignored; `cancel_async/3` kills one. In tests call `render_async(view)` before asserting.

Replaces this pattern, which still blocks the connected mount and has no error state:

<!-- epg:bad -->
```elixir
socket =
  if connected?(socket),
    do: assign(socket, :stats, Analytics.post_stats(scope, id)),
    else: assign(socket, :stats, nil)
```

## Function Components

```elixir
attr :post, MyApp.Blog.Post, required: true
attr :compact, :boolean, default: false
attr :rest, :global
slot :inner_block
slot :footer

def post_card(assigns) do
  ~H"""
  <article class={["card", @compact && "card-compact"]} {@rest}>
    <h3>{@post.title}</h3>
    {render_slot(@inner_block)}
    <footer :if={@footer != []}>{render_slot(@footer)}</footer>
  </article>
  """
end
```

`attr ..., default:` replaces optional-assign lookups and gives compile-time warnings for missing or unknown attrs:

<!-- epg:bad -->
```elixir
def post_card(assigns) do
  compact = Map.get(assigns, :compact, false)
  # ...
end
```

When a component must compute a derived assign, use `assign/3` or `assign_new/3` on `assigns` inside the component, not `Map.put`.

## JS Commands and Hooks

`Phoenix.LiveView.JS` (aliased as `JS` in `MyAppWeb`'s `html_helpers`) runs on the client with no round trip and survives DOM patches:

```heex
<button phx-click={JS.toggle(to: "#menu") |> JS.toggle_class("rotate-180", to: "#chevron")}>
  Menu
</button>
<div id="flash-banner" phx-mounted={JS.transition({"ease-out duration-300", "opacity-0", "opacity-100"})}>
  Saved
</div>
<dialog id="confirm" phx-mounted={JS.ignore_attributes("open")}>
  ...
</dialog>
```

- Commands: `push`, `show`, `hide`, `toggle`, `add_class`, `remove_class`, `toggle_class`, `set_attribute`, `remove_attribute`, `toggle_attribute`, `transition`, `dispatch`, `navigate`, `patch`, `focus`, `focus_first`, `push_focus`, `pop_focus`, `exec`, `ignore_attributes`. Pipe them; `JS.push("save") |> JS.hide(to: "#modal")`.
- `phx-mounted` runs a command when the element is added to the DOM (page load or later patch).
- `JS.ignore_attributes/1` (LiveView 1.1+) stops the server from patching attributes the client owns, like `<dialog open>` or `<details open>`. It only ignores future server changes.
- `phx-click-away`, `phx-window-keydown` (with `phx-key`), `phx-blur`/`phx-focus` cover most "small JS" needs before you write a hook.

### Colocated hooks (LiveView 1.1+, Phoenix 1.8)

Write the hook next to the markup. The name starts with a dot and is namespaced to the module; Phoenix 1.8's `app.js` already spreads `colocatedHooks` into `LiveSocket`.

```elixir
attr :field, Phoenix.HTML.FormField, required: true

def phone_input(assigns) do
  ~H"""
  <input type="text" id={@field.id} name={@field.name} value={@field.value} phx-hook=".PhoneMask" />
  <script :type={Phoenix.LiveView.ColocatedHook} name=".PhoneMask">
    export default {
      mounted() {
        this.el.addEventListener("input", () => {
          this.el.value = this.el.value.replace(/\D/g, "").slice(0, 10)
        })
      }
    }
  </script>
  """
end
```

### Server ↔ hook events

```elixir
# Server -> client: all hooks on the page can listen with this.handleEvent("chart:data", ...)
{:noreply, push_event(socket, "chart:data", %{points: points})}

# Client -> server: this.pushEvent("chart:clicked", %{index: 3}) arrives as an event;
# reply to the hook's promise with {:reply, map, socket}
@impl true
def handle_event("chart:clicked", %{"index" => index}, socket) do
  {:reply, %{label: Enum.at(socket.assigns.labels, index)}, socket}
end
```

A hook's element is patched by LiveView like any other; if the hook renders its own children, add `phx-update="ignore"` to it. Details, plus `ColocatedJS` for non-hook code and `ColocatedCSS` (1.2): [JS interop reference](js-interop.md).

## Lifecycle Hooks: `on_mount` and `attach_hook`

`on_mount` runs before `mount/3` — declared on a `live_session` in the router or with `on_mount {MyAppWeb.UserAuth, :require_authenticated}` in the module. It's where `current_scope` is assigned; see `phoenix-liveview-auth`.

`attach_hook/4` taps into `:handle_params`, `:handle_event`, `:handle_info`, `:handle_async` or `:after_render` from an `on_mount` or `mount`. Return `{:cont, socket}` to continue or `{:halt, socket}` to stop the callback, and always add a catch-all clause:

```elixir
def on_mount(:track_path, _params, _session, socket) do
  {:cont,
   attach_hook(socket, :current_path, :handle_params, fn _params, uri, socket ->
     {:cont, assign(socket, :current_path, URI.parse(uri).path)}
   end)}
end
```

## Portals

`<.portal>` (LiveView 1.1+) renders its content into another DOM node — modals, tooltips and dropdowns that must escape `overflow: hidden` or a stacking context — while events still go to the current LiveView:

```heex
<.portal id="post-modal" target="body">
  <div class="modal modal-open">{@post.title}</div>
</.portal>
```

`id` and `target` (a unique CSS selector) are required. In tests, `has_element?/2` can't see inside a portal; render `element(view, "#post-modal")` and match the HTML.

## Debugging a Running LiveView

`Phoenix.LiveView.Debug` (LiveView 1.1+) inspects live processes from IEx:

```elixir
Phoenix.LiveView.Debug.list_liveviews()
# => [%{pid: pid, view: MyAppWeb.PostLive.Index, topic: "lv:...", transport_pid: tpid}]
{:ok, socket} = Phoenix.LiveView.Debug.socket(pid)
socket.assigns
{:ok, components} = Phoenix.LiveView.Debug.live_components(pid)
```

## Common Mistakes

| Mistake | Fix |
|---|---|
| `Blog.get_post!(id)` / `Repo.get(Post, id)` in a LiveView | `Blog.get_post!(socket.assigns.current_scope, id)` |
| `PubSub.subscribe` in `handle_params` | Subscribe in `mount` under `connected?` |
| List of records in an assign, `update(socket, :posts, &[post \| &1])` | `stream_insert(socket, :posts, post, at: 0)` |
| `assign(socket, :changeset, cs)` and `<.form for={@changeset}>` | `assign(socket, :form, to_form(cs))` |
| Submit button inside an actions slot of `<.form>` | `<.button>` as a direct child |
| `<.form>` without `id` | `id="post-form"` |
| `socket.assigns.x` inside an `assign_async` fn | Bind `x = socket.assigns.x` before the fn |
| `if connected?` around an expensive load | `assign_async` / `stream_async` |
| `<%= @title %>`, EEx `for`/`if` blocks | `{@title}`, `:for={...}`, `:if={...}` |
| `@current_user` | `@current_scope` (`@current_scope.user`) — Phoenix 1.8 |
| `push_navigate` described as a reload | It swaps LiveViews over the socket; `redirect/2` reloads |
| Element with `phx-hook` and no `id` | Add a unique `id` (the client logs an error otherwise) |
