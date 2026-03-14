# DatastarPlug

[![Hex version](https://img.shields.io/hexpm/v/datastar_plug.svg)](https://hex.pm/packages/datastar_plug)
[![Hex docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/datastar_plug)
[![CI](https://github.com/rskinnerc/datastar_plug/actions/workflows/ci.yml/badge.svg)](https://github.com/rskinnerc/datastar_plug/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Stateless [Server-Sent Events (SSE)](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events)
helpers for [Datastar](https://data-star.dev) in any **Plug** or **Phoenix** application.

`DatastarPlug` gives you a small set of composable, pipeline-friendly functions
that write Datastar-compatible SSE events to a chunked `Plug.Conn` response.
The [Datastar JavaScript client](https://data-star.dev) running in the browser
receives these events and applies DOM patches, signal updates, script
executions, and redirects — all without a full-page reload and without any
WebSocket or long-polling infrastructure.

---

## Installation

Add `:datastar_plug` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:datastar_plug, "~> 0.2.0"}
  ]
end
```

Then run:

```shell
mix deps.get
```

No additional configuration is required. The package has two runtime
dependencies: [`plug`](https://hex.pm/packages/plug) and
[`jason`](https://hex.pm/packages/jason), both of which are already present
in virtually every Phoenix application.

---

## What's New in v0.2.0

- **`check_connection/1`** — detect client disconnects in long-running streams.
- **`remove_signals/3`** — remove client signals by dot-notated path, with
  correct merging of shared path prefixes.
- **`:namespace` option** on `patch_fragment/3` — patch SVG or MathML
  fragments.
- **`:use_view_transition` option** on `patch_fragment/3` — animate patches
  via the browser's View Transitions API.
- **`:only_if_missing` option** on `patch_signals/3` — set default signal
  values without overwriting existing ones.
- **`:auto_remove` option** on `execute_script/3` — automatically remove the
  injected `<script>` tag after execution.
- **`:event_id` and `:retry_duration` options** on every SSE function — emit
  the standard SSE `id:` and `retry:` fields for client-side replay support.

---

## Quick Start

### Phoenix controller

```elixir
defmodule MyAppWeb.ItemController do
  use MyAppWeb, :controller

  alias Datastar
  alias MyApp.Items

  # GET /items/:id/refresh — triggered by a Datastar `data-on-load` attribute
  def refresh(conn, params) do
    signals = Datastar.parse_signals(params)
    item    = Items.get!(signals["itemId"])
    html    = Phoenix.View.render_to_string(MyAppWeb.ItemView, "card.html", item: item)

    conn
    |> Datastar.init_sse()
    |> Datastar.patch_fragment(html)
    |> Datastar.patch_signals(%{itemLoaded: true})
    |> Datastar.close_sse()
  end

  # DELETE /items/:id — delete and remove the card from the DOM
  def delete(conn, %{"id" => id}) do
    Items.delete!(id)

    conn
    |> Datastar.init_sse()
    |> Datastar.remove_fragment("#item-#{id}")
    |> Datastar.patch_signals(%{count: Items.count()})
    |> Datastar.close_sse()
  end
end
```

### Plain `Plug.Router`

```elixir
defmodule MyApp.Router do
  use Plug.Router

  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :dispatch

  get "/updates" do
    conn
    |> Datastar.init_sse()
    |> Datastar.patch_fragment(~s(<div id="status">All systems go</div>))
    |> Datastar.patch_signals(%{ready: true})
    |> Datastar.close_sse()
  end
end
```

### Long-running SSE streams with connection checking

```elixir
def stream(conn, _params) do
  conn = Datastar.init_sse(conn)
  stream_items(conn, MyApp.Items.all())
end

defp stream_items(conn, []), do: conn

defp stream_items(conn, [item | rest]) do
  case Datastar.check_connection(conn) do
    {:ok, conn} ->
      conn
      |> Datastar.patch_fragment(render_item(item))
      |> stream_items(rest)

    {:error, _conn} ->
      # Client disconnected — stop streaming silently
      conn
  end
end
```

### Removing signals

```elixir
conn
|> Datastar.init_sse()
|> Datastar.remove_signals(["user.name", "user.email"])
|> Datastar.close_sse()
```

### Reading signals from GET requests

Datastar serialises the entire client signal store as a JSON string in the
`?datastar=` query parameter on GET requests. Use `parse_signals/1` to decode
it:

```elixir
def search(conn, params) do
  # params == %{"datastar" => "{\"query\":\"elixir\"}"}
  signals = Datastar.parse_signals(params)
  query   = Map.get(signals, "query", "")

  results_html = render_results(query)

  conn
  |> Datastar.init_sse()
  |> Datastar.patch_fragment(results_html)
  |> Datastar.close_sse()
end
```

### Reading signals from POST / PUT / DELETE requests

For mutating requests Datastar sends signals as the JSON request body. The
body parser decodes it, so `params` is already the signal map:

```elixir
def create(conn, params) do
  # params == %{"title" => "Buy milk", "done" => false}
  signals = Datastar.parse_signals(params)
  title   = Map.get(signals, "title", "")

  {:ok, item} = MyApp.Items.create(%{title: title})

  conn
  |> Datastar.init_sse()
  |> Datastar.patch_fragment(render_item(item), selector: "#list", merge_mode: "append")
  |> Datastar.patch_signals(%{newTitle: ""})
  |> Datastar.close_sse()
end
```

---

## Function Reference

| Function | Description |
|----------|-------------|
| [`init_sse/1`](https://hexdocs.pm/datastar_plug/Datastar.html#init_sse/1) | Open a chunked SSE response. **Call first.** |
| [`patch_fragment/3`](https://hexdocs.pm/datastar_plug/Datastar.html#patch_fragment/3) | Patch HTML into the DOM (`datastar-patch-elements`). |
| [`remove_fragment/3`](https://hexdocs.pm/datastar_plug/Datastar.html#remove_fragment/3) | Remove a DOM element by CSS selector. |
| [`patch_signals/3`](https://hexdocs.pm/datastar_plug/Datastar.html#patch_signals/3) | Merge values into the client signal store (`datastar-patch-signals`). |
| [`remove_signals/3`](https://hexdocs.pm/datastar_plug/Datastar.html#remove_signals/3) | Remove one or more signals by dot-notated path. |
| [`execute_script/3`](https://hexdocs.pm/datastar_plug/Datastar.html#execute_script/3) | Execute JavaScript on the client (appends a `<script>` tag). |
| [`redirect_to/3`](https://hexdocs.pm/datastar_plug/Datastar.html#redirect_to/3) | Redirect the browser via `window.location.href`. |
| [`check_connection/1`](https://hexdocs.pm/datastar_plug/Datastar.html#check_connection/1) | Verify the SSE connection is still alive. |
| [`close_sse/1`](https://hexdocs.pm/datastar_plug/Datastar.html#close_sse/1) | No-op pipeline terminator for readability. |
| [`parse_signals/1`](https://hexdocs.pm/datastar_plug/Datastar.html#parse_signals/1) | Decode Datastar signals from GET or POST params. |

---

## SSE Protocol Overview

Each function emits one or more
[SSE events](https://data-star.dev/reference/sse_events) in the following
wire format:

```
event: <event-type>\n
data: <key> <value>\n
[data: <key2> <value2>\n]
\n
```

The blank line (`\n\n`) terminates the event. Multi-line HTML values (from
`patch_fragment/3`) are split into one `data: elements` line per source line.

### `datastar-patch-elements`

Used by `patch_fragment/3`, `execute_script/2`, `remove_fragment/2`.

```
event: datastar-patch-elements
data: selector #my-div
data: mode inner
data: elements <p>Hello, world!</p>

```

### `datastar-patch-signals`

Used by `patch_signals/2`.

```
event: datastar-patch-signals
data: signals {"count":42,"loading":false}

```

---

## Merge Modes

The `:merge_mode` option of `patch_fragment/3` controls how incoming HTML is
merged into the DOM:

| Mode | Behaviour |
|------|-----------|
| `"outer"` | **(Default)** Morphs the element in place. Without a `:selector`, matches top-level elements by `id` and morphs each one. |
| `"inner"` | Replaces inner HTML of the target element using morphing. |
| `"replace"` | Replaces the target element with `replaceWith` (no morphing diff). |
| `"prepend"` | Inserts before the first child of the target. |
| `"append"` | Inserts after the last child of the target. |
| `"before"` | Inserts immediately before the target element. |
| `"after"` | Inserts immediately after the target element. |
| `"remove"` | Removes the target (use `remove_fragment/2` instead). |

---

## Security

See the [Datastar security reference](https://data-star.dev/reference/security)
for the full specification. Key points for this library:

- **`patch_fragment/3`** — HTML is written verbatim to the SSE stream. If any
  part of the HTML originates from user input, **sanitise it first** to prevent
  XSS. Use `Phoenix.HTML.html_escape/1` or a dedicated HTML sanitiser.

- **`execute_script/2`** — Executes arbitrary JavaScript on the client. Only
  pass **server-controlled** strings. Never interpolate user input into the
  script.

- **`redirect_to/2`** — The URL is `Jason.encode!/1`-encoded before embedding,
  preventing injection via single-quotes, backslashes, or `</script>` in the
  URL string.

- **`parse_signals/1`** — Signal data originates from the browser and must be
  treated as **untrusted user input**. Validate and sanitise all values before
  using them in queries, HTML rendering, or downstream business logic.

---

## Contributing

1. Fork the repository.
2. Create a feature branch: `git checkout -b my-feature`.
3. Make your changes and add tests.
4. Run the full quality suite:
   ```shell
   mix test.ci
   ```
5. Open a pull request.

Bug reports and feature requests are welcome via
[GitHub Issues](https://github.com/rskinnerc/datastar_plug/issues).

---

## License

DatastarPlug is released under the [MIT License](LICENSE).
