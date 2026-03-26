---
name: security-essentials
description: MANDATORY for ALL security-sensitive code. Invoke before writing auth, token handling, redirects, or user input processing.
file_patterns:
  - "**/*.ex"
  - "**/*.exs"
  - "**/*.heex"
auto_suggest: true
---

# Security Essentials

## RULES — Follow these with no exceptions

1. **Never use `String.to_atom/1` on user input** — atoms are never garbage collected; user-controlled atoms exhaust the atom table and crash the BEAM VM
2. **Never interpolate strings into `fragment()` or `SQL.query()`** — always use `?` parameters for fragments and `$1` for raw SQL
3. **Never redirect to user-controlled URLs** — validate against a whitelist or use verified routes (`~p"..."`)
4. **Avoid `raw/1` in templates** — Phoenix auto-escapes for a reason; if HTML is required, sanitize first with a library like HtmlSanitizeEx
5. **Never log sensitive data** — passwords, tokens, secrets, API keys, and credentials must never appear in Logger calls
6. **Use `Plug.Crypto.secure_compare/2` for token comparison** — never `==`, which enables timing attacks
7. **Run dependency audits after changes** — `mix deps.audit`, `mix hex.audit`, and `mix sobelow` catch known vulnerabilities

---

## Atom Table Exhaustion

The BEAM atom table has a fixed limit (default ~1M atoms) and is **never garbage collected**. If an attacker can create arbitrary atoms, they crash the entire VM.

**Bad:**
```elixir
# User controls the atom — can exhaust atom table
role = String.to_atom(params["role"])
status = String.to_existing_atom(params["status"])
```

**Good:**
```elixir
# Whitelist approach — only known values become atoms
case params["role"] do
  "admin" -> :admin
  "user" -> :user
  "moderator" -> :moderator
  _ -> {:error, :invalid_role}
end

# Or keep as strings throughout
def authorize(%{"role" => "admin"}), do: :ok
def authorize(%{"role" => _}), do: {:error, :unauthorized}
```

---

## SQL Injection

Ecto's query DSL is safe by default. Danger arises with `fragment/1` and `Ecto.Adapters.SQL.query/3`.

**Bad:**
```elixir
# String interpolation in fragment — SQL injection
from(u in User, where: fragment("lower(#{field}) = ?", ^value))

# String interpolation in raw SQL
Ecto.Adapters.SQL.query(Repo, "SELECT * FROM users WHERE id = #{id}")

# String concatenation in queries
query = "SELECT * FROM users WHERE name = '" <> name <> "'"
```

**Good:**
```elixir
# Parameterized fragment — safe
from(u in User, where: fragment("lower(?) = ?", field(u, ^field_name), ^value))

# Parameterized raw SQL — safe
Ecto.Adapters.SQL.query(Repo, "SELECT * FROM users WHERE id = $1", [id])

# Ecto query DSL — always safe
from(u in User, where: u.name == ^name) |> Repo.one()
```

---

## Open Redirects

Redirecting to a user-supplied URL lets attackers craft phishing links that appear to come from your domain.

**Bad:**
```elixir
# User controls redirect destination
def create(conn, %{"redirect_to" => redirect_to} = params) do
  # ... create resource ...
  redirect(conn, to: redirect_to)
end
```

**Good:**
```elixir
# Use verified routes
redirect(conn, to: ~p"/dashboard")

# Or validate against known paths
@allowed_redirects ["/dashboard", "/profile", "/settings"]

def create(conn, %{"redirect_to" => redirect_to} = params) do
  # ... create resource ...
  if redirect_to in @allowed_redirects do
    redirect(conn, to: redirect_to)
  else
    redirect(conn, to: ~p"/dashboard")
  end
end

# Phoenix's built-in approach for auth redirects
defp maybe_store_return_to(conn) do
  # Only store relative paths
  return_to = conn.request_path
  if String.starts_with?(return_to, "/") and not String.starts_with?(return_to, "//") do
    put_session(conn, :user_return_to, return_to)
  else
    conn
  end
end
```

---

## Cross-Site Scripting (XSS)

Phoenix auto-escapes all template output by default. Using `raw/1` bypasses this protection.

**Bad:**
```elixir
# In HEEx template — bypasses escaping
<%= raw(@user_bio) %>
<%= Phoenix.HTML.raw(@comment_body) %>
```

**Good:**
```elixir
# Let Phoenix auto-escape (default behavior)
<%= @user_bio %>

# If HTML rendering is required, sanitize first
<%= raw(HtmlSanitizeEx.html5(@user_bio)) %>

# Or use Phoenix.HTML.Format for simple formatting
<%= text_to_html(@user_bio) %>
```

**Phoenix's built-in protections (already active):**
- All `<%= %>` output is HTML-escaped
- CSRF tokens in forms (`<.form>` handles this)
- Content Security Policy headers (add in your endpoint or Plug pipeline)

---

## Sensitive Data in Logs

Logs are stored in plaintext, shipped to third-party services, and often retained for months. Never log secrets.

**Bad:**
```elixir
Logger.info("User login", email: email, password: password)
Logger.debug("API call", token: api_token, response: resp)
Logger.error("Auth failed", credentials: credentials, secret: secret)
```

**Good:**
```elixir
Logger.info("User login", email: email, user_id: user.id)
Logger.debug("API call", endpoint: url, status: resp.status)
Logger.error("Auth failed", user_id: user_id, reason: :invalid_credentials)

# Use Logger metadata for request correlation (no secrets)
Logger.metadata(request_id: conn.assigns[:request_id])
```

---

## Timing Attacks

Standard `==` comparison short-circuits on the first different byte, leaking information about the secret through response timing.

**Bad:**
```elixir
# Timing-unsafe — leaks token value byte by byte
def verify_token(provided_token, stored_token) do
  provided_token == stored_token
end

# Also bad — pattern match is also timing-unsafe
def verify(%{token: token}, token), do: :ok
```

**Good:**
```elixir
# Constant-time comparison — same duration regardless of input
def verify_token(provided_token, stored_token) do
  Plug.Crypto.secure_compare(provided_token, stored_token)
end

# Phoenix already uses this for CSRF and session tokens
# Apply the same principle to your own token comparisons
```

---

## Dependency Auditing

Run these commands after adding or updating dependencies:

```bash
# Check for known vulnerabilities in dependencies
mix deps.audit

# Verify package checksums match Hex registry
mix hex.audit

# Static security analysis of your code
mix sobelow

# All three in sequence
mix deps.audit && mix hex.audit && mix sobelow
```

**Add to CI pipeline:**
```elixir
# In mix.exs aliases
defp aliases do
  [
    "security.check": ["deps.audit", "hex.audit", "sobelow --config"]
  ]
end
```

---

## CSRF Protection

Phoenix includes CSRF protection by default. Don't disable it.

```elixir
# Phoenix forms automatically include CSRF tokens
# <.form> component handles this — never use raw <form> tags

# If building a JSON API, CSRF is handled differently:
# API pipeline in router.ex should NOT include :protect_from_forgery
pipeline :api do
  plug :accepts, ["json"]
  # No :protect_from_forgery — APIs use Bearer tokens instead
end
```

---

See `elixir-essentials` skill for general Elixir patterns.
See `phoenix-authorization-patterns` skill for access control patterns.
See `telemetry-essentials` skill for secure logging practices.
