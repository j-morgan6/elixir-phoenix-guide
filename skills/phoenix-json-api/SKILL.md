---
name: phoenix-json-api
description: MANDATORY for ALL JSON API work. Invoke before writing API controllers, pipelines, or JSON responses.
file_patterns:
  - "**/*_controller.ex"
  - "**/*_json.ex"
  - "**/router.ex"
auto_suggest: true
---

# Phoenix JSON API

## RULES — Follow these with no exceptions

1. **Use the `:api` pipeline** — don't mix HTML and JSON pipelines; API routes skip CSRF, sessions, and browser headers
2. **Render errors as structured JSON** — `{:error, changeset}` must become `{"errors": {...}}`; never return raw text or HTML errors
3. **Use offset/limit for pagination** — never return unbounded collections; default to a sensible limit (e.g., 20)
4. **Version APIs via URL prefix (`/api/v1/`)** — not headers; URL versioning is visible, cacheable, and debuggable
5. **Use `FallbackController` for consistent error handling** — every action returns `{:ok, result}` or `{:error, reason}`; the fallback renders errors
6. **Authenticate via Bearer tokens in `Authorization` header** — not cookies; API clients don't have browser sessions
7. **Use `json/2` helper** — ensures `Content-Type: application/json`; avoid `render` for simple JSON responses

---

## API Pipeline Setup

```elixir
# lib/my_app_web/router.ex
defmodule MyAppWeb.Router do
  use MyAppWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    # No :fetch_session, :protect_from_forgery, :put_secure_browser_headers
    # APIs use tokens, not sessions
  end

  pipeline :api_auth do
    plug MyAppWeb.Plugs.ApiAuth
  end

  # Public endpoints (no auth required)
  scope "/api/v1", MyAppWeb.API.V1, as: :api_v1 do
    pipe_through :api

    post "/auth/login", AuthController, :login
    post "/auth/register", AuthController, :register
  end

  # Protected endpoints
  scope "/api/v1", MyAppWeb.API.V1, as: :api_v1 do
    pipe_through [:api, :api_auth]

    resources "/posts", PostController, except: [:new, :edit]
    resources "/users", UserController, only: [:index, :show, :update]
  end
end
```

---

## Controller Pattern

Controllers return `{:ok, result}` or `{:error, reason}` — the FallbackController handles error rendering.

```elixir
defmodule MyAppWeb.API.V1.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog
  alias MyApp.Blog.Post

  action_fallback MyAppWeb.FallbackController

  def index(conn, params) do
    page = Map.get(params, "page", "1") |> String.to_integer()
    per_page = Map.get(params, "per_page", "20") |> String.to_integer() |> min(100)

    {posts, total} = Blog.list_posts(page: page, per_page: per_page)

    conn
    |> put_resp_header("x-total-count", to_string(total))
    |> json(%{
      data: Enum.map(posts, &post_json/1),
      meta: %{page: page, per_page: per_page, total: total}
    })
  end

  def show(conn, %{"id" => id}) do
    with {:ok, post} <- Blog.get_post(id) do
      json(conn, %{data: post_json(post)})
    end
  end

  def create(conn, %{"post" => post_params}) do
    with {:ok, %Post{} = post} <- Blog.create_post(post_params) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/api/v1/posts/#{post}")
      |> json(%{data: post_json(post)})
    end
  end

  def update(conn, %{"id" => id, "post" => post_params}) do
    with {:ok, post} <- Blog.get_post(id),
         {:ok, %Post{} = updated} <- Blog.update_post(post, post_params) do
      json(conn, %{data: post_json(updated)})
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, post} <- Blog.get_post(id),
         {:ok, _} <- Blog.delete_post(post) do
      send_resp(conn, :no_content, "")
    end
  end

  defp post_json(%Post{} = post) do
    %{
      id: post.id,
      title: post.title,
      body: post.body,
      inserted_at: post.inserted_at,
      updated_at: post.updated_at
    }
  end
end
```

**Bad:**
```elixir
# Mixing concerns — error handling inline, inconsistent responses
def show(conn, %{"id" => id}) do
  case Repo.get(Post, id) do
    nil -> conn |> put_status(404) |> text("Not found")
    post -> conn |> put_status(200) |> render("show.json", post: post)
  end
end
```

---

## FallbackController

Centralized error handling — every error gets a consistent JSON response.

```elixir
defmodule MyAppWeb.FallbackController do
  use MyAppWeb, :controller

  # Ecto changeset errors
  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: format_changeset_errors(changeset)})
  end

  # Not found
  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{errors: %{detail: "Not found"}})
  end

  # Unauthorized
  def call(conn, {:error, :unauthorized}) do
    conn
    |> put_status(:forbidden)
    |> json(%{errors: %{detail: "Forbidden"}})
  end

  # Generic error
  def call(conn, {:error, reason}) when is_binary(reason) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: reason}})
  end

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
```

**Context functions should return tagged tuples:**
```elixir
defmodule MyApp.Blog do
  def get_post(id) do
    case Repo.get(Post, id) do
      nil -> {:error, :not_found}
      post -> {:ok, post}
    end
  end
end
```

---

## Bearer Token Authentication

```elixir
defmodule MyAppWeb.Plugs.ApiAuth do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, user} <- MyApp.Accounts.verify_api_token(token) do
      assign(conn, :current_user, user)
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.json(%{errors: %{detail: "Unauthorized"}})
        |> halt()
    end
  end
end
```

**Token generation in the auth controller:**
```elixir
defmodule MyAppWeb.API.V1.AuthController do
  use MyAppWeb, :controller

  alias MyApp.Accounts

  def login(conn, %{"email" => email, "password" => password}) do
    case Accounts.authenticate_user(email, password) do
      {:ok, user} ->
        token = Accounts.generate_api_token(user)
        json(conn, %{data: %{token: token, user_id: user.id}})

      {:error, :invalid_credentials} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{errors: %{detail: "Invalid email or password"}})
    end
  end
end
```

---

## Pagination

Never return unbounded collections. Cap per_page to prevent abuse.

```elixir
defmodule MyApp.Blog do
  import Ecto.Query

  def list_posts(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 20) |> min(100)
    offset = (page - 1) * per_page

    posts =
      from(p in Post,
        order_by: [desc: p.inserted_at],
        limit: ^per_page,
        offset: ^offset
      )
      |> Repo.all()

    total = Repo.aggregate(Post, :count)

    {posts, total}
  end
end
```

**Response format:**
```json
{
  "data": [...],
  "meta": {
    "page": 1,
    "per_page": 20,
    "total": 142
  }
}
```

---

## API Versioning

Version via URL prefix. It's visible in logs, cacheable by CDNs, and simple to implement.

```elixir
# router.ex
scope "/api/v1", MyAppWeb.API.V1, as: :api_v1 do
  pipe_through [:api, :api_auth]
  resources "/posts", PostController, except: [:new, :edit]
end

# When v2 is needed, add a new scope
scope "/api/v2", MyAppWeb.API.V2, as: :api_v2 do
  pipe_through [:api, :api_auth]
  resources "/posts", PostController, except: [:new, :edit]
end
```

**Controller directory structure:**
```
lib/my_app_web/controllers/api/
├── v1/
│   ├── post_controller.ex
│   ├── user_controller.ex
│   └── auth_controller.ex
└── v2/
    └── post_controller.ex  # Only modules that changed
```

---

## JSON Rendering

For simple responses, use `json/2`. For complex or reusable serialization, use JSON views.

### Simple (json/2)

```elixir
# Direct — good for simple responses
json(conn, %{data: %{id: post.id, title: post.title}})
```

### JSON Views (for complex/reusable serialization)

```elixir
# lib/my_app_web/controllers/api/v1/post_json.ex
defmodule MyAppWeb.API.V1.PostJSON do
  alias MyApp.Blog.Post

  def index(%{posts: posts, meta: meta}) do
    %{data: for(post <- posts, do: data(post)), meta: meta}
  end

  def show(%{post: post}) do
    %{data: data(post)}
  end

  def data(%Post{} = post) do
    %{
      id: post.id,
      title: post.title,
      body: post.body,
      author: author_data(post.author),
      inserted_at: post.inserted_at,
      updated_at: post.updated_at
    }
  end

  defp author_data(nil), do: nil
  defp author_data(author) do
    %{id: author.id, name: author.name}
  end
end

# In controller — use render with the JSON view
def show(conn, %{"id" => id}) do
  with {:ok, post} <- Blog.get_post(id) do
    render(conn, :show, post: post)
  end
end
```

---

## Testing API Endpoints

```elixir
defmodule MyAppWeb.API.V1.PostControllerTest do
  use MyAppWeb.ConnCase

  setup %{conn: conn} do
    user = user_fixture()
    token = MyApp.Accounts.generate_api_token(user)

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")

    %{conn: conn, user: user}
  end

  describe "GET /api/v1/posts" do
    test "lists posts with pagination", %{conn: conn} do
      for _ <- 1..25, do: post_fixture()

      conn = get(conn, ~p"/api/v1/posts?page=1&per_page=10")
      response = json_response(conn, 200)

      assert length(response["data"]) == 10
      assert response["meta"]["total"] == 25
      assert response["meta"]["page"] == 1
    end
  end

  describe "POST /api/v1/posts" do
    test "creates post with valid data", %{conn: conn} do
      attrs = %{"post" => %{"title" => "Test", "body" => "Content"}}
      conn = post(conn, ~p"/api/v1/posts", attrs)

      assert %{"data" => %{"id" => id, "title" => "Test"}} = json_response(conn, 201)
      assert get_resp_header(conn, "location") == ["/api/v1/posts/#{id}"]
    end

    test "returns errors with invalid data", %{conn: conn} do
      attrs = %{"post" => %{"title" => ""}}
      conn = post(conn, ~p"/api/v1/posts", attrs)

      assert %{"errors" => errors} = json_response(conn, 422)
      assert errors["title"] != nil
    end
  end

  describe "unauthenticated requests" do
    test "returns 401 without token" do
      conn = build_conn()
      conn = get(conn, ~p"/api/v1/posts")

      assert json_response(conn, 401)["errors"]["detail"] == "Unauthorized"
    end
  end
end
```

---

See `ecto-essentials` skill for query and changeset patterns.
See `security-essentials` skill for token handling and auth security.
See `testing-essentials` skill for comprehensive testing patterns.
