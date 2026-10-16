---
name: testing-essentials
description: "Use when writing or fixing ExUnit tests — DataCase/ConnCase, generated fixtures and scopes, LiveView test helpers, uploads, Mox and Req.Test stubs, async and sandbox rules."
---

# Testing Essentials

> Verified against Elixir 1.20, Phoenix 1.8, LiveView 1.2, Ecto 3.14, Req 0.7 — October 2026

For longer worked examples (a full context + LiveView suite, uploads, Mox wiring, sandbox allowances, StreamData), read the [testing reference](reference.md) when the patterns below aren't enough.

## RULES — Follow these with no exceptions

1. **Follow the project's existing test setup patterns** (e.g. shared setup helpers like `setup :store_test_session`) — don't inline DataCase/ConnCase boilerplate that the project already abstracts away
2. **Test both happy path AND error/invalid cases** for every function
3. **Prefer `async: true` — it is safe under the Ecto SQL Sandbox**, for DataCase and ConnCase/LiveView tests alike. Opt out only for real shared state: `Application.put_env`, named or app-supervised processes, Mox/Req.Test global mode. (Generators are inconsistent: phx.gen.auth's web tests are async, but its `accounts_test.exs` and the phx.gen.live / phx.gen.context tests aren't — add it.)
4. **Use the generated fixtures and scopes** — `user_fixture/1`, `user_scope_fixture/0`, `post_fixture(scope, attrs)`, and `setup :register_and_log_in_user` (puts `conn`, `user` and `scope` in the context). New fixtures go in `test/support/fixtures/`, never inline across tests
5. **Test authorization both ways** — guests are redirected to `~p"/users/log-in"`, and a record created under one scope can't be read or changed through another
6. **Assert LiveView structure with `has_element?/3`**, not `html =~` on markup. When an event navigates, pipe into `follow_redirect/2` and assert on the page you land on — the old view is gone
7. **Mock only at boundaries** — Mox against a behaviour with `setup :verify_on_exit!`; HTTP through `Req.Test` stubs. Never mock your own contexts or Repo
8. **Never `Process.sleep/1`** — use `assert_receive`, `render_async/2`, `start_supervised!/1`
9. **Test the public context interface**, not private helpers or internal state
10. **Use `describe` blocks** to group tests by function or behavior

---

## TDD Workflow

Write the failing test first, run it, confirm it fails for the right reason, then implement the minimum to pass.

```bash
mix test test/my_app/blog_test.exs:42   # one test by line
mix test --failed                       # re-run only last run's failures
mix test --stale                        # only tests affected by changed modules
mix test --warnings-as-errors           # fail on compile warnings in test files (CI)
```

---

## Case Templates

`DataCase` (context and schema tests) has no `conn`. `ConnCase` (controllers, LiveViews) builds one and checks out the sandbox. Both call `setup_sandbox/1`, which starts a sandbox owner per test — that's why `async: true` is safe.

```elixir
defmodule MyApp.BlogTest do
  use MyApp.DataCase, async: true

  alias MyApp.Blog
  import MyApp.AccountsFixtures, only: [user_scope_fixture: 0]
  import MyApp.BlogFixtures
end

defmodule MyAppWeb.PostLiveTest do
  use MyAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MyApp.BlogFixtures
end
```

---

## Fixtures

Follow the shape `phx.gen.context` emits with scopes: the scope comes first, attrs merge over defaults, the record goes through the real context function.

```elixir
defmodule MyApp.BlogFixtures do
  def post_fixture(scope, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{title: "some title", body: "some body"})
    {:ok, post} = MyApp.Blog.create_post(scope, attrs)
    post
  end
end
```

phx.gen.auth (1.8) registration is email-only. `user_fixture/1` already confirms the user via magic link; use `unconfirmed_user_fixture/1` for the unconfirmed case and `set_password/1` when a test needs a password. When you add a field to users, add it to `valid_user_attributes/1` — don't write a new user fixture.

Fixtures for a custom scope entry (`org_scope_fixture/0`, its `test_setup_helper`) are in the `phoenix-scopes-and-generators` skill.

---

## Context Test Skeleton

```elixir
describe "posts" do
  test "list_posts/1 returns only the scope's posts" do
    scope = user_scope_fixture()
    other_scope = user_scope_fixture()
    post = post_fixture(scope)
    _other = post_fixture(other_scope)

    assert Blog.list_posts(scope) == [post]
  end

  test "get_post!/2 raises for another user's post" do
    post = post_fixture(user_scope_fixture())
    assert_raise Ecto.NoResultsError, fn -> Blog.get_post!(user_scope_fixture(), post.id) end
  end

  test "create_post/2 with valid attrs sets the owner from the scope" do
    scope = user_scope_fixture()
    assert {:ok, %Post{} = post} = Blog.create_post(scope, %{title: "Hello", body: "Hi"})
    assert post.user_id == scope.user.id
  end

  test "create_post/2 with invalid attrs returns an error changeset" do
    assert {:error, %Ecto.Changeset{} = changeset} = Blog.create_post(user_scope_fixture(), %{})
    assert %{title: ["can't be blank"]} = errors_on(changeset)
  end
end
```

---

## LiveView Test Skeleton

Mirrors `phx.gen.live`'s `live_test.exs`. `render_change/1` returns HTML, so the apostrophe is escaped (`can&#39;t`). A submit that navigates must be followed; the flash is on the new page.

```elixir
defmodule MyAppWeb.PostLiveTest do
  use MyAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MyApp.BlogFixtures

  setup :register_and_log_in_user

  defp create_post(%{scope: scope}), do: %{post: post_fixture(scope)}

  test "redirects guests to log in" do
    assert {:error, {:redirect, %{to: path}}} = live(build_conn(), ~p"/posts")
    assert path == ~p"/users/log-in"
  end

  describe "Index" do
    setup [:create_post]

    test "lists the user's posts", %{conn: conn, post: post} do
      {:ok, lv, _html} = live(conn, ~p"/posts")
      assert has_element?(lv, "#posts-#{post.id}", post.title)
    end

    test "deletes a post", %{conn: conn, post: post} do
      {:ok, lv, _html} = live(conn, ~p"/posts")
      lv |> element("#posts-#{post.id} a", "Delete") |> render_click()
      refute has_element?(lv, "#posts-#{post.id}")
    end
  end

  describe "Form" do
    test "validates, then saves and redirects", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/posts/new")

      assert lv
             |> form("#post-form", post: %{title: nil})
             |> render_change() =~ "can&#39;t be blank"

      assert {:ok, index_lv, _html} =
               lv
               |> form("#post-form", post: %{title: "New Post", body: "Body"})
               |> render_submit()
               |> follow_redirect(conn, ~p"/posts")

      html = render(index_lv)
      assert html =~ "Post created successfully"
      assert html =~ "New Post"
    end
  end
end
```

`<.input>` errors render as `<p class="... text-error">` in 1.8's `core_components.ex`, so a structural check is `has_element?(lv, "#post-form p.text-error", "can't be blank")` — `has_element?/3` matches decoded text, so no `&#39;` there.

### LiveViewTest helpers worth knowing

| Helper | Use |
|---|---|
| `render_async(lv)` | Await `assign_async`/`start_async`/`stream_async`, then render. Default timeout is 100 ms — pass a larger one for slow work |
| `assert_patch(lv, path)` | After a `push_patch` (same LiveView). Returns the path when called without one |
| `assert_redirect(lv, path)` | After `push_navigate` or `redirect` from an event; returns the flash map |
| `follow_redirect(result, conn)` | Mount the destination from a `{:error, {:redirect, _}}` result of `live/2` or a `render_*` call |
| `render_hook(lv, "event", params)` | Fire an event that a JS hook would push (no DOM element needed) |
| `live_isolated(conn, MyLive, session: %{})` | Mount a LiveView without a route — good for components and uploads |
| `open_browser(lv)` | Debug only: dumps current HTML to a browser. Never commit it |
| `form(lv, sel, data)` | Validates `data` against the form's markup: unknown fields, disabled inputs and select values not in the options raise `ArgumentError` |

`render_submit/1` sends the form's values *as currently rendered* plus what you gave `form/3` — not what an earlier `render_change` sent. Values survive only if the server re-rendered them into the inputs (`<.input field={@form[:x]}>` does; a `<select>` rendered without `selected` doesn't). Pass the full params to `form/3` on the submit too.

LiveView 1.1+ parses test HTML with **LazyHTML**, not Floki — `phx.new` adds `{:lazy_html, ">= 0.1.0", only: :test}`. Keep Floki as a dependency only if your own tests call `Floki` directly; prefer `has_element?/3` over hand-parsing.

---

## Changeset Test Skeleton

```elixir
describe "changeset/3" do
  test "requires title" do
    changeset = Post.changeset(%Post{}, %{}, user_scope_fixture())
    assert %{title: ["can't be blank"]} = errors_on(changeset)
  end
end
```

---

## Mocks: Mox at Behaviour Boundaries

Mox needs three pieces: a behaviour the real module implements, a config switch, and the mock defined in `test/test_helper.exs`. Without `setup :verify_on_exit!`, a `expect` that is never called passes silently.

```elixir
# lib/my_app/storage.ex — callers use MyApp.Storage.put/2, never the impl directly
defmodule MyApp.Storage do
  @callback put(key :: String.t(), data :: binary()) :: {:ok, String.t()} | {:error, term()}

  def put(key, data), do: impl().put(key, data)

  defp impl, do: Application.get_env(:my_app, :storage, MyApp.Storage.S3)
end

# config/test.exs:      config :my_app, :storage, MyApp.StorageMock
# test/test_helper.exs: Mox.defmock(MyApp.StorageMock, for: MyApp.Storage)

defmodule MyApp.AvatarsTest do
  use MyApp.DataCase, async: true

  import Mox

  setup :verify_on_exit!

  test "stores the avatar under the user's key" do
    scope = MyApp.AccountsFixtures.user_scope_fixture()

    expect(MyApp.StorageMock, :put, fn "avatars/" <> _, _data -> {:ok, "https://cdn.example/a.png"} end)

    assert {:ok, user} = MyApp.Avatars.update(scope, "png-bytes")
    assert user.avatar_url == "https://cdn.example/a.png"
  end
end
```

Mox expectations are per-process. Calls from `Task`s and LiveViews started by the test are allowed automatically (`$callers`); for any other process use `Mox.allow(MyApp.StorageMock, self(), pid)`. Full wiring in the [testing reference](reference.md).

---

## HTTP: Req.Test Stubs

Req is Phoenix 1.8's default HTTP client. Route requests through a named `Req.Test` plug in test config; stubs are per-test and async-safe.

```elixir
# lib/my_app/weather.ex (trimmed; the full client is in the http-clients-req skill)
defmodule MyApp.Weather do
  def current(city) do
    req_options = :my_app |> Application.get_env(__MODULE__, []) |> Keyword.get(:req_options, [])

    [base_url: "https://api.weather.example", url: "/v1/current", params: [city: city]]
    |> Keyword.merge(req_options)
    |> Req.request()
    |> case do
      {:ok, %Req.Response{status: 200, body: %{"celsius" => celsius}}} -> {:ok, celsius}
      {:ok, %Req.Response{status: status}} -> {:error, {:unexpected_response, status}}
      {:error, exception} -> {:error, exception}
    end
  end
end

# config/test.exs — retry: false or transport-error tests sleep through Req's backoff
# config :my_app, MyApp.Weather, req_options: [plug: {Req.Test, MyApp.Weather}, retry: false]

defmodule MyApp.WeatherTest do
  use ExUnit.Case, async: true

  test "parses the temperature" do
    Req.Test.stub(MyApp.Weather, fn conn -> Req.Test.json(conn, %{"celsius" => 21.5}) end)
    assert {:ok, 21.5} = MyApp.Weather.current("Lisbon")
  end

  test "surfaces transport errors" do
    Req.Test.stub(MyApp.Weather, &Req.Test.transport_error(&1, :timeout))
    assert {:error, %Req.TransportError{reason: :timeout}} = MyApp.Weather.current("Lisbon")
  end
end
```

Use `Req.Test.expect/3` + `setup {Req.Test, :verify_on_exit!}` when the number of calls matters. Client design, retry policy, allowances for app-started processes and Finch pools are in the `http-clients-req` skill.

---

## Processes, Logs, Files

```elixir
test "counter starts at zero" do
  # Stopped after the test. Unnamed, so async tests (and an app-started
  # MyApp.Counter) don't collide; pass a unique name if the API needs one.
  pid = start_supervised!({MyApp.Counter, name: nil})
  assert MyApp.Counter.value(pid) == 0
end

@tag :capture_log                                       # hide expected error logs
test "logs and returns an error on bad input" do
  assert {:error, :invalid} = MyApp.Importer.run("garbage")
end

test "warns about the retry" do
  log = ExUnit.CaptureLog.capture_log(fn -> MyApp.Importer.run("retry-me") end)
  assert log =~ "retrying"
end

@tag :tmp_dir                                           # unique dir per test, in context
test "writes the export", %{tmp_dir: dir} do
  path = Path.join(dir, "out.csv")
  :ok = MyApp.Export.write(path)
  assert File.exists?(path)
end
```

**Sandbox allowances.** The SQL sandbox connection belongs to the test process. `Task`s and LiveViews started from the test inherit it via `$callers`; a GenServer (even one from `start_supervised!`) or anything already running in the application tree does not, and fails with `DBConnection.OwnershipError` in async tests. Allow it explicitly:

```elixir
pid = start_supervised!(MyApp.Indexer)
Ecto.Adapters.SQL.Sandbox.allow(MyApp.Repo, self(), pid)
```

---

## Email and Jobs

`phx.new` configures `Swoosh.Adapters.Test` in `config/test.exs`. It sends `{:email, email}` to the delivering process and its `$callers`, so mail sent from a LiveView or `Task` under test reaches the test process.

```elixir
import Swoosh.TestAssertions

test "sends the invite" do
  {:ok, _} = MyApp.Teams.invite(user_scope_fixture(), "new@example.com")
  assert_email_sent(to: "new@example.com", subject: "You're invited")
end
```

For Oban jobs (`Oban.Testing`, `assert_enqueued`, `perform_job/2`), see the `oban-essentials` skill.

---

## Parameterized Tests (Elixir 1.18+)

Run a whole module once per parameter map; each map is merged into the test context. With `async: true` the parameter sets run concurrently.

```elixir
defmodule MyApp.CacheTest do
  use ExUnit.Case,
    async: true,
    parameterize: [%{adapter: MyApp.Cache.ETS}, %{adapter: MyApp.Cache.Mnesia}]

  test "round-trips a value", %{adapter: adapter} do
    :ok = adapter.put(:k, 1)
    assert adapter.get(:k) == 1
  end
end
```

For property-based tests (`use ExUnitProperties`, `check all`), see the [testing reference](reference.md).

---

## Timestamp Testing

Never hardcode dates — use relative timestamps so tests don't rot.

<!-- epg:bad -->
```elixir
# Bad — breaks after 2026
assert post.published_at == ~U[2026-01-15 12:00:00Z]
```

```elixir
# Good — within 5 seconds of now (abs: inserted_at is in the past, so the diff is negative)
assert abs(DateTime.diff(post.inserted_at, DateTime.utc_now(), :second)) < 5

# Good — relative dates for filtering/sorting
past = DateTime.add(DateTime.utc_now(:second), -7, :day)
future = DateTime.add(DateTime.utc_now(:second), 7, :day)
old_post = post_fixture(scope, published_at: past)
_future_post = post_fixture(scope, published_at: future)
assert Blog.list_published_posts(scope) == [old_post]
```
