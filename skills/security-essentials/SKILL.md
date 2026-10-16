---
name: security-essentials
description: "Use when Elixir/Phoenix code handles params or other user input, String.to_atom on external strings, tokens, redirects, raw SQL, deserialization, outbound HTTP or security headers, or when asked to review code for security — injection, XSS, atom exhaustion, SSRF, open redirects, CSP, timing attacks, Sobelow. Not for permission rules (use phoenix-authorization-patterns)."
---

# Security Essentials

> Verified against Elixir 1.20, Phoenix 1.8, LiveView 1.2, Ecto 3.14 — October 2026

## RULES — Follow these with no exceptions

1. **Never use `String.to_atom/1` on user input** — atoms are never garbage collected; `String.to_existing_atom/1` raises on unknown input (a 500). Map known strings with a `case`
2. **Never build SQL or identifiers from user input** — `fragment` already rejects interpolated strings at compile time; the real holes are `Repo.query`/`SQL.query` with string interpolation and user-chosen columns (`field(p, ^name)`, `identifier(^name)`, `order_by: ^...`). Use `$1` parameters and allowlist columns with a `case`
3. **Never pass user input to `redirect(external: ...)`** — check the host against an allowlist first. `redirect(to: ...)` already raises on anything but a local path, so keep return paths server-side (session) like phx.gen.auth
4. **Avoid `raw/1`** — HEEx escapes `{@x}`; if HTML is required, sanitize with HtmlSanitizeEx first
5. **Keep secrets out of logs** — `redact: true` on sensitive schema fields, extend `:filter_parameters`, and never pass tokens or credentials as Logger metadata or message text
6. **Compare secrets with `Plug.Crypto.secure_compare/2`** — never `==` or a pattern match
7. **Never `:erlang.binary_to_term/1` untrusted bytes** — it can build functions and atoms; use JSON, or `Plug.Crypto.non_executable_binary_to_term(bin, [:safe])`
8. **Give every signed token a purpose and an explicit `max_age`** — `Phoenix.Token.verify(endpoint, "purpose", token, max_age: ...)`; `Phoenix.Token` can't be revoked, so use database tokens (phx.gen.auth `UserToken`) for login sessions and API keys
9. **Validate outbound URLs (SSRF)** — allowlist scheme and host before `Req.get(url)`, and disable redirects
10. **Production transport and headers** — keep the generated `force_ssl` (HSTS), and replace the default CSP, which only sets `base-uri` and `frame-ancestors`
11. **Run audits after dependency changes** — `mix hex.audit`, `mix deps.audit`, `mix sobelow`

---

## Atom Table Exhaustion

The atom table has a fixed limit (default 1,048,576) and is never garbage collected. Filling it crashes the whole VM.

<!-- epg:bad -->
```elixir
role = String.to_atom(params["role"])          # unbounded atom creation
status = String.to_existing_atom(params["status"])  # ArgumentError (500) on unknown input
```

```elixir
def parse_role("admin"), do: {:ok, :admin}
def parse_role("member"), do: {:ok, :member}
def parse_role(_), do: {:error, :invalid_role}
```

For schema fields, `Ecto.Enum` does this mapping for you when you `cast`.

---

## SQL Injection

The query DSL parameterizes `^values`, and `fragment("lower(#{x})")` is a compile error ("to prevent SQL injection attacks, fragment(...) does not allow strings to be interpolated"). The risks that remain:

<!-- epg:bad -->
```elixir
# Raw SQL built with interpolation — injection
Repo.query("SELECT * FROM users WHERE email = '#{email}'")

# User picks the column: ?sort=hashed_password orders (and leaks) by the password hash
order_by(query, [u], asc: field(u, ^String.to_existing_atom(params["sort"])))

# identifier/1 is quoted, but the user still chooses which column or table is read
fragment("SELECT ? FROM users", identifier(^params["column"]))
```

```elixir
# Parameters for raw SQL
Repo.query("SELECT * FROM users WHERE email = $1", [email])

# Allowlist user-chosen columns
defp sort_field("name"), do: :name
defp sort_field("inserted_at"), do: :inserted_at
defp sort_field(_), do: :inserted_at

def list_users(params) do
  from(u in User, order_by: [asc: field(u, ^sort_field(params["sort"])), asc: u.id])
  |> Repo.all()
end
```

`splice(^list)` sends each element as a parameter and is safe. `constant(^value)` inlines the value into the SQL (escaped), so each distinct value creates a new prepared query: don't feed it user input.

---

## Open Redirects

`redirect(conn, to: path)` raises `ArgumentError` unless `path` starts with a single `/` and contains no `\`, tab or newline. So `to: params["return_to"]` is a crash, not an open redirect. The risk is `external:`, in controllers and in LiveView (`redirect(socket, external: url)`).

<!-- epg:bad -->
```elixir
def callback(conn, %{"next" => next}) do
  redirect(conn, external: next)   # https://evil.example/login looks like it came from you
end
```

```elixir
@allowed_hosts ["docs.example.com", "billing.example.com"]

def callback(conn, %{"next" => next}) do
  case URI.new(next) do
    {:ok, %URI{scheme: "https", host: host}} when host in @allowed_hosts ->
      redirect(conn, external: next)

    _ ->
      redirect(conn, to: ~p"/")
  end
end
```

For "return to where you were", copy phx.gen.auth: `maybe_store_return_to/1` saves `current_path(conn)` in the session on GET requests and `log_in_user/3` redirects to it with `to:`. The path never comes from a query param.

---

## Cross-Site Scripting (XSS)

HEEx escapes every `{@value}` in text and attributes. `raw/1` turns that off.

<!-- epg:bad -->
```heex
<div>{raw(@user_bio)}</div>
<a href={@user_url}>website</a>
```

```heex
<div>{@user_bio}</div>
<div>{raw(HtmlSanitizeEx.basic_html(@user_bio))}</div>
<p class="whitespace-pre-line">{@comment_body}</p>
```

- `Phoenix.HTML.Format` was removed in phoenix_html 4. To keep line breaks in plain text, use CSS (`whitespace-pre-line`) rather than generating `<br>` tags.
- Escaping doesn't make a URL safe: `href={@user_url}` with `javascript:alert(1)` still runs. Validate that the scheme is `http`/`https` before storing user URLs.
- Uploaded files are another XSS route: see the `phoenix-uploads` skill. Never derive the stored extension or the served content type from the client.

### Content Security Policy

The `:browser` pipeline's `put_secure_browser_headers` sets only `content-security-policy: base-uri 'self'; frame-ancestors 'self';`. That's clickjacking protection, not XSS protection. Pass a real policy:

```elixir
# router.ex
@csp "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; " <>
       "img-src 'self' data: blob:; connect-src 'self'; frame-ancestors 'self'; " <>
       "base-uri 'self'; form-action 'self'; object-src 'none'"

pipeline :browser do
  plug :accepts, ["html"]
  plug :fetch_session
  plug :fetch_live_flash
  plug :put_root_layout, html: {MyAppWeb.Layouts, :root}
  plug :protect_from_forgery
  plug :put_secure_browser_headers, %{"content-security-policy" => @csp}
  plug :fetch_current_scope_for_user
end
```

The Phoenix 1.8 root layout includes an inline theme `<script>`, which `script-src 'self'` blocks. Move it to its own static file loaded without `defer`, or add a per-request nonce. `connect-src 'self'` covers the LiveView websocket on the same host.

---

## Sensitive Data in Logs

Phoenix replaces any request parameter whose name contains `"password"` with `[FILTERED]`. Extend that list:

```elixir
# config/config.exs
config :phoenix, :filter_parameters, ["password", "token", "secret", "api_key"]
```

Mark sensitive schema fields `redact: true`, so `inspect/1` (crash reports, `Logger.error("...#{inspect(user)}")`) prints `**redacted**`. phx.gen.auth already does this for `password` and `hashed_password`.

```elixir
schema "integrations" do
  field :api_key, :string, redact: true
  field :webhook_secret, :string, redact: true
  timestamps(type: :utc_datetime)
end
```

<!-- epg:bad -->
```elixir
Logger.info("API call", token: api_token, response: resp)
Logger.error("Auth failed for #{email} with #{password}")
```

```elixir
require Logger

Logger.info("API call", endpoint: url, status: resp.status)
Logger.warning("Auth failed", user_id: user_id, reason: :invalid_credentials)
```

`Plug.RequestId` (in every generated endpoint) already sets `request_id` Logger metadata; don't overwrite it.

---

## Timing Attacks and Tokens

<!-- epg:bad -->
```elixir
def valid_signature?(given, expected), do: given == expected
```

```elixir
def valid_signature?(given, expected), do: Plug.Crypto.secure_compare(given, expected)
```

Tokens you look up by a hash (the `UserToken` pattern) don't need this; the database comparison is on a hash the attacker can't steer.

**Signed tokens (`Phoenix.Token`)** default to a 1-day `max_age`. Always say what you mean:

```elixir
token = Phoenix.Token.sign(MyAppWeb.Endpoint, "email-confirm", user.id)

case Phoenix.Token.verify(MyAppWeb.Endpoint, "email-confirm", token, max_age: 3600) do
  {:ok, user_id} -> {:ok, user_id}
  {:error, :expired} -> {:error, :expired}
  {:error, _invalid} -> {:error, :invalid}
end
```

Use a different namespace for each purpose. They're signed, not encrypted: the payload is readable (`Phoenix.Token.encrypt/4` hides it). They can't be revoked before `max_age`, so they're wrong for "log out everywhere" or API keys. Use database tokens for those.

---

## Unsafe Deserialization

`:erlang.binary_to_term/1` on attacker-controlled bytes can create atoms (exhausting the table) and anonymous functions that a later call may execute.

<!-- epg:bad -->
```elixir
state = :erlang.binary_to_term(Base.decode64!(params["state"]))
```

```elixir
# Prefer JSON for anything that crosses a trust boundary
{:ok, state} = JSON.decode(params["state"])

# If it must be ETF: no new atoms, no executable terms
state = Plug.Crypto.non_executable_binary_to_term(bin, [:safe])
```

`[:safe]` alone still decodes local funs; `non_executable_binary_to_term/2` rejects them. If the data round-trips through the client, sign it too (`Phoenix.Token`).

---

## SSRF (Outbound Requests to User URLs)

A user-supplied URL (webhook, avatar URL, link preview) lets an attacker make your server call `http://169.254.169.254/` (cloud metadata), `localhost` admin ports, or internal services.

```elixir
@allowed_hosts ["api.partner.example"]

def fetch_partner_resource(url) do
  case URI.new(url) do
    {:ok, %URI{scheme: "https", host: host}} when host in @allowed_hosts ->
      # A redirect is a new, unchecked URL
      Req.get(url, redirect: false, retry: false)

    _ ->
      {:error, :url_not_allowed}
  end
end
```

If you must accept arbitrary hosts (webhooks), resolve the hostname and reject loopback, private (10/8, 172.16/12, 192.168/16), link-local (169.254/16) and IPv6 equivalents. Then connect to the IP you checked, because a second DNS lookup can return a different address (DNS rebinding). Run such fetches from a background job with a short timeout.

Req strips only `authorization` on cross-host redirects; custom API-key headers are forwarded. See the `http-clients-req` skill.

---

## File Paths

Never build a filesystem path from client input: `entry.client_name`, `params["file"]`, or any name stored from the client.

<!-- epg:bad -->
```elixir
path = Path.join("priv/uploads", params["name"])   # "../../config/runtime.exs"
send_file(conn, 200, path)
```

```elixir
# Store under a server-chosen name; look the record up through a scoped context
document = Media.get_document!(scope, id)
send_download(conn, {:file, Media.document_path(document)}, filename: document.original_name)

# If a relative path must come from input, Path.safe_relative/2 rejects ../ escapes
{:ok, rel} = Path.safe_relative(params["path"], Media.uploads_dir())
```

`Path.basename/1` isn't a guard: `Path.basename("..")` is `".."`. See the `phoenix-uploads` skill for upload naming and content types.

---

## Session Cookies, HTTPS and HSTS

- **HTTPS**: Phoenix 1.8's `config/prod.exs` sets `force_ssl: [rewrite_on: [:x_forwarded_proto], ...]`. That redirects HTTP to HTTPS and sends HSTS (1 year by default). `force_ssl` is compile-time config: keep it in `prod.exs`, not `runtime.exs`. `rewrite_on` is required behind a TLS-terminating proxy; without it every request looks like HTTP and you get a redirect loop.
- **Session cookie**: the generated `@session_options` are signed (`signing_salt`), `http_only` (the default) and `same_site: "Lax"`. `secure` is added automatically when the request is HTTPS, which again depends on `rewrite_on` behind a proxy. Set `secure: true` explicitly if unsure. The cookie is signed, not encrypted: the user can read it. Add `encryption_salt:` if you store anything they shouldn't see.
- **WebSockets**: keep `check_origin` enabled (the default) in production. See the `phoenix-channels-essentials` skill.

---

## CSRF Protection

`protect_from_forgery` in the `:browser` pipeline checks a token on every non-GET request. `<.form>` and `<.link method="delete">` include it for you. A hand-written `<form>` needs it explicitly:

```heex
<form action={~p"/export"} method="post">
  <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
  <button type="submit">Export</button>
</form>
```

The `:api` pipeline has no CSRF check because it uses `Authorization` headers, not cookies. If an API endpoint reads the session cookie, it needs CSRF protection again.

---

## Dependency and Code Auditing

```elixir
# mix.exs
defp deps do
  [
    # ...
    {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
    {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false}
  ]
end

defp aliases do
  [
    # ...
    "security.check": ["hex.audit", "deps.audit", "sobelow --exit"]
  ]
end
```

```bash
mix hex.audit              # retired packages (checksums are already verified via mix.lock)
mix deps.audit             # known CVEs in dependencies (mix_audit)
mix sobelow --save-config  # once: writes .sobelow-conf (commit it); later runs pick it up automatically
mix sobelow --exit         # non-zero exit on findings (low confidence and up), for CI
```

Sobelow flags `Config.CSP` until the `:browser` pipeline passes a `"content-security-policy"` header (see above). Silence a reviewed finding with a `# sobelow_skip ["Module"]` comment, not by dropping the check.

---

See the `phoenix-authorization-patterns` skill for access control.
See the `phoenix-json-api` skill for API tokens and rate limiting.
See the `telemetry-essentials` skill for the logging rules.
