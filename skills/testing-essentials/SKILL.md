---
name: testing-essentials
description: MANDATORY for ALL test files. Invoke before writing any _test.exs file.
file_patterns:
  - "**/*_test.exs"
  - "**/test/**/*.exs"
auto_suggest: true
---

# Testing Essentials

## RULES — Follow these with no exceptions

1. **Use `DataCase` for database tests, `ConnCase` for LiveView/controller tests** — never mix them
2. **Test both happy path AND error/invalid cases** for every function
3. **Use `async: true` only when tests don't touch shared state** or external services
4. **Define test data in fixtures** (`test/support/`) — never build it inline across multiple tests
5. **Use `has_element?/2` and `element/2` for LiveView assertions** — not `html =~ "text"` for structure checks
6. **Always test the unauthorized case** for any protected resource
7. **Test the public context interface**, not internal implementation details
8. **Use `describe` blocks** to group tests by function or behavior

---

## TDD Workflow

Write the failing test first. Run it to confirm it fails for the right reason. Implement the minimum code to make it pass. Never write implementation before the test exists.

```bash
mix test test/my_app/accounts_test.exs  # Should fail first
# ... implement ...
mix test test/my_app/accounts_test.exs  # Should pass
```

---

## Test Module Setup

### DataCase — for context and schema tests

```elixir
defmodule MyApp.AccountsTest do
  use MyApp.DataCase, async: true

  alias MyApp.Accounts
  import MyApp.AccountsFixtures
end
```

### ConnCase — for LiveView and controller tests

```elixir
defmodule MyAppWeb.UserLiveTest do
  use MyAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MyApp.AccountsFixtures
end
```

---

## Fixture Pattern

Define all test data in `test/support/fixtures/`:

```elixir
defmodule MyApp.AccountsFixtures do
  def user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> Enum.into(%{
        email: "user#{System.unique_integer([:positive])}@example.com",
        password: "hello world!"
      })
      |> MyApp.Accounts.register_user()

    user
  end
end
```

---

## Context Test Skeleton

```elixir
describe "create_post/1" do
  test "with valid attrs creates a post" do
    assert {:ok, %Post{title: "Hello"}} = Blog.create_post(%{title: "Hello"})
  end

  test "with invalid attrs returns error changeset" do
    assert {:error, %Ecto.Changeset{}} = Blog.create_post(%{})
  end
end
```

---

## LiveView Test Skeleton

```elixir
describe "index" do
  test "lists posts", %{conn: conn} do
    post = post_fixture()
    {:ok, _lv, html} = live(conn, ~p"/posts")
    assert html =~ post.title
  end

  test "unauthorized user is redirected", %{conn: conn} do
    {:error, {:redirect, %{to: path}}} = live(conn, ~p"/admin/posts")
    assert path == ~p"/login"
  end
end

describe "create" do
  test "saves post with valid attrs", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/posts/new")

    lv
    |> form("#post-form", post: %{title: "New Post"})
    |> render_submit()

    assert has_element?(lv, "p", "Post created")
  end

  test "shows errors with invalid attrs", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/posts/new")

    lv
    |> form("#post-form", post: %{title: ""})
    |> render_submit()

    assert has_element?(lv, "p.alert", "can't be blank")
  end
end
```

---

## Changeset Test Skeleton

```elixir
describe "changeset/2" do
  test "valid attrs" do
    assert %Ecto.Changeset{valid?: true} = Post.changeset(%Post{}, %{title: "Hello"})
  end

  test "requires title" do
    changeset = Post.changeset(%Post{}, %{})
    assert %{title: ["can't be blank"]} = errors_on(changeset)
  end
end
```

---

See `testing-guide.md` for comprehensive examples covering async tests, Mox mocking, file upload testing, and Ecto query testing.