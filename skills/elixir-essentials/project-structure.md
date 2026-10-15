# Phoenix Project Structure

> Verified against Elixir 1.20, Phoenix 1.8, LiveView 1.2 (a freshly generated app) — October 2026

The layout `mix phx.new my_app` (Phoenix 1.8) generates, plus `mix phx.gen.auth Accounts User users --live` and a `Media` context.

## Directory Layout

```text
my_app/
├── lib/
│   ├── my_app.ex                    # Top-level module (docs only)
│   ├── my_app/                      # Business logic, no web dependencies
│   │   ├── application.ex           # Supervision tree
│   │   ├── repo.ex                  # Ecto repository
│   │   ├── mailer.ex                # Swoosh mailer
│   │   ├── accounts.ex              # Accounts context: public API (phx.gen.auth)
│   │   ├── accounts/
│   │   │   ├── scope.ex             # %Scope{} passed first to every context call
│   │   │   ├── user.ex              # Schema
│   │   │   ├── user_token.ex
│   │   │   └── user_notifier.ex     # Login/confirmation emails
│   │   ├── media.ex                 # Media context: public API
│   │   └── media/
│   │       ├── image.ex             # Schema
│   │       └── folder.ex            # Schema
│   │
│   ├── my_app_web.ex                # `use MyAppWeb, :live_view` / :controller / :html
│   └── my_app_web/
│       ├── components/
│       │   ├── core_components.ex   # <.input>, <.button>, <.table>, <.header>, <.icon>, <.flash>
│       │   ├── layouts.ex           # Layouts.app/1 function component, flash_group
│       │   └── layouts/
│       │       └── root.html.heex   # <html> shell, the only layout template
│       ├── controllers/
│       │   ├── page_controller.ex
│       │   ├── page_html.ex         # View module: embed_templates "page_html/*"
│       │   ├── page_html/
│       │   │   └── home.html.heex
│       │   ├── error_html.ex        # Error pages (HTML)
│       │   ├── error_json.ex        # Error bodies (JSON); API views are *_json.ex
│       │   └── user_session_controller.ex
│       ├── live/
│       │   ├── image_live/
│       │   │   ├── index.ex
│       │   │   ├── show.ex
│       │   │   └── form.ex
│       │   └── user_live/           # Registration, login, settings, confirmation
│       ├── user_auth.ex             # Auth plugs and on_mount hooks
│       ├── endpoint.ex
│       ├── router.ex
│       ├── telemetry.ex             # Metrics and telemetry poller
│       └── gettext.ex
│
├── priv/
│   ├── repo/
│   │   ├── migrations/
│   │   └── seeds.exs                # `mix run priv/repo/seeds.exs`
│   ├── static/                      # Build output + favicon.ico, robots.txt, images/
│   └── gettext/                     # Translations
│
├── assets/
│   ├── css/app.css                  # Tailwind v4 entry (@import "tailwindcss", daisyUI @plugin)
│   ├── js/app.js                    # esbuild entry (LiveSocket, hooks)
│   └── vendor/                      # heroicons.js, topbar.js
│
├── test/
│   ├── my_app/
│   │   └── media_test.exs
│   ├── my_app_web/
│   │   └── live/
│   │       └── image_live_test.exs
│   ├── support/
│   │   ├── conn_case.ex             # ConnCase: register_and_log_in_user/1
│   │   ├── data_case.ex             # DataCase: sandbox setup, errors_on/1
│   │   └── fixtures/
│   │       ├── accounts_fixtures.ex # user_fixture/1, user_scope_fixture/0
│   │       └── media_fixtures.ex
│   └── test_helper.exs
│
├── config/
│   ├── config.exs                   # Shared; imports "#{config_env()}.exs" at the bottom
│   ├── dev.exs
│   ├── test.exs
│   ├── prod.exs                     # Compile-time prod settings
│   └── runtime.exs                  # Env vars, read at boot (releases too)
│
├── rel/                             # Created by `mix phx.gen.release` (overlays, env.sh.eex)
├── AGENTS.md                        # Usage rules Phoenix 1.8 generates for coding agents
└── mix.exs                          # Deps and aliases (setup, assets.build, assets.deploy)
```

There is no `tailwind.config.js` in Phoenix 1.8: Tailwind v4 is configured in `assets/css/app.css`. Both tailwind and esbuild run as Mix deps (no Node required) via `config :tailwind` / `config :esbuild` and the dev watchers.

## Context Boundaries

The context module sits next to its directory: `lib/my_app/media.ex` holds the public API, `lib/my_app/media/*.ex` holds schemas. Following the 1.8 generators, every function takes the caller's `%Scope{}` first:

```elixir
# lib/my_app/media.ex
defmodule MyApp.Media do
  alias MyApp.Accounts.Scope
  alias MyApp.Media.Image
  alias MyApp.Repo

  def get_image!(%Scope{} = scope, id), do: Repo.get_by!(Image, id: id, user_id: scope.user.id)

  # list_images/2, create_image/3, update_image/3, delete_image/2: see the ecto-essentials skill
end
```

The full scoped context is in the `ecto-essentials` skill (queries) and the `phoenix-pubsub-patterns` skill (the generated module with broadcasts). The web layer stays thin and passes `socket.assigns.current_scope`:

```elixir
# lib/my_app_web/live/image_live/form.ex
@impl true
def handle_event("save", %{"image" => image_params}, socket) do
  %{current_scope: scope, image: image} = socket.assigns

  case Media.update_image(scope, image, image_params) do
    {:ok, _image} ->
      {:noreply,
       socket
       |> put_flash(:info, "Image updated")
       |> push_navigate(to: ~p"/images")}

    {:error, %Ecto.Changeset{} = changeset} ->
      {:noreply, assign(socket, form: to_form(changeset))}
  end
end
```

## File Organization Rules

1. **One module per file; the path mirrors the module name.** `MyApp.Media.Image` → `lib/my_app/media/image.ex`, `MyApp.Media` → `lib/my_app/media.ex`.
2. **`lib/my_app/` never references `MyAppWeb`.** Dependencies flow from web to core.
3. **Tests mirror source.** `lib/my_app/media.ex` → `test/my_app/media_test.exs`.
4. **Controllers render through a view module.** `PageController` → `PageHTML` (`page_html.ex` + `page_html/*.heex`); JSON APIs use `*_json.ex` modules returning maps.
5. **Shared UI goes in `core_components.ex`** (or a new module under `components/`), not in each LiveView.

## application.ex

The generated supervision tree, in start order. Add Oban (and your own processes) before the Endpoint so they are running when requests arrive:

```elixir
def start(_type, _args) do
  children = [
    MyAppWeb.Telemetry,
    MyApp.Repo,
    {DNSCluster, query: Application.get_env(:my_app, :dns_cluster_query) || :ignore},
    {Phoenix.PubSub, name: MyApp.PubSub},
    {Oban, Application.fetch_env!(:my_app, Oban)},
    # Start to serve requests, typically the last entry
    MyAppWeb.Endpoint
  ]

  opts = [strategy: :one_for_one, name: MyApp.Supervisor]
  Supervisor.start_link(children, opts)
end
```

## Configuration

- `config/config.exs` is read first and ends with `import_config "#{config_env()}.exs"`, so `dev.exs`, `test.exs` or `prod.exs` override it. The environment files don't import `config.exs`.
- `config/runtime.exs` runs at boot, after compilation, in dev, test and releases. Secrets and `DATABASE_URL`/`SECRET_KEY_BASE` go here, never in `prod.exs`.
- Repeated `config :my_app, Key, ...` calls deep-merge keyword lists; any other value (including a list that isn't a keyword list) is replaced by the later call.

## Static files and uploads

`priv/static` holds build output and is served only for the paths in `MyAppWeb.static_paths/0` (`assets fonts images favicon.ico robots.txt`). Don't store user uploads there: a release is rebuilt and replaced on every deploy, so uploaded files disappear. Store uploads in external storage (S3 or compatible) or a configured directory on a mounted volume: public files served by their own `Plug.Static` in the endpoint, private ones by a controller that loads the record through the scope. See the `phoenix-uploads` skill.

## Key Principles

1. **Contexts are boundaries.** The web layer calls context functions, never `Repo` or schemas' queries directly.
2. **Scope every call.** Pass `current_scope` into the context; never load or delete a record by a client-supplied id alone.
3. **Thin controllers and LiveViews.** Business logic lives in contexts.
4. **One owner per piece of data.** Each table belongs to one context.
