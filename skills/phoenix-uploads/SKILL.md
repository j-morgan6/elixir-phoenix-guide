---
name: phoenix-uploads
description: MANDATORY for file upload features. Invoke before implementing upload or file serving functionality.
file_patterns:
  - "**/live/**/*.ex"
  - "**/*_live.ex"
  - "**/uploads/**/*.ex"
  - "**/endpoint.ex"
  - "**/*_web.ex"
auto_suggest: true
---

# Phoenix File Uploads

## RULES — Follow these with no exceptions

1. **Use manual uploads (NOT auto_upload: true)** for form submission patterns
2. **Always add upload directory to static_paths()** — files won't be accessible without this
3. **Handle upload errors** — display error_to_string/1 output in templates
4. **Create upload directories with File.mkdir_p!** before saving files
5. **Generate unique filenames** — prevent collisions and path traversal attacks
6. **Validate file types server-side** — never trust client MIME types
7. **Restart server after changing static_paths()** — changes don't apply until restart

---

## Upload Configuration

### Manual Upload (Recommended for Most Cases)

```elixir
allow_upload(:upload_name,
  accept: ~w(.jpg .jpeg .png .pdf),
  max_entries: 10,
  max_file_size: 10_000_000
)
```

**Template Requirements:**
- Form with `phx-submit` event
- Submit button to trigger upload
- `<.live_file_input>` component
- Progress indicators

### Auto Upload (Advanced - Use Sparingly)

Only use `auto_upload: true` when:
- Files should upload immediately on selection
- You have `handle_progress/3` callback
- You consume entries outside form submission

**⚠️ Never use auto_upload: true with form submission patterns!**

## Complete Upload Pattern

### LiveView Module

```elixir
@impl true
def mount(_params, _session, socket) do
  socket =
    socket
    |> assign(:uploaded_files, [])
    |> allow_upload(:photos,
         accept: ~w(.jpg .jpeg .png),
         max_entries: 5,
         max_file_size: 10_000_000
       )

  {:ok, socket}
end

@impl true
def handle_event("validate", _params, socket) do
  {:noreply, socket}
end

@impl true
def handle_event("save", _params, socket) do
  uploaded_files =
    consume_uploaded_entries(socket, :photos, fn %{path: path}, entry ->
      dest = Path.join(["priv", "static", "uploads", safe_filename(entry.client_name)])
      File.mkdir_p!(Path.dirname(dest))
      File.cp!(path, dest)
      {:ok, ~s(/uploads/#{Path.basename(dest)})}
    end)

  # Save to database with uploaded_files paths
  {:noreply, assign(socket, :uploaded_files, uploaded_files)}
end

defp safe_filename(original_name) do
  # Generate unique name to prevent collisions and attacks
  ext = Path.extname(original_name)
  "#{Ecto.UUID.generate()}#{ext}"
end
```

### Template

```heex
<.simple_form for={@form} phx-change="validate" phx-submit="save">
  <.input field={@form[:title]} label="Title" />

  <div>
    <.label>Upload Photos</.label>
    <.live_file_input upload={@uploads.photos} />
  </div>

  <!-- Upload errors -->
  <%= for err <- upload_errors(@uploads.photos) do %>
    <p class="error"><%= error_to_string(err) %></p>
  <% end %>

  <!-- Entry previews and errors -->
  <%= for entry <- @uploads.photos.entries do %>
    <div>
      <.live_img_preview entry={entry} />
      <progress value={entry.progress} max="100"><%= entry.progress %>%</progress>

      <%= for err <- upload_errors(@uploads.photos, entry) do %>
        <p class="error"><%= error_to_string(err) %></p>
      <% end %>
    </div>
  <% end %>

  <:actions>
    <.button phx-disable-with="Uploading...">Upload</.button>
  </:actions>
</.simple_form>
```

## Error Handling

Always implement `error_to_string/1`:

```elixir
defp error_to_string(:too_large), do: "File is too large (max 10MB)"
defp error_to_string(:not_accepted), do: "File type not accepted"
defp error_to_string(:too_many_files), do: "Too many files selected"
defp error_to_string(:external_client_failure), do: "Upload failed"
```

## Static File Serving Configuration

**Critical:** After uploading files, they MUST be served via static_paths.

### Step 1: Define static_paths/0

```elixir
# lib/my_app_web.ex
def static_paths do
  ~w(assets fonts images uploads favicon.ico robots.txt)
end
```

**Rule:** Any directory you serve files from must be listed here.

### Step 2: Verify Plug.Static Configuration

```elixir
# lib/my_app_web/endpoint.ex
plug Plug.Static,
  at: "/",
  from: :my_app,
  gzip: false,
  only: MyAppWeb.static_paths()
```

### File Structure

Static files must be in `priv/static/`:

```
my_app/
├── priv/
│   └── static/
│       ├── assets/        # CSS, JS (from esbuild)
│       ├── uploads/       # User uploads
│       │   ├── image1.jpg
│       │   └── doc.pdf
│       └── favicon.ico
```

## Serving Uploaded Files

### From Templates

```heex
<!-- Image -->
<img src="/uploads/photo.jpg" alt="Photo" />

<!-- Document download -->
<.link href="/uploads/document.pdf" download>Download</.link>
```

### From Controllers

```elixir
def download(conn, %{"filename" => filename}) do
  # Sanitize filename to prevent path traversal
  safe_name = Path.basename(filename)
  path = Path.join(["priv", "static", "uploads", safe_name])

  if File.exists?(path) and String.starts_with?(path, "priv/static/uploads") do
    send_download(conn, {:file, path}, filename: safe_name)
  else
    conn
    |> put_status(:not_found)
    |> text("File not found")
  end
end
```

## Image Previews

For image uploads, show previews:

```heex
<%= for entry <- @uploads.photos.entries do %>
  <div class="preview">
    <.live_img_preview entry={entry} width={200} />
    <button type="button" phx-click="cancel-upload" phx-value-ref={entry.ref}>
      Cancel
    </button>
  </div>
<% end %>
```

```elixir
@impl true
def handle_event("cancel-upload", %{"ref" => ref}, socket) do
  {:noreply, cancel_upload(socket, :photos, ref)}
end
```

## Multiple Upload Slots

You can have multiple upload configurations:

```elixir
socket
|> allow_upload(:photos, accept: ~w(.jpg .jpeg .png), max_entries: 5)
|> allow_upload(:documents, accept: ~w(.pdf .docx), max_entries: 3)
```

## External Storage (S3, etc.)

For external storage, use the `:external` option:

```elixir
allow_upload(:photos,
  accept: ~w(.jpg .jpeg .png),
  max_entries: 5,
  external: &presign_upload/2
)

defp presign_upload(entry, socket) do
  # Generate presigned URL for S3
  {:ok, %{uploader: "S3", key: key, url: url}, socket}
end
```

## Troubleshooting

### Files Return 404

**Problem:** Accessing `/uploads/file.jpg` returns 404

**Fixes:**
1. Check static_paths includes "uploads"
2. Verify file exists in `priv/static/uploads/`
3. **Restart server** after changing static_paths
4. Check file permissions (should be readable)

```elixir
# Debug helper
def check_static_file(path) do
  full_path = Path.join(["priv", "static", path])

  cond do
    not File.exists?(full_path) ->
      "File does not exist: #{full_path}"

    not File.readable?(full_path) ->
      "File exists but not readable: #{full_path}"

    true ->
      "File OK: #{full_path}"
  end
end
```

### Files Work in Dev but Not Production

**Problem:** Files serve correctly locally but fail in production

**Fixes:**

1. **Run `mix phx.digest` before deployment:**
```bash
MIX_ENV=prod mix phx.digest
```

2. **Check production endpoint config:**
```elixir
# config/runtime.exs
config :my_app, MyAppWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json"
```

3. **Ensure files are deployed:**
```
# Check your deployment includes priv/static/
```

## Security Best Practices

### 1. Sanitize File Paths

**Never** use user input directly in file paths:

```elixir
# ❌ DANGEROUS - Path traversal attack
def serve_file(conn, %{"path" => user_path}) do
  send_file(conn, 200, "priv/static/#{user_path}")
end

# ✅ SAFE - Validate and constrain
def serve_file(conn, %{"filename" => filename}) do
  safe_name = Path.basename(filename)  # Remove directory traversal
  path = Path.join(["priv", "static", "uploads", safe_name])

  if File.exists?(path) and String.starts_with?(path, "priv/static/uploads") do
    send_file(conn, 200, path)
  else
    send_resp(conn, 404, "Not found")
  end
end
```

### 2. Validate File Types

Don't trust client MIME types:

```elixir
def validate_file_type(path) do
  # Use a library like `file_type` to verify actual content
  case FileType.from_path(path) do
    {:ok, %{mime_type: "image/" <> _}} -> :ok
    _ -> {:error, :invalid_type}
  end
end
```

### 3. Generate Unique Filenames

Prevent collisions and path traversal:

```elixir
defp safe_filename(original_name) do
  ext = Path.extname(original_name)
  "#{Ecto.UUID.generate()}#{ext}"
end
```

### 4. Limit File Sizes

Set reasonable limits:

```elixir
allow_upload(:photos,
  accept: ~w(.jpg .jpeg .png),
  max_entries: 5,
  max_file_size: 10_000_000  # 10MB
)
```

### 5. Content-Type Headers

Set proper content types to prevent XSS:

```elixir
def serve_image(conn, %{"id" => id}) do
  image = get_image!(id)

  conn
  |> put_resp_header("content-type", image.content_type)
  |> put_resp_header("x-content-type-options", "nosniff")
  |> send_file(200, image.path)
end
```

## Testing Uploads

```elixir
test "uploads image successfully", %{conn: conn} do
  {:ok, lv, _html} = live(conn, "/gallery")

  image =
    file_input(lv, "#upload-form", :photos, [
      %{
        name: "test.png",
        content: File.read!("test/fixtures/test.png"),
        type: "image/png"
      }
    ])

  assert render_upload(image, "test.png") =~ "100%"

  lv
  |> form("#upload-form")
  |> render_submit()

  assert has_element?(lv, "img[alt='test.png']")
end
```

## Common Pitfalls

### ❌ Using auto_upload with form submit
```elixir
# DON'T DO THIS
allow_upload(:photos, auto_upload: true, ...)

def handle_event("save", _params, socket) do
  consume_uploaded_entries(socket, :photos, ...)  # Won't work!
end
```

### ✅ Use manual upload instead
```elixir
# DO THIS
allow_upload(:photos, ...)

def handle_event("save", _params, socket) do
  consume_uploaded_entries(socket, :photos, ...)  # Works!
end
```

### ❌ Not handling upload errors
```heex
<!-- Missing error display -->
<.live_file_input upload={@uploads.photos} />
```

### ✅ Always show errors
```heex
<.live_file_input upload={@uploads.photos} />
<%= for err <- upload_errors(@uploads.photos) do %>
  <p class="error"><%= error_to_string(err) %></p>
<% end %>
```

### ❌ Forgetting static_paths
```elixir
# File saved to priv/static/uploads/
# But "uploads" not in static_paths
def static_paths, do: ~w(assets favicon.ico)  # Missing uploads!
```

### ✅ Include upload directory
```elixir
def static_paths, do: ~w(assets uploads favicon.ico)
```

## Quick Reference

```elixir
# 1. Add directory to static_paths
def static_paths, do: ~w(assets uploads favicon.ico)

# 2. Create directory structure
priv/static/uploads/

# 3. Configure upload in mount
allow_upload(:photos, accept: ~w(.jpg .png), max_entries: 5)

# 4. Consume in handle_event
consume_uploaded_entries(socket, :photos, fn %{path: path}, entry ->
  dest = Path.join(["priv", "static", "uploads", safe_filename(entry.client_name)])
  File.mkdir_p!(Path.dirname(dest))
  File.cp!(path, dest)
  {:ok, "/uploads/#{Path.basename(dest)}"}
end)

# 5. Reference in templates
<img src="/uploads/#{filename}" />

# 6. Restart server to apply changes
mix phx.server
```

## Testing

When writing tests for file upload functionality, invoke `elixir-phoenix-guide:testing-essentials` before writing any `_test.exs` file.
