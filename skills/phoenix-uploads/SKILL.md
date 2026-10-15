---
name: phoenix-uploads
description: "Use when implementing file uploads or serving uploaded files — allow_upload, consume_uploaded_entries, content-type allowlists, validators, local vs S3/external storage, authorized downloads."
---

# Phoenix File Uploads

> Verified against Elixir 1.20, Phoenix 1.8, LiveView 1.2, Ecto 3.14 — October 2026

## RULES — Follow these with no exceptions

1. **Never take the stored extension or the served content type from the client.** LiveView accepts an entry when its client MIME type **or** its file extension matches `:accept`, so `x.html` sent as `image/png` passes. Sniff the magic bytes of the uploaded file and pick the extension from an allowlist keyed on the detected type.
2. **Name files on the server** — `Ecto.UUID.generate() <> allowlisted_ext`. Never put `entry.client_name` (or any request param) in a path.
3. **Store under a configured directory, not a cwd-relative `"priv/static/uploads"`.** `priv/static` is replaced on every release deploy and runtime files are never in the digest manifest. Read the directory from app config at runtime and serve it with its own `Plug.Static` (or use object storage via `:external`).
4. **Private files go through a controller that loads the record through the scope** — `Media.get_document!(scope, id)`. Never accept a filename or path from the request. Send an allowlisted `content_type`, `disposition: :attachment` and `x-content-type-options: nosniff`.
5. **The `consume_uploaded_entries/3` callback must return `{:ok, value}` or `{:postpone, value}`.** Wrap the context result (`{:ok, Media.create_image(...)}`) and handle failures after consuming.
6. **Render `upload_errors/1` and `upload_errors/2`, and make `error_to_string/1` total** — atoms, `{:external_metadata_failure, _}`, `{:writer_failure, _}`, your `validator:` reasons, and a catch-all.
7. **Form markup is Phoenix 1.8:** assign `:form` in `mount`, give `<.form>` an `id`, put `<.button>` directly inside it (`<.form>` has no `actions` slot), and use a plain `<label for={@uploads.images.ref}>` (1.8 `core_components` has no `label/1` component).
8. **Default to manual uploads.** With `auto_upload: true`, `consume_uploaded_entries/3` raises while any entry is still in progress; consume from a `progress:` callback once `entry.done?`.
9. **External uploads need both halves:** the `:external` function returns meta with an `:uploader` name, and that name must be registered in `uploaders:` on the JS `LiveSocket`.

---

## Complete Upload Pattern (local storage)

### Context: sniff, name, store

The `MyApp.Media.Image` schema is the one in the `ecto-essentials` skill: `title`, `filename` (server-generated), `original_name` (display only), `content_type`, `byte_size`, `folder_id`, `user_id`. Its `changeset/3` casts only `[:title, :original_name]`.

```elixir
defmodule MyApp.Media do
  alias MyApp.Accounts.Scope
  alias MyApp.Media.Image
  alias MyApp.Repo

  # Detected content type => extension we store under. The client's name and
  # type never decide either.
  @exts %{"image/jpeg" => ".jpg", "image/png" => ".png", "image/webp" => ".webp"}

  def allowed_type?(content_type), do: Map.has_key?(@exts, content_type)

  def create_image(%Scope{} = scope, tmp_path, attrs) do
    with {:ok, stored} <- store_file(tmp_path) do
      # Storage fields are set on the struct, never cast from attrs.
      changeset = Image |> struct!(stored) |> Image.changeset(attrs, scope)

      case Repo.insert(changeset) do
        {:ok, image} ->
          {:ok, image}

        {:error, changeset} ->
          # Don't leave an orphaned file behind a failed insert.
          remove_file(stored.filename)
          {:error, changeset}
      end
    end
  end

  def delete_image(%Scope{} = scope, %Image{} = image) do
    true = image.user_id == scope.user.id

    with {:ok, image} <- Repo.delete(image) do
      remove_file(image.filename)
      {:ok, image}
    end
  end

  # list_images/2, get_image!/2, update_image/3: see the ecto-essentials skill.

  def image_url(%Image{filename: filename}), do: "/uploads/" <> filename

  # Resolved at runtime, so prod can point at a mounted volume (config/runtime.exs).
  def uploads_dir, do: Application.fetch_env!(:my_app, :uploads_dir)

  defp store_file(tmp_path) do
    with {:ok, content_type} <- sniff_image(tmp_path) do
      filename = Ecto.UUID.generate() <> Map.fetch!(@exts, content_type)
      File.mkdir_p!(uploads_dir())
      File.cp!(tmp_path, Path.join(uploads_dir(), filename))

      {:ok, %{filename: filename, content_type: content_type, byte_size: File.stat!(tmp_path).size}}
    end
  end

  defp remove_file(filename), do: File.rm(Path.join(uploads_dir(), filename))

  # Magic bytes from the file itself.
  defp sniff_image(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, 12)) do
      {:ok, <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>} -> {:ok, "image/png"}
      {:ok, <<0xFF, 0xD8, 0xFF, _::binary>>} -> {:ok, "image/jpeg"}
      {:ok, <<"RIFF", _::binary-size(4), "WEBP", _::binary>>} -> {:ok, "image/webp"}
      _ -> {:error, :invalid_content}
    end
  end
end
```

For more formats, the `file_type` package sniffs many types: `FileType.from_path(path)` returns `{:ok, {"png", "image/png"}}` or `{:error, reason}`. Still map the detected MIME type through your own allowlist. Broadcasts (`{:created, image}` etc.) follow the `phoenix-pubsub-patterns` skill.

### LiveView

```elixir
defmodule MyAppWeb.ImageLive.Index do
  use MyAppWeb, :live_view

  alias MyApp.Media

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:form, to_form(%{"title" => ""}, as: :image))
     |> stream(:images, Media.list_images(socket.assigns.current_scope))
     |> allow_upload(:images,
       accept: ~w(.jpg .jpeg .png .webp),
       max_entries: 5,
       max_file_size: 10_000_000,
       # Runs on client metadata, before any bytes arrive: early feedback only.
       # The magic-byte check in the context is the real gate.
       validator: &validate_entry/1
     )}
  end

  @impl true
  def handle_event("validate", %{"image" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :image))}
  end

  def handle_event("save", %{"image" => params}, socket) do
    scope = socket.assigns.current_scope

    # The temp file is deleted once the callback returns, so store and insert here,
    # but always return {:ok, result} and deal with failures below.
    results =
      consume_uploaded_entries(socket, :images, fn %{path: path}, entry ->
        attrs = Map.put(params, "original_name", entry.client_name)
        {:ok, Media.create_image(scope, path, attrs)}
      end)

    {saved, failed} = Enum.split_with(results, &match?({:ok, _}, &1))

    socket =
      Enum.reduce(saved, socket, fn {:ok, image}, acc ->
        stream_insert(acc, :images, image, at: 0)
      end)

    socket =
      if failed == [],
        do: socket,
        else: put_flash(socket, :error, "#{length(failed)} file(s) were not valid images")

    {:noreply, assign(socket, :form, to_form(%{"title" => ""}, as: :image))}
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :images, ref)}
  end

  defp validate_entry(%{client_type: type}) do
    if Media.allowed_type?(type), do: :ok, else: {:error, :unsupported_type}
  end

  defp error_to_string(:too_large), do: "File is too large (max 10 MB)"
  defp error_to_string(:not_accepted), do: "Only JPEG, PNG and WebP images are accepted"
  defp error_to_string(:unsupported_type), do: "Only JPEG, PNG and WebP images are accepted"
  defp error_to_string(:too_many_files), do: "Too many files (max 5)"
  defp error_to_string(:external_client_failure), do: "Upload failed, please try again"
  defp error_to_string({:external_metadata_failure, _meta}), do: "Could not prepare the upload"
  defp error_to_string({:writer_failure, _reason}), do: "Could not store the file"
  defp error_to_string(_other), do: "Upload failed"
end
```

### Template

`render/1` (or the colocated `.html.heex`), wrapped in `<Layouts.app flash={@flash} current_scope={@current_scope}>` like the generators:

```heex
<.form for={@form} id="upload-form" phx-change="validate" phx-submit="save">
  <.input field={@form[:title]} label="Title" />

  <div phx-drop-target={@uploads.images.ref} class="border border-dashed p-4">
    <label for={@uploads.images.ref} class="label">Images (or drop them here)</label>
    <.live_file_input upload={@uploads.images} />
  </div>

  <p :for={err <- upload_errors(@uploads.images)} class="text-error">{error_to_string(err)}</p>

  <div :for={entry <- @uploads.images.entries} id={"entry-#{entry.ref}"}>
    <.live_img_preview entry={entry} width="120" />
    <progress value={entry.progress} max="100">{entry.progress}%</progress>
    <button type="button" phx-click="cancel-upload" phx-value-ref={entry.ref} aria-label="cancel">
      &times;
    </button>
    <p :for={err <- upload_errors(@uploads.images, entry)} class="text-error">
      {error_to_string(err)}
    </p>
  </div>

  <.button phx-disable-with="Uploading...">Upload</.button>
</.form>

<div id="images" phx-update="stream">
  <img
    :for={{id, image} <- @streams.images}
    id={id}
    src={MyApp.Media.image_url(image)}
    alt={image.title}
  />
</div>
```

`phx-drop-target` gets the `phx-drop-target-active` class while a file is dragged over it. `live_file_input` renders `id={@uploads.images.ref}`, which is what the `<label for>` points at.

---

## Storing and Serving Local Files

Configure the directory per environment and serve it with a dedicated `Plug.Static`. An MFA `from:` is resolved on each request, so the runtime config applies in releases:

```elixir
# config/dev.exs (add priv/uploads to .gitignore)
config :my_app, :uploads_dir, Path.expand("../priv/uploads", __DIR__)

# config/test.exs
config :my_app, :uploads_dir, Path.expand("../tmp/test_uploads", __DIR__)

# config/runtime.exs, inside `if config_env() == :prod do`: a mounted volume
config :my_app, :uploads_dir, System.fetch_env!("UPLOADS_DIR")
```

```elixir
# lib/my_app_web/endpoint.ex, next to the generated Plug.Static
plug Plug.Static,
  at: "/uploads",
  from: {MyApp.Media, :uploads_dir, []},
  gzip: false,
  headers: %{
    "x-content-type-options" => "nosniff",
    "content-security-policy" => "default-src 'none'"
  }
```

Plug.Static sets the content type from the extension, which is safe only because the extension came from the sniffed type. Everything under `/uploads` is public: there is no auth before the router. Files that need authorization go through a controller (below).

Writing into `priv/static/uploads` and adding `"uploads"` to `static_paths/0` works in dev only: the next release deploy wipes it.

### Private files: scoped download controller

```elixir
defmodule MyAppWeb.DocumentController do
  use MyAppWeb, :controller

  alias MyApp.Media

  # Route lives in the scope piped through :require_authenticated_user.
  def show(conn, %{"id" => id}) do
    # Scoped lookup: another user's id raises Ecto.NoResultsError (404).
    document = Media.get_document!(conn.assigns.current_scope, id)

    conn
    |> put_resp_header("x-content-type-options", "nosniff")
    |> send_download({:file, Media.document_path(document)},
      # Display name only; send_download encodes it into the header.
      filename: document.original_name,
      # Stored from the allowlist at upload time, not the client's type.
      content_type: document.content_type,
      disposition: :attachment
    )
  end
end
```

`Media.document_path/1` is `Path.join(private_dir(), document.filename)`, where `filename` is the server-generated UUID name. Keep private files outside any `Plug.Static` directory.

---

## External Uploads (S3 and compatible)

The browser uploads straight to storage; the server only signs. Pick the key and the extension on the server:

```elixir
# In mount: allow_upload(:images, accept: ..., validator: &validate_entry/1,
#                        external: &presign_upload/2)

defp presign_upload(entry, socket) do
  # With manual uploads, :external can be called for entries the validator
  # rejected, so check the allowlist again.
  with {:ok, ext} <- Media.extension_for(entry.client_type),
       key = "images/#{entry.uuid}#{ext}",
       {:ok, url} <- Media.presigned_put_url(key, entry.client_type) do
    {:ok, %{uploader: "S3", key: key, url: url, content_type: entry.client_type}, socket}
  else
    _ -> {:error, %{reason: "unsupported type"}, socket}
  end
end

# In "save", the callback receives the meta map returned above.
consume_uploaded_entries(socket, :images, fn %{key: key}, entry ->
  {:ok, Media.create_image_from_key(scope, key, entry, params)}
end)
```

`Media.presigned_put_url/2` wraps your S3 client (for example `ex_aws_s3`'s presigned URL function). Sign the `content-type` into the URL so storage rejects a different header, configure CORS on the bucket for your origin, and serve user content from a separate domain. The server never sees the bytes, so there is no magic-byte check unless you fetch and verify the object afterwards (for example in an Oban job).

Register the uploader on the client. Without this, LiveView logs "no uploader configured for S3" and nothing uploads:

```javascript
// assets/js/app.js
const Uploaders = {}

Uploaders.S3 = function (entries, onViewError) {
  entries.forEach(entry => {
    const xhr = new XMLHttpRequest()
    onViewError(() => xhr.abort())
    xhr.onload = () => (xhr.status >= 200 && xhr.status < 300 ? entry.progress(100) : entry.error())
    xhr.onerror = () => entry.error()
    xhr.upload.addEventListener("progress", event => {
      if (event.lengthComputable) {
        const percent = Math.round((event.loaded / event.total) * 100)
        if (percent < 100) entry.progress(percent)
      }
    })
    xhr.open("PUT", entry.meta.url, true)
    xhr.setRequestHeader("content-type", entry.meta.content_type)
    xhr.send(entry.file)
  })
}

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks},
  uploaders: Uploaders
})
```

`entry.error()` surfaces as `:external_client_failure` in `upload_errors/2`.

---

## Custom Writers

`writer:` streams chunks somewhere other than a temp file (for example straight to another service). It takes a 3-arity function returning `{module, opts}`, where the module implements `Phoenix.LiveView.UploadWriter` (`init/1`, `meta/1`, `write_chunk/2`, `close/2`). Whatever `meta/1` returns is what `consume_uploaded_entries/3` receives instead of `%{path: path}`. Writers run in the upload channel process: blocking work blocks the upload, and an error from `write_chunk/2` cancels the entry with `{:writer_failure, reason}`.

```elixir
allow_upload(socket, :video,
  accept: ~w(.mp4),
  max_file_size: 500_000_000,
  writer: fn _name, entry, _socket -> {MyApp.StreamingWriter, upload_id: entry.uuid} end
)
```

---

## Auto Upload

`auto_upload: true` starts uploading on file selection. Consume each entry from a `progress:` callback once it is done; consuming in a submit handler raises `ArgumentError` while any entry is still in progress.

```elixir
# allow_upload(:avatar, accept: ~w(.jpg .jpeg .png), auto_upload: true,
#              progress: &handle_progress/3)

defp handle_progress(:avatar, entry, socket) do
  if entry.done? do
    scope = socket.assigns.current_scope

    result =
      consume_uploaded_entry(socket, entry, fn %{path: path} ->
        {:ok, MyApp.Accounts.update_avatar(scope, path)}
      end)

    case result do
      {:ok, _user} -> {:noreply, put_flash(socket, :info, "Avatar updated")}
      {:error, _reason} -> {:noreply, put_flash(socket, :error, "Not a valid image")}
    end
  else
    {:noreply, socket}
  end
end
```

---

## Testing Uploads

```elixir
setup :register_and_log_in_user

@png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>> <> :binary.copy(<<0>>, 64)

test "uploads an image", %{conn: conn} do
  {:ok, lv, _html} = live(conn, ~p"/images")

  upload = file_input(lv, "#upload-form", :images, [%{name: "cat.png", content: @png, type: "image/png"}])
  assert render_upload(upload, "cat.png") =~ "100%"

  lv |> form("#upload-form", image: %{title: "Cat"}) |> render_submit()

  assert has_element?(lv, "#images img[alt='Cat']")
end

test "rejects a type that isn't accepted", %{conn: conn} do
  {:ok, lv, _html} = live(conn, ~p"/images")

  pdf = file_input(lv, "#upload-form", :images, [%{name: "a.pdf", content: "%PDF-1.7", type: "application/pdf"}])

  assert {:error, [[_ref, :not_accepted]]} = render_upload(pdf, "a.pdf")
end

test "rejects HTML that claims to be a PNG", %{conn: conn} do
  {:ok, lv, _html} = live(conn, ~p"/images")

  fake = file_input(lv, "#upload-form", :images, [%{name: "x.html", content: "<script>", type: "image/png"}])
  render_upload(fake, "x.html")

  assert lv |> form("#upload-form", image: %{title: "x"}) |> render_submit() =~ "not valid images"
end
```

`file_input/4` only builds the upload; `render_upload/3` is what sends it to the server, so assert on its result for validation errors. See the `testing-essentials` skill before writing any `_test.exs` file.

---

## Troubleshooting

- **`/uploads/...` returns 404:** the file isn't under `MyApp.Media.uploads_dir()`, or the `Plug.Static at: "/uploads"` plug is missing or placed after the router.
- **Uploads vanish after a deploy:** they were written into `priv/static` (Rule 3). `mix phx.digest` doesn't help; it only fingerprints files that existed at build time.
- **Submit button doesn't render:** it is inside an `actions` slot; `<.form>` only declares `inner_block`, so the slot is dropped with just a compile warning.
- **`no uploader configured for S3` in the browser console:** the `uploaders:` option is missing on `LiveSocket`.
