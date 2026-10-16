---
name: phoenix-json-api
description: "Use when building JSON API endpoints — :api pipeline, phx.gen.json-style JSON views, FallbackController, pagination, Bearer tokens, rate limits, CORS. Not for HTML/LiveView controllers."
---

# Phoenix JSON API

> Verified against Elixir 1.20, Phoenix 1.8, Ecto 3.14 — October 2026

## RULES — Follow these with no exceptions

1. **Use the `:api` pipeline** — `plug :accepts, ["json"]`, no session, CSRF or browser headers; API clients authenticate with tokens
2. **Pass `conn.assigns.current_scope` as the first argument to every context call** — `Blog.get_post!(scope, id)` loads by id *and* owner; loading or deleting by a client-supplied id alone is an IDOR
3. **Follow `phx.gen.json`** — `action_fallback`, `render(conn, :show, post: post)` with a `PostJSON` module, `ChangesetJSON` for validation errors; `json/2` is fine for one-off bodies
4. **The `FallbackController` handles every error your contexts return, plus a catch-all 500** — an unmatched `{:error, _}` otherwise raises `FunctionClauseError`; never put `inspect(reason)` in the response body
5. **Never return unbounded collections** — parse `page`/`per_page` with `Integer.parse/1` and clamp (`1..100`); order by a unique tiebreaker (`desc: p.id`); use keyset pagination for large or fast-changing tables
6. **Bearer tokens are random, stored hashed, expire, and are revocable** — follow the generated `UserToken` pattern; never store or compare plaintext tokens
7. **Rate-limit login and token endpoints, and keep failures indistinguishable** — same error for unknown email and wrong password; the generated `get_user_by_email_and_password/2` already calls `Bcrypt.no_user_verify/0` for unknown users
8. **Preload every association the JSON view renders** — in the context function, not the view; `post.user` on an unloaded association is `%Ecto.Association.NotLoaded{}` (and the generated `Post` has no `belongs_to :user` until you add one)
9. **Version via URL prefix (`/api/v1`)** — no `as:` option needed; Phoenix 1.8 apps use verified routes, not router helpers

---

## Router

```elixir
# lib/my_app_web/router.ex
pipeline :api do
  plug :accepts, ["json"]
end

pipeline :api_auth do
  plug MyAppWeb.Plugs.ApiAuth
end

scope "/api/v1", MyAppWeb.API.V1 do
  pipe_through :api

  post "/tokens", TokenController, :create
end

scope "/api/v1", MyAppWeb.API.V1 do
  pipe_through [:api, :api_auth]

  resources "/posts", PostController, except: [:new, :edit]
end
```

When v2 is needed, add `scope "/api/v2", MyAppWeb.API.V2` and put only the controllers that changed under `controllers/api/v2/`.

---

## Controller (generator shape, scoped)

`phx.gen.json` with scopes generates exactly this shape. `get_post!/2` raises `Ecto.NoResultsError`, which `phoenix_ecto` turns into a 404 rendered by `ErrorJSON` — for another user's post as well as a missing one. Generated scoped controllers and their tests assume a pipeline that assigns `:current_scope`; see the `phoenix-scopes-and-generators` skill.

```elixir
defmodule MyAppWeb.API.V1.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog
  alias MyApp.Blog.Post

  action_fallback MyAppWeb.FallbackController

  def index(conn, params) do
    page = parse_pos_int(params["page"], 1)
    per_page = params["per_page"] |> parse_pos_int(20) |> min(100)

    {posts, total} = Blog.paginate_posts(conn.assigns.current_scope, page: page, per_page: per_page)

    render(conn, :index, posts: posts, meta: %{page: page, per_page: per_page, total: total})
  end

  def create(conn, %{"post" => post_params}) do
    with {:ok, %Post{} = post} <- Blog.create_post(conn.assigns.current_scope, post_params) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/api/v1/posts/#{post}")
      |> render(:show, post: post)
    end
  end

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(conn.assigns.current_scope, id)
    render(conn, :show, post: post)
  end

  def update(conn, %{"id" => id, "post" => post_params}) do
    scope = conn.assigns.current_scope
    post = Blog.get_post!(scope, id)

    with {:ok, %Post{} = post} <- Blog.update_post(scope, post, post_params) do
      render(conn, :show, post: post)
    end
  end

  def delete(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope
    post = Blog.get_post!(scope, id)

    with {:ok, %Post{}} <- Blog.delete_post(scope, post) do
      send_resp(conn, :no_content, "")
    end
  end

  # "abc", "0", "-5" and per_page[]=1 all fall back to the default instead of a 500
  defp parse_pos_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_pos_int(_value, default), do: default
end
```

<!-- epg:bad -->
```elixir
# IDOR: any authenticated user can read or delete any post by guessing ids
def delete(conn, %{"id" => id}) do
  post = Repo.get!(Post, id)
  {:ok, _} = Repo.delete(post)
  send_resp(conn, :no_content, "")
end

# 500 on "abc"; 0 or a negative value reaches LIMIT and Postgres errors
per_page = String.to_integer(params["per_page"])
```

---

## JSON Views

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

  defp data(%Post{} = post) do
    %{
      id: post.id,
      title: post.title,
      body: post.body,
      user_id: post.user_id,
      inserted_at: post.inserted_at
    }
  end
end
```

To render an association (say the author of a post in a shared feed), the schema needs it: the generated `Post` has `field :user_id, :id`, so replace that with `belongs_to :user, MyApp.Accounts.User` (the changeset's `put_change(:user_id, scope.user.id)` keeps working). Then preload `:user` in **every** context function whose result reaches the view (`get_post!/2`, create and update too, e.g. `Repo.preload(post, :user)`), and match a loaded struct in the view so a missed preload fails loudly instead of rendering `%Ecto.Association.NotLoaded{}`:

```elixir
defp author(%MyApp.Accounts.User{} = user), do: %{id: user.id, email: user.email}
```

Choosing preload strategies and spotting N+1 queries: see the `ecto-queries-performance` skill.

List exactly the fields you expose. Never encode a schema struct directly (`@derive Jason.Encoder` without `only:`): the next field someone adds (`hashed_password`, `role`) ships to clients.

---

## FallbackController

```elixir
defmodule MyAppWeb.FallbackController do
  use MyAppWeb, :controller

  alias Plug.Conn.Status

  require Logger

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: MyAppWeb.ChangesetJSON)
    |> render(:error, changeset: changeset)
  end

  def call(conn, {:error, :not_found}), do: error(conn, :not_found)
  def call(conn, {:error, :unauthorized}), do: error(conn, :unauthorized)
  def call(conn, {:error, :forbidden}), do: error(conn, :forbidden)

  def call(conn, {:error, {:rate_limited, retry_after_ms}}) do
    conn
    |> put_resp_header("retry-after", to_string(div(retry_after_ms, 1000) + 1))
    |> error(:too_many_requests)
  end

  # Catch-all: log the reason, return a generic 500 body
  def call(conn, {:error, reason}) do
    Logger.error("Unhandled API error: #{inspect(reason)}")
    error(conn, :internal_server_error)
  end

  # Same body shape as the generated ErrorJSON: %{errors: %{detail: "Not Found"}}
  defp error(conn, status) do
    code = Status.code(status)

    conn
    |> put_status(code)
    |> json(%{errors: %{detail: Status.reason_phrase(code)}})
  end
end
```

`ChangesetJSON` is generated the first time you run `phx.gen.json`. If you hand-write the API, add it:

```elixir
defmodule MyAppWeb.ChangesetJSON do
  def error(%{changeset: changeset}) do
    %{errors: Ecto.Changeset.traverse_errors(changeset, &MyAppWeb.CoreComponents.translate_error/1)}
  end
end
```

If clients need machine-readable errors, render [RFC 9457](https://www.rfc-editor.org/rfc/rfc9457) problem details instead (`type`, `title`, `status`, `detail`, content type `application/problem+json`) — pick one error shape and use it for every error, including the 404/500 that `ErrorJSON` renders for exceptions.

---

## Bearer Token Authentication

Store a SHA-256 hash of a random token, like the generated magic-link tokens. A database dump then contains no usable tokens, and a lookup by hash needs no constant-time comparison.

```elixir
# lib/my_app/accounts/user_token.ex — add next to the generated builders
@api_token_validity_in_days 30

def build_api_token(user) do
  token = :crypto.strong_rand_bytes(@rand_size)

  {Base.url_encode64(token, padding: false),
   %UserToken{token: :crypto.hash(@hash_algorithm, token), context: "api", user_id: user.id}}
end

def verify_api_token_query(token) do
  case Base.url_decode64(token, padding: false) do
    {:ok, decoded} ->
      query =
        from t in by_token_and_context_query(:crypto.hash(@hash_algorithm, decoded), "api"),
          join: user in assoc(t, :user),
          where: t.inserted_at > ago(@api_token_validity_in_days, "day"),
          select: user

      {:ok, query}

    :error ->
      :error
  end
end
```

```elixir
# lib/my_app/accounts.ex
def create_user_api_token(%User{} = user) do
  {encoded, user_token} = UserToken.build_api_token(user)
  Repo.insert!(user_token)
  encoded
end

def fetch_user_by_api_token(token) do
  with {:ok, query} <- UserToken.verify_api_token_query(token),
       %User{} = user <- Repo.one(query) do
    {:ok, user}
  else
    _ -> :error
  end
end
```

Revoke with `Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: "api"]))`. The generated password change already deletes every token of the user, API tokens included.

```elixir
defmodule MyAppWeb.Plugs.ApiAuth do
  import Plug.Conn

  alias MyApp.Accounts
  alias MyApp.Accounts.Scope

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, user} <- Accounts.fetch_user_by_api_token(token) do
      assign(conn, :current_scope, Scope.for_user(user))
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

### Issuing tokens (rate-limited)

```elixir
defmodule MyAppWeb.API.V1.TokenController do
  use MyAppWeb, :controller

  alias MyApp.Accounts
  alias MyApp.Accounts.User

  action_fallback MyAppWeb.FallbackController

  def create(conn, %{"email" => email, "password" => password}) do
    key = "api-login:#{:inet.ntoa(conn.remote_ip)}"

    with {:allow, _count} <- MyApp.RateLimit.hit(key, :timer.minutes(1), 10),
         %User{} = user <- Accounts.get_user_by_email_and_password(email, password) do
      conn
      |> put_status(:created)
      |> json(%{data: %{token: Accounts.create_user_api_token(user)}})
    else
      {:deny, retry_after_ms} -> {:error, {:rate_limited, retry_after_ms}}
      # One response for unknown email and wrong password
      nil -> {:error, :unauthorized}
    end
  end
end
```

`MyApp.RateLimit` is a [Hammer](https://hex.pm/packages/hammer) 7 module: `defmodule MyApp.RateLimit, do: use(Hammer, backend: :ets)`, started in your supervision tree as `{MyApp.RateLimit, clean_period: :timer.minutes(1)}`. The ETS backend counts per node; use a shared backend (Redis) when you run several nodes. Behind a proxy, `conn.remote_ip` is the proxy's address unless you rewrite it from `x-forwarded-for` (only when you trust the proxy).

---

## Pagination

Ordering by `inserted_at` alone is not stable — rows with equal timestamps swap between pages, so OFFSET pagination skips or duplicates them. Always add a unique tiebreaker.

```elixir
# lib/my_app/blog.ex
def paginate_posts(%Scope{} = scope, opts) do
  page = Keyword.fetch!(opts, :page)
  per_page = Keyword.fetch!(opts, :per_page)
  base = from(p in Post, where: p.user_id == ^scope.user.id)

  posts =
    from(p in base,
      order_by: [desc: p.inserted_at, desc: p.id],
      limit: ^per_page,
      offset: ^((page - 1) * per_page)
    )
    |> Repo.all()

  {posts, Repo.aggregate(base, :count)}
end
```

**Keyset (cursor) pagination** — use it for large tables, infinite scroll, or data that changes while clients page. Cost doesn't grow with page depth and inserts don't shift pages. Return the last row's `{inserted_at, id}` as an opaque cursor, and decode and validate it like any other param.

```elixir
def list_posts_after(%Scope{} = scope, cursor, limit) do
  query =
    from(p in Post,
      where: p.user_id == ^scope.user.id,
      order_by: [desc: p.inserted_at, desc: p.id],
      limit: ^limit
    )

  query =
    case cursor do
      nil ->
        query

      {inserted_at, id} ->
        from(p in query,
          where: p.inserted_at < ^inserted_at or (p.inserted_at == ^inserted_at and p.id < ^id)
        )
    end

  Repo.all(query)
end
```

Back it with an index on `(user_id, inserted_at, id)`.

---

## Production Concerns

- **CORS** — only needed when browsers on another origin call the API. Use [Corsica](https://hex.pm/packages/corsica) in the **endpoint**, before the router, so preflight `OPTIONS` requests get an answer before routing:
  ```elixir
  plug Corsica,
    origins: ["https://app.example.com"],
    allow_headers: ["authorization", "content-type"],
    allow_methods: ["GET", "POST", "PUT", "PATCH", "DELETE"]
  ```
  Never `origins: "*"` on an API that reads cookies.
- **Body size** — `Plug.Parsers` defaults to `length: 8_000_000` (8 MB) for every parser. Lower it in the endpoint for JSON-only APIs, and raise it only for multipart: `parsers: [:urlencoded, {:multipart, length: 20_000_000}, :json]`.
- **Idempotency keys** — for non-idempotent POSTs that clients retry (payments, orders), accept an `Idempotency-Key` header, store it with a unique index scoped to the user, and return the stored response on a repeat instead of creating a second record.
- **OpenAPI** — [OpenApiSpex](https://hex.pm/packages/open_api_spex) generates the spec from controller `operation` macros (`use OpenApiSpex.ControllerSpecs`), and its `OpenApiSpex.Plug.CastAndValidate` plug validates requests against that spec.

---

## Testing API Endpoints

```elixir
defmodule MyAppWeb.API.V1.PostControllerTest do
  use MyAppWeb.ConnCase

  import MyApp.AccountsFixtures
  import MyApp.BlogFixtures

  setup %{conn: conn} do
    scope = user_scope_fixture()
    token = MyApp.Accounts.create_user_api_token(scope.user)

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")

    %{conn: conn, scope: scope}
  end

  test "paginates the caller's posts only", %{conn: conn, scope: scope} do
    for _ <- 1..25, do: post_fixture(scope)
    _other = post_fixture(user_scope_fixture())

    response = conn |> get(~p"/api/v1/posts?page=1&per_page=10") |> json_response(200)

    assert length(response["data"]) == 10
    assert response["meta"]["total"] == 25
  end

  test "garbage per_page falls back to the default", %{conn: conn} do
    assert %{"meta" => %{"per_page" => 20}} =
             conn |> get(~p"/api/v1/posts?per_page=abc") |> json_response(200)
  end

  test "another user's post is a 404", %{conn: conn} do
    other = post_fixture(user_scope_fixture())

    assert_error_sent 404, fn -> get(conn, ~p"/api/v1/posts/#{other}") end
  end

  test "returns 422 with errors on invalid data", %{conn: conn} do
    conn = post(conn, ~p"/api/v1/posts", post: %{title: ""})
    assert %{"title" => ["can't be blank"]} = json_response(conn, 422)["errors"]
  end

  test "returns 401 without a token" do
    conn = get(build_conn(), ~p"/api/v1/posts")
    assert json_response(conn, 401)["errors"]["detail"] == "Unauthorized"
  end
end
```

---

See the `phoenix-authorization-patterns` skill for permission checks beyond ownership.
See the `security-essentials` skill for token, redirect and input-handling rules.
See the `testing-essentials` skill for comprehensive testing patterns.
