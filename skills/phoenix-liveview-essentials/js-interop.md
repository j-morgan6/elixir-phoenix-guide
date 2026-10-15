# LiveView JS Interop Reference

> Verified against Elixir 1.20, Phoenix 1.8, LiveView 1.2 — October 2026

Read this when writing a client hook, exchanging events between a hook and the server, or adding
colocated JavaScript or CSS. The short version is in the skill's "JS Commands and Hooks" section.

Order of preference: plain bindings (`phx-click`, `phx-click-away`, `phx-window-keydown`) →
`Phoenix.LiveView.JS` commands → a colocated hook → a hook registered in `app.js`.

## Hooks

A hook is a JS object attached to an element with `phx-hook="Name"`. The element **must** have a
unique `id`; without one the client logs `no DOM ID for hook` and the hook never runs.

Callbacks: `mounted()`, `beforeUpdate(toEl)`, `updated()`, `destroyed()`, `disconnected()`,
`reconnected()`. Inside them:

| API | Purpose |
|---|---|
| `this.el` | The element |
| `this.pushEvent(event, payload)` | Send to the LiveView's `handle_event/3`; returns a promise of the `{:reply, map, socket}` payload |
| `this.pushEvent(event, payload, (reply, ref) => ...)` | Callback form |
| `this.pushEventTo(selectorOrTarget, event, payload)` | Send to the LiveView or LiveComponent that owns the target (e.g. `this.el` inside a component) |
| `this.handleEvent(event, payload => ...)` | Receive a `push_event/3` from the server; returns a ref for `removeHandleEvent(ref)` |
| `this.js()` | Run JS commands from the hook (`this.js().show(el)`, `this.js().exec(el, encodedJS)`) |
| `this.upload(name, files)` / `this.uploadTo(target, name, files)` | Feed files into an `allow_upload` config |

If the hook builds its own DOM inside `this.el`, add `phx-update="ignore"` so LiveView patches don't
wipe it. If it only needs to keep a few client-set attributes, use `JS.ignore_attributes/1` instead.

## Colocated hooks (`Phoenix.LiveView.ColocatedHook`, LiveView 1.1+)

```elixir
attr :share_url, :string, required: true

def copy_button(assigns) do
  ~H"""
  <div id="clipboard-btn" phx-hook=".Copy" data-text={@share_url}>Copy link</div>
  <script :type={Phoenix.LiveView.ColocatedHook} name=".Copy">
    export default {
      mounted() {
        this.el.addEventListener("click", async () => {
          await navigator.clipboard.writeText(this.el.dataset.text)
          this.pushEvent("copied", {})
        })
      }
    }
  </script>
  """
end
```

- `name` must be a compile-time string starting with `.`; it's prefixed with the module name, so
  `.Copy` in two modules doesn't clash. Reference it with the same dotted name in `phx-hook`.
- Requires Phoenix 1.8+. New 1.8 apps already import the manifest in `assets/js/app.js`:
  `import {hooks as colocatedHooks} from "phoenix-colocated/my_app"` and
  `hooks: {...colocatedHooks}`. Upgraded apps must add both lines and the `NODE_PATH` entry
  (`Mix.Project.build_path()`) in the esbuild config.
- Hooks are extracted at compile time into `_build/$MIX_ENV/phoenix-colocated/`. A release alias
  must compile before bundling: `release: ["compile", "assets.deploy", "release"]`.
- Imports work: npm packages resolve normally; local files use the `@` alias
  (`import {x} from "@/vendor/foo"`), configured by default in 1.8's esbuild args.
- `runtime` attribute: the hook isn't bundled but evaluated in the browser (for pages like
  LiveDashboard that can't add to your bundle). Body is an object expression, not
  `export default`; under a CSP it needs `nonce={@script_csp_nonce}`. Avoid unless needed.

## Colocated JS (`Phoenix.LiveView.ColocatedJS`, LiveView 1.1+)

Same mechanism for non-hook code (web components, global listeners). The script's `export default`
becomes the key `name` on the default export of `phoenix-colocated/my_app`:

```elixir
def copy_button_script(assigns) do
  ~H"""
  <script :type={Phoenix.LiveView.ColocatedJS} name="CopyButton">
    export default class CopyButton extends HTMLElement {}
  </script>
  """
end
```

```javascript
import colocated from "phoenix-colocated/my_app"
customElements.define("copy-button", colocated.CopyButton)
```

## Colocated CSS (`Phoenix.LiveView.ColocatedCSS`, LiveView 1.2)

Not used directly: define a module that implements the behaviour, then use it as the `:type`.

```elixir
defmodule MyAppWeb.ColocatedCSS do
  use Phoenix.LiveView.ColocatedCSS

  @impl true
  def transform("style", _attrs, css, _meta) do
    {:ok, css, []}
  end
end
```

```elixir
def price_table(assigns) do
  ~H"""
  <style :type={MyAppWeb.ColocatedCSS}>
    .price-table th { text-align: left; }
  </style>
  <table class="price-table">
    <tr><th>Plan</th></tr>
  </table>
  """
end
```

- The `<style>` tag must come first in the template.
- That module emits global CSS. For scoped CSS, return a `root_tag_attribute: {"phx-css-...", true}`
  directive and wrap the CSS in an `@scope` rule; the `Phoenix.LiveView.ColocatedCSS` moduledoc has a
  complete scoped implementation (it needs `config :phoenix_live_view, root_tag_attribute: "phx-r"`).
- Tailwind setup (Tailwind 4.2.3+, `:tailwind` 0.5+; default in apps generated with Phoenix 1.8.8+):
  `@import "phoenix-colocated/my_app/colocated.css";` and
  `@source "../../_build/dev/phoenix-colocated/my_app/*/";` in `assets/css/app.css`.

## Server → client: `push_event/4`

```elixir
{:noreply, push_event(socket, "chart:update", %{points: points})}
```

- Delivered to every hook that called `this.handleEvent("chart:update", ...)`, and dispatched on
  `window` as `phx:chart:update` (`window.addEventListener("phx:chart:update", e => e.detail)`).
- Dispatched after the DOM is patched; pass `dispatch: :before` to run before the patch.
- Payloads are JSON — don't push structs with fields the client shouldn't see.
- `JS` structs encode to JSON (LiveView 1.2), so you can push a command and run it in the hook:

```elixir
{:noreply, push_event(socket, "highlight", %{cmd: JS.transition("bg-yellow-100", to: "#row-#{id}")})}
```

```javascript
this.handleEvent("highlight", ({cmd}) => this.js().exec(this.el, cmd))
```

## Client → server with a reply

```javascript
const {label} = await this.pushEvent("chart:clicked", {index: 3})
```

```elixir
@impl true
def handle_event("chart:clicked", %{"index" => index}, socket) when is_integer(index) do
  {:reply, %{label: Enum.at(socket.assigns.labels, index)}, socket}
end
```

Treat hook payloads like any client input: validate types, and scope any record lookup with
`socket.assigns.current_scope`.

## `JS` commands quick reference

| Command | Notes |
|---|---|
| `JS.push(event, value: map, target: ...)` | Server event; chain client commands after it |
| `JS.show/hide/toggle(to:, transition:, time:)` | `display` toggling with optional transitions |
| `JS.add_class/remove_class/toggle_class(names, to:)` | Survive DOM patches |
| `JS.set_attribute({attr, val})`, `remove_attribute`, `toggle_attribute` | Attribute changes that survive patches |
| `JS.transition(classes_or_tuple, to:)` | One-off animation |
| `JS.dispatch(event, to:, detail:)` | Fire a DOM `CustomEvent` for vanilla JS listeners |
| `JS.navigate(path)` / `JS.patch(path)` | Client-initiated live navigation |
| `JS.focus`, `focus_first`, `push_focus`, `pop_focus` | Focus management for modals |
| `JS.exec("data-cancel", to: "#modal")` | Run a command stored in another element's attribute |
| `JS.ignore_attributes(attrs, to:)` | LiveView 1.1+: stop server patches to client-owned attributes (`"open"`, `"data-*"`) |

`phx-mounted={...}` runs a command when the element enters the DOM; `phx-remove={...}` runs one
before it leaves.
