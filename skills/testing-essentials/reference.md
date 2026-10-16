# Testing Reference for Elixir/Phoenix

> Verified against Elixir 1.20, Phoenix 1.8, LiveView 1.2, Ecto 3.14, Req 0.7 — October 2026

Companion to the `testing-essentials` skill, which holds the rules and core patterns. This file has longer worked examples.

The examples use the `MyApp.Media` context and `Image` schema from the `ecto-essentials` and `phoenix-uploads` skills (images in folders), in the Phoenix 1.8 style: every context function takes the caller's `%Scope{}` first; `Image.changeset/3` casts only `title` and `original_name` and sets `user_id` from the scope; `create_image(scope, tmp_path, attrs)` sniffs and stores the file and sets `filename`, `content_type` and `byte_size` itself.

---

## Fixtures

Fixtures live in `test/support/fixtures/` and go through the real context, so validations and scoping are exercised.

```elixir
defmodule MyApp.MediaFixtures do
  @moduledoc "Test helpers for the Media context."

  alias MyApp.Media

  # A real PNG: create_image/3 checks the magic bytes.
  def png_path, do: Path.join(__DIR__, "test.png")

  def unique_image_title, do: "Image #{System.unique_integer([:positive])}"

  def valid_image_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{title: unique_image_title(), original_name: "test.png"})
  end

  def image_fixture(scope, attrs \\ %{}) do
    {:ok, image} = Media.create_image(scope, png_path(), valid_image_attributes(attrs))
    image
  end

  def folder_fixture(scope, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{name: "Folder #{System.unique_integer([:positive])}"})
    {:ok, folder} = Media.create_folder(scope, attrs)
    folder
  end
end
```

`test/support/fixtures/test.png` must be a real PNG. `create_image/3` copies it into the test `:uploads_dir` (`tmp/test_uploads`, configured as in the `phoenix-uploads` skill); the server-generated UUID names keep async tests from colliding there.

---

## Context Tests

```elixir
defmodule MyApp.MediaTest do
  use MyApp.DataCase, async: true

  alias MyApp.Media
  alias MyApp.Media.Image

  import MyApp.AccountsFixtures, only: [user_scope_fixture: 0]
  import MyApp.MediaFixtures

  setup do
    %{scope: user_scope_fixture()}
  end

  describe "list_images/2" do
    test "returns only the scope's images", %{scope: scope} do
      image = image_fixture(scope)
      _others = image_fixture(user_scope_fixture())

      assert [%Image{id: id}] = Media.list_images(scope)
      assert id == image.id
    end

    test "returns an empty list when the user has no images", %{scope: scope} do
      assert Media.list_images(scope) == []
    end

    test "folder_id: returns only images in that folder", %{scope: scope} do
      folder = folder_fixture(scope)
      {:ok, in_folder} = Media.move_image(scope, image_fixture(scope), folder.id)
      _loose = image_fixture(scope)

      assert [%Image{id: id}] = Media.list_images(scope, folder_id: folder.id)
      assert id == in_folder.id
    end
  end

  describe "create_image/3" do
    test "stores the file and creates an image owned by the scope", %{scope: scope} do
      attrs = valid_image_attributes(title: "Sunset")

      assert {:ok, %Image{} = image} = Media.create_image(scope, png_path(), attrs)
      assert image.title == "Sunset"
      assert image.content_type == "image/png"
      assert image.user_id == scope.user.id
    end

    test "ignores user_id and storage fields in the params", %{scope: scope} do
      other = user_scope_fixture()
      attrs = valid_image_attributes(user_id: other.user.id, filename: "../../evil.html")

      assert {:ok, image} = Media.create_image(scope, png_path(), attrs)
      assert image.user_id == scope.user.id
      refute image.filename == "../../evil.html"
    end

    @tag :tmp_dir
    test "rejects a file that isn't an image", %{scope: scope, tmp_dir: dir} do
      path = Path.join(dir, "fake.png")
      File.write!(path, "<script>alert(1)</script>")

      assert {:error, :invalid_content} = Media.create_image(scope, path, valid_image_attributes())
    end

    test "with invalid attributes returns an error changeset", %{scope: scope} do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Media.create_image(scope, png_path(), %{title: ""})

      assert "can't be blank" in errors_on(changeset).title
    end
  end

  describe "update_image/3" do
    test "with valid attributes updates the image", %{scope: scope} do
      image = image_fixture(scope)

      assert {:ok, %Image{} = updated} = Media.update_image(scope, image, %{title: "Updated"})
      assert updated.title == "Updated"
    end
  end

  describe "move_image/3" do
    test "refuses a folder owned by someone else", %{scope: scope} do
      image = image_fixture(scope)
      foreign = folder_fixture(user_scope_fixture())

      assert_raise Ecto.NoResultsError, fn -> Media.move_image(scope, image, foreign.id) end
    end
  end

  describe "delete_image/2" do
    test "deletes the image", %{scope: scope} do
      image = image_fixture(scope)

      assert {:ok, %Image{}} = Media.delete_image(scope, image)
      assert_raise Ecto.NoResultsError, fn -> Media.get_image!(scope, image.id) end
    end

    test "can't reach another user's image", %{scope: scope} do
      image = image_fixture(user_scope_fixture())
      assert_raise Ecto.NoResultsError, fn -> Media.get_image!(scope, image.id) end
    end
  end
end
```

Compare by id (or `Repo.reload`) when the struct you hold and the one the query returns may differ in preloads or virtual fields.

---

## Schema and Changeset Tests

```elixir
defmodule MyApp.Media.ImageTest do
  use MyApp.DataCase, async: true

  alias MyApp.Media.Image
  import MyApp.AccountsFixtures, only: [user_scope_fixture: 0]

  # Storage fields are set on the struct by the upload code, never cast.
  @stored %Image{filename: "a.png", content_type: "image/png", byte_size: 1024}

  setup do
    %{scope: user_scope_fixture()}
  end

  test "valid attributes", %{scope: scope} do
    changeset = Image.changeset(@stored, %{title: "Test"}, scope)
    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :user_id) == scope.user.id
  end

  test "requires title", %{scope: scope} do
    changeset = Image.changeset(@stored, %{}, scope)
    assert %{title: ["can't be blank"]} = errors_on(changeset)
  end

  test "limits title length", %{scope: scope} do
    changeset = Image.changeset(@stored, %{title: String.duplicate("a", 256)}, scope)
    assert %{title: ["should be at most 255 character(s)"]} = errors_on(changeset)
  end

  test "does not cast storage fields", %{scope: scope} do
    changeset = Image.changeset(%Image{}, %{title: "T", filename: "x.html", byte_size: 1}, scope)
    assert %{filename: ["can't be blank"], byte_size: ["can't be blank"]} = errors_on(changeset)
  end
end
```

---

## LiveView Tests

The gallery lists images as a stream (`id="images"`, rows `images-<id>`), has a folder form and a per-image "move" form.

```elixir
defmodule MyAppWeb.GalleryLiveTest do
  use MyAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MyApp.MediaFixtures

  alias MyApp.Media

  setup :register_and_log_in_user

  test "displays the user's images only", %{conn: conn, scope: scope} do
    image = image_fixture(scope, title: "Sunset")
    other = image_fixture(MyApp.AccountsFixtures.user_scope_fixture(), title: "Not mine")

    {:ok, lv, _html} = live(conn, ~p"/gallery")

    assert has_element?(lv, "#images-#{image.id}", "Sunset")
    refute has_element?(lv, "#images-#{other.id}")
  end

  test "deletes an image", %{conn: conn, scope: scope} do
    image = image_fixture(scope, title: "To Delete")
    {:ok, lv, _html} = live(conn, ~p"/gallery")

    lv |> element("#images-#{image.id} button", "Delete") |> render_click()

    refute has_element?(lv, "#images-#{image.id}")
  end

  test "creates a folder", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/gallery")

    lv |> form("#folder-form", folder: %{name: "Vacation"}) |> render_submit()

    assert has_element?(lv, "#folders", "Vacation")
  end

  test "moves an image to a folder", %{conn: conn, scope: scope} do
    image = image_fixture(scope)
    folder = folder_fixture(scope, name: "Vacation")
    {:ok, lv, _html} = live(conn, ~p"/gallery")

    # The submit must carry the selection itself: render_submit/1 sends the form as
    # rendered, not what an earlier render_change sent.
    lv
    |> form("#move-image-#{image.id}", image: %{folder_id: folder.id})
    |> render_submit()

    assert Media.get_image!(scope, image.id).folder_id == folder.id
  end

  test "navigates to a folder", %{conn: conn, scope: scope} do
    folder = folder_fixture(scope, name: "Vacation")
    {:ok, lv, _html} = live(conn, ~p"/gallery")

    {:ok, folder_lv, _html} =
      lv
      |> element("#folders-#{folder.id} a")
      |> render_click()
      |> follow_redirect(conn, ~p"/gallery/folders/#{folder}")

    assert has_element?(folder_lv, "h1", "Vacation")
  end
end
```

`form/3` checks your data against the markup: the `<select>` must contain an option whose value is `folder.id` (integers are compared as strings), or it raises `ArgumentError`. That makes the test fail if the user's folders aren't offered.

### Async assigns, patches and hooks

```elixir
test "loads stats asynchronously", %{conn: conn} do
  {:ok, lv, html} = live(conn, ~p"/gallery")
  assert html =~ "Loading stats"
  assert render_async(lv, 500) =~ "images total"
end

test "sorting patches the URL", %{conn: conn} do
  {:ok, lv, _html} = live(conn, ~p"/gallery")
  lv |> element("a", "Newest first") |> render_click()
  assert_patch(lv, ~p"/gallery?sort=newest")
end

test "a JS hook reorders images", %{conn: conn, scope: scope} do
  [a, b] = [image_fixture(scope), image_fixture(scope)]
  {:ok, lv, _html} = live(conn, ~p"/gallery")

  render_hook(lv, "reorder", %{"ids" => [b.id, a.id]})

  assert [b.id, a.id] == Enum.map(Media.list_images(scope), & &1.id)
end
```

### Components and LiveViews without a route

`live_isolated/3` mounts a LiveView without the router, so the `live_session`'s `on_mount` hooks don't run: `@current_scope` is not assigned (a generated LiveView raises `KeyError`) unless the module declares its own `on_mount`. It suits self-contained LiveViews; pass extra data to `mount/3` with `:session`.

```elixir
{:ok, lv, _html} =
  live_isolated(conn, MyAppWeb.UploadDemoLive, session: %{"max_entries" => 3})
```

Function components can be rendered with `render_component/3`:

```elixir
assert render_component(&MyAppWeb.MediaComponents.status_badge/1, status: :draft) =~ "Draft"
```

---

## Upload Tests

`file_input/4` only builds the upload; nothing reaches the server until `render_upload/3`. On rejection `render_upload/3` returns `{:error, [[entry_ref, reason]]}` with `:not_accepted`, `:too_large` or `:too_many_files`, so assert on that return value instead of the rendered page.

```elixir
describe "uploads" do
  setup :register_and_log_in_user

  test "uploads and saves an image", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/gallery")

    upload =
      file_input(lv, "#upload-form", :images, [
        %{name: "test.png", content: File.read!("test/support/fixtures/test.png"), type: "image/png"}
      ])

    assert render_upload(upload, "test.png") =~ "100%"

    lv |> form("#upload-form", image: %{title: "Test Upload"}) |> render_submit()

    assert has_element?(lv, "#images img[alt='Test Upload']")
  end

  test "rejects a file type outside :accept", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/gallery")

    pdf =
      file_input(lv, "#upload-form", :images, [
        %{name: "test.pdf", content: "fake pdf", type: "application/pdf"}
      ])

    assert {:error, [[_ref, :not_accepted]]} = render_upload(pdf, "test.pdf")
  end

  test "rejects a file over :max_file_size", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/gallery")

    # allow_upload(:images, max_file_size: 10_000_000)
    large =
      file_input(lv, "#upload-form", :images, [
        %{name: "large.jpg", content: :binary.copy(<<0>>, 10_000_001), type: "image/jpeg"}
      ])

    assert {:error, [[_ref, :too_large]]} = render_upload(large, "large.jpg")
  end
end
```

`render_upload/3` does not consume the entry; call `render_submit` before asserting anything that `consume_uploaded_entries/3` does.

---

## Async Tests and the SQL Sandbox

`DataCase` and `ConnCase` call `Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: not tags[:async])`, so each async test gets its own transaction that is rolled back on exit.

```elixir
defmodule MyApp.Media.QueriesTest do
  use MyApp.DataCase, async: true   # DataCase has no conn — use ConnCase for HTTP/LiveView

  test "counts images per user" do
    scope = MyApp.AccountsFixtures.user_scope_fixture()
    MyApp.MediaFixtures.image_fixture(scope)
    assert MyApp.Media.count_images(scope) == 1
  end
end
```

Use `async: false` only when the test touches truly shared state:

- `Application.put_env/3` or other global config
- named processes, ETS tables or anything in the application's supervision tree
- Mox or `Req.Test` in global/shared mode
- the filesystem outside `@tag :tmp_dir`

### Processes outside the test tree

Which processes can use the test's sandbox connection in an async test:

| Process | Sandbox access |
|---|---|
| the test process | yes (owner) |
| `Task.async`/`Task.Supervisor` started from the test | yes, via `$callers` |
| LiveViews started by `live/2`; channels joined with `subscribe_and_join` | yes, via `$callers` |
| a GenServer started with `start_supervised!` | **no** — call `allow/3` |
| a process already running in the app tree (cache, PubSub listener) | **no** — `allow/3`, or `async: false` |

```elixir
test "the indexer reads the new image", %{scope: scope} do
  pid = start_supervised!(MyApp.Indexer)
  Ecto.Adapters.SQL.Sandbox.allow(MyApp.Repo, self(), pid)

  image = MyApp.MediaFixtures.image_fixture(scope)
  assert :ok = MyApp.Indexer.index(pid, image.id)
end
```

Without the allowance the GenServer fails with `DBConnection.OwnershipError` ("cannot find ownership process"). Browser-driven tests (Wallaby, PhoenixTest.Playwright) need `Phoenix.Ecto.SQL.Sandbox` in the endpoint to pass the owner through the user agent.

---

## Mox in Full

1. Add the dependency: `{:mox, "~> 1.2", only: :test}`.
2. Define a behaviour and route calls through a configured implementation:

```elixir
defmodule MyApp.Storage do
  @callback put(key :: String.t(), data :: binary()) :: {:ok, String.t()} | {:error, term()}
  @callback delete(key :: String.t()) :: :ok | {:error, term()}

  def put(key, data), do: impl().put(key, data)
  def delete(key), do: impl().delete(key)

  defp impl, do: Application.get_env(:my_app, :storage, MyApp.Storage.S3)
end

defmodule MyApp.Storage.S3 do
  @behaviour MyApp.Storage

  @impl true
  def put(key, _data) do
    # the real upload (Req / ExAws) goes here
    {:ok, "https://bucket.example/#{key}"}
  end

  @impl true
  def delete(_key), do: :ok
end
```

3. Swap it in tests and define the mock:

```elixir
# config/test.exs
config :my_app, :storage, MyApp.StorageMock

# test/test_helper.exs
Mox.defmock(MyApp.StorageMock, for: MyApp.Storage)
ExUnit.start()
```

4. Use it with `verify_on_exit!` so unmet expectations fail:

```elixir
defmodule MyApp.MediaStorageTest do
  use MyApp.DataCase, async: true

  import Mox

  setup :verify_on_exit!

  # Assumes a Media context whose store_file/1 and delete_image/2 go through MyApp.Storage.
  test "delete_image/2 removes the stored file" do
    scope = MyApp.AccountsFixtures.user_scope_fixture()
    stub(MyApp.StorageMock, :put, fn key, _data -> {:ok, "https://cdn.example/#{key}"} end)
    image = MyApp.MediaFixtures.image_fixture(scope)
    filename = image.filename

    expect(MyApp.StorageMock, :delete, fn ^filename -> :ok end)

    assert {:ok, _} = MyApp.Media.delete_image(scope, image)
  end
end
```

- `expect/4` must be called exactly N times; `stub/3` may be called any number of times. `stub_with(MyApp.StorageMock, MyApp.Storage.Fake)` stubs every callback from a module.
- Expectations belong to the test process. `Task`s inherit them via `$callers`; for a GenServer, `Mox.allow(MyApp.StorageMock, self(), pid)`. If you can't get the pid, use `setup :set_mox_from_context` with `async: false` (global mode).
- Prefer `Application.get_env/3` at call time over `Application.compile_env/3` when tests may need to swap the implementation per test.

---

## Req.Test in Full

With `plug: {Req.Test, MyApp.Weather}` (and `retry: false`) in the test config, as in the skill:

```elixir
defmodule MyApp.WeatherTest do
  use ExUnit.Case, async: true

  setup {Req.Test, :verify_on_exit!}

  test "sends the city and parses the reply" do
    Req.Test.expect(MyApp.Weather, fn conn ->
      assert conn.method == "GET"
      assert conn.params["city"] == "Lisbon"
      Req.Test.json(conn, %{"celsius" => 21.5})
    end)

    assert {:ok, 21.5} = MyApp.Weather.current("Lisbon")
  end

  test "maps a 503 to an error" do
    Req.Test.stub(MyApp.Weather, &Plug.Conn.send_resp(&1, 503, "down"))
    assert {:error, {:unexpected_response, 503}} = MyApp.Weather.current("Lisbon")
  end

  test "a transport error, then a good reply" do
    Req.Test.expect(MyApp.Weather, &Req.Test.transport_error(&1, :econnrefused))
    Req.Test.expect(MyApp.Weather, &Req.Test.json(&1, %{"celsius" => 3.0}))

    assert {:error, %Req.TransportError{}} = MyApp.Weather.current("Oslo")
    assert {:ok, 3.0} = MyApp.Weather.current("Oslo")
  end
end
```

`Req.Test.expect/3` registrations are consumed in order. Processes the test starts (`Task`, `start_supervised!`) find its stubs through `$callers`/`$ancestors`; for a process the application started, call `Req.Test.allow(MyApp.Weather, self(), pid)`.

---

## Property-Based Tests (StreamData)

Add `{:stream_data, "~> 1.1", only: [:dev, :test]}`. Good for parsers, encoders and invariants that should hold for any input.

```elixir
defmodule MyApp.SlugTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  property "slugify/1 output is URL-safe and idempotent" do
    check all title <- string(:printable, min_length: 1) do
      slug = MyApp.Slug.slugify(title)
      assert slug =~ ~r/\A[a-z0-9-]*\z/
      assert MyApp.Slug.slugify(slug) == slug
    end
  end
end
```

---

## Common Assertions

```elixir
assert {:ok, %Image{}} = result                      # pattern match
assert_raise Ecto.NoResultsError, fn -> Media.get_image!(scope, id) end
assert Repo.aggregate(Image, :count) == 1
assert "can't be blank" in errors_on(changeset).title

assert has_element?(lv, "#images-#{image.id}")       # LiveView structure
assert render(lv) =~ "Successfully created"          # flash text on the current page
assert_receive {:created, %Image{}}, 500            # PubSub / messages
refute_received {:deleted, _}
```

---

## Test Organization

```
test/
├── my_app/
│   ├── media_test.exs              # context tests
│   └── media/
│       └── image_test.exs          # schema/changeset tests
├── my_app_web/
│   ├── live/
│   │   └── gallery_live_test.exs
│   └── controllers/
│       └── page_controller_test.exs
├── support/
│   ├── conn_case.ex
│   ├── data_case.ex
│   └── fixtures/
│       ├── accounts_fixtures.ex    # generated by phx.gen.auth
│       ├── media_fixtures.ex
│       └── test.png
└── test_helper.exs                 # Mox.defmock calls go here
```
