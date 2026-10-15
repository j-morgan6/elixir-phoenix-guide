# LiveView Review Checklist

> Verified against Elixir 1.20, Phoenix 1.8, LiveView 1.2 — October 2026

Walk through this before finishing or reviewing a LiveView. Each section has a checklist and,
where it helps, a reference snippet. The examples build one gallery LiveView: images in folders,
owned by the current user, with uploads.

Assumed context API (Phoenix 1.8 style, scope first; the `Image` schema is the one in the
`ecto-essentials` skill): `Media.list_folders(scope)`, `Media.get_folder!(scope, id)`,
`Media.list_images(scope, filters \\ [])`, `Media.get_image!(scope, id)`,
`Media.create_image(scope, tmp_path, attrs)`, `Media.delete_image(scope, image)`,
`Media.image_url(image)`, and `Media.subscribe_images(scope)`, which delivers
`{:created | :updated | :deleted, %Image{}}`.

## Module Setup

- [ ] `use MyAppWeb, :live_view` (brings in `JS`, core components, `~p`, `Layouts`)
- [ ] `@impl true` before every callback
- [ ] Render wraps content in `<Layouts.app flash={@flash} current_scope={@current_scope}>`
- [ ] The route sits in a `live_session` whose `on_mount` assigns `current_scope` (see the `phoenix-liveview-auth` skill)

## Mount

- [ ] Every assign the template reads is set here or in `handle_params/3`
- [ ] PubSub subscriptions and timers only inside `if connected?(socket)`, and only here
- [ ] Collections are streams; small fixed lists (folders, options) may be plain assigns
- [ ] Slow or optional data uses `assign_async` / `stream_async`, not a blocking query
- [ ] Returns `{:ok, socket}`

```elixir
@impl true
def mount(_params, _session, socket) do
  scope = socket.assigns.current_scope

  if connected?(socket) do
    Media.subscribe_images(scope)
  end

  {:ok,
   socket
   |> assign(:folders, Media.list_folders(scope))
   |> assign(:selected_folder, nil)
   |> stream(:images, [])
   |> assign(:form, to_form(%{"title" => ""}, as: :image))
   |> allow_upload(:images, accept: ~w(.jpg .jpeg .png .webp), max_entries: 5, max_file_size: 10_000_000)}
end
```

## Handle Params

- [ ] Present whenever URL params change what's shown (ids, filters, sort, page)
- [ ] Never subscribes — it re-runs on every `push_patch`
- [ ] Records loaded by URL id go through the scope (`get_folder!(scope, id)`)
- [ ] Refilters a stream with `reset: true`

```elixir
@impl true
def handle_params(%{"folder_id" => folder_id}, _uri, socket) do
  scope = socket.assigns.current_scope
  folder = Media.get_folder!(scope, folder_id)

  {:noreply,
   socket
   |> assign(:selected_folder, folder)
   |> stream(:images, Media.list_images(scope, folder_id: folder.id), reset: true)}
end

def handle_params(_params, _uri, socket) do
  {:noreply,
   socket
   |> assign(:selected_folder, nil)
   |> stream(:images, Media.list_images(socket.assigns.current_scope), reset: true)}
end
```

## Handle Event

- [ ] Every context call gets `socket.assigns.current_scope` first — an id from the client is never trusted on its own
- [ ] Load the record through the scope, then act on the struct (string params never compare equal to integer ids)
- [ ] Expected failures (`{:error, changeset}`, `{:error, :reason}`) become flash or form errors; only bugs crash
- [ ] Returns `{:noreply, socket}` (or `{:reply, map, socket}` for a hook's `pushEvent`)

```elixir
@impl true
def handle_event("delete_image", %{"id" => id}, socket) do
  scope = socket.assigns.current_scope
  image = Media.get_image!(scope, id)

  case Media.delete_image(scope, image) do
    {:ok, _} ->
      {:noreply,
       socket
       |> put_flash(:info, "Image deleted")
       |> stream_delete(:images, image)}

    {:error, _changeset} ->
      {:noreply, put_flash(socket, :error, "Failed to delete image")}
  end
end
```

## Handle Info

- [ ] Clauses match the exact broadcast shapes from the context (`{:created, %Image{}}`, ...)
- [ ] Updates the stream rather than refetching, unless order/filter makes that impractical (then `stream(..., reset: true)`)
- [ ] Multi-clause callbacks are grouped together, `@impl true` on the first

```elixir
@impl true
def handle_info({:created, %Image{} = image}, socket) do
  {:noreply, stream_insert(socket, :images, image, at: 0)}
end

def handle_info({:updated, %Image{} = image}, socket) do
  {:noreply, stream_insert(socket, :images, image)}
end

def handle_info({:deleted, %Image{} = image}, socket) do
  {:noreply, stream_delete(socket, :images, image)}
end
```

If a broadcast carries only an id, use `stream_delete_by_dom_id(socket, :images, "images-#{id}")`.

## Forms

- [ ] `@form` comes from `to_form/2`; templates never read a raw changeset
- [ ] `<.form>` has a unique `id`, `phx-change` and `phx-submit`
- [ ] `<.button>` is a direct child of `<.form>` (no actions slot — it would never render)
- [ ] The validate handler uses `to_form(changeset, action: :validate)`
- [ ] `phx-debounce` on inputs that hit the server on every keystroke
- [ ] `phx-disable-with` on submit buttons

## File Uploads

The `phoenix-uploads` skill has the full pattern (context, LiveView, template, tests). Check:

- [ ] `allow_upload/3` in mount with `accept`, `max_entries`, `max_file_size`
- [ ] The form has `phx-change` (even a no-op validate handler) so entries are tracked
- [ ] The callback given to `consume_uploaded_entries/3` returns `{:ok, value}` or `{:postpone, value}` — wrap the context result and handle `{:error, _}` after consuming
- [ ] The stored name and extension come from the server (UUID plus an extension picked from the sniffed content type), never from `entry.client_name` or `entry.client_type`
- [ ] Files are stored under a configured directory, not `priv/static`, and rendered through a helper (`Media.image_url(image)`)
- [ ] `upload_errors/1` and `upload_errors/2` are rendered, and `error_to_string/1` has a catch-all clause

## Templates

- [ ] `{@x}` for interpolation in text and attributes, never `<%= @x %>`
- [ ] `:for` / `:if` attributes instead of EEx `for` / `if` blocks
- [ ] Stream containers have an `id` and `phx-update="stream"`; each child uses the stream's `dom_id`
- [ ] `:for` over a plain list has a `:key`
- [ ] Function components declare `attr` / `slot` (with `default:` for optional attrs)
- [ ] Loading states for async assigns via `<.async_result>`
- [ ] Every element with `phx-hook` has a unique `id`

```heex
<Layouts.app flash={@flash} current_scope={@current_scope}>
  <%!-- Upload form (#upload-form, @uploads.images): see the phoenix-uploads skill --%>

  <div id="images" phx-update="stream">
    <div :for={{dom_id, image} <- @streams.images} id={dom_id}>
      <img src={Media.image_url(image)} alt={image.title} />
      <.button phx-click="delete_image" phx-value-id={image.id} data-confirm="Delete this image?">
        Delete
      </.button>
    </div>
  </div>
</Layouts.app>
```

`~p` only verifies routes and static paths; uploaded files are neither, so build their URLs with a helper.

## Navigation

- [ ] `push_patch` / `<.link patch>` for the same LiveView with new params (only `handle_params/3` runs)
- [ ] `push_navigate` / `<.link navigate>` for another LiveView in the same `live_session` (no page reload; assigns are not carried over, flash is)
- [ ] `redirect/2` / `<.link href>` for a full page load (controller routes, other `live_session`s)
- [ ] Paths use `~p`

## Testing

Invoke the `testing-essentials` skill before writing the test file. Upload test shape:

```elixir
test "uploads and displays an image", %{conn: conn} do
  {:ok, lv, _html} = live(conn, ~p"/gallery")

  upload =
    file_input(lv, "#upload-form", :images, [
      %{name: "test.png", content: File.read!("test/support/fixtures/test.png"), type: "image/png"}
    ])

  assert render_upload(upload, "test.png") =~ "100%"

  lv |> form("#upload-form", image: %{title: "Sunset"}) |> render_submit()

  assert has_element?(lv, "#images img[alt='Sunset']")
end
```

- [ ] `render_async(lv)` before asserting on async-loaded content
- [ ] Forms are targeted by their `id` (`form(lv, "#upload-form", ...)`)

## Performance

- [ ] Streams for anything that grows; `limit:` for feeds
- [ ] No queries in `render/1` or in function components
- [ ] Associations preloaded in the context, not lazily per row
- [ ] Async task functions capture plain values, not `socket` or `assigns`
- [ ] `phx-debounce` / `phx-throttle` on chatty events

## Common Pitfalls

- Subscribing in `handle_params/3` (duplicate messages after each `push_patch`)
- Context calls without the scope, or `Repo` calls in the LiveView
- Lists of records kept in assigns and updated with `update/3`
- Submit button inside an actions slot of `<.form>`, or a form without `id`
- `@current_user` (Phoenix 1.8 assigns `@current_scope`; the user is `@current_scope.user`)
- Changing the socket after `push_navigate/2` and expecting the next LiveView to see it
- `socket.assigns.x` in templates (use `@x`, which is change-tracked)
