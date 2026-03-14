defmodule Datastar do
  @moduledoc """
  Stateless SSE helpers for [Datastar](https://data-star.dev) in any Plug/Phoenix app.

  `Datastar` provides a set of composable, stateless functions that write
  [Server-Sent Events (SSE)](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events)
  to a chunked `Plug.Conn` response. The Datastar JavaScript client library
  running in the browser receives these events and applies DOM patches, signal
  updates, script executions, and redirects — all without a full-page reload.

  ## Installation

  Add `datastar_plug` to your `mix.exs` dependencies:

  ```elixir
  def deps do
    [
      {:datastar_plug, "~> 0.1.0"}
    ]
  end
  ```

  ## Quick Start

  ### Phoenix controller

  ```elixir
  defmodule MyAppWeb.DashboardController do
    use MyAppWeb, :controller
    alias Datastar

    def show(conn, params) do
      signals = Datastar.parse_signals(params)
      html = render_to_string(conn, :dashboard, assigns)

      conn
      |> Datastar.init_sse()
      |> Datastar.patch_fragment(html)
      |> Datastar.patch_signals(%{loaded: true})
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
      |> Datastar.patch_fragment(~s(<div id="status">OK</div>))
      |> Datastar.close_sse()
    end
  end
  ```

  ## SSE Event Protocol

  Each SSE event emitted by this library follows the format required by the
  [Datastar SSE specification](https://data-star.dev/reference/sse_events):

  ```
  event: <event-type>\\n
  data: <key> <value>\\n
  ...more data lines...\\n
  \\n
  ```

  The blank line (double newline `\\n\\n`) terminates the event. Multi-line
  values (e.g. multi-line HTML) are split into multiple `data:` lines, one
  per original line.

  ## Security Considerations

  See the [Datastar security reference](https://data-star.dev/reference/security)
  for the full specification. Key points for this library:

  - **`patch_fragment/3`** — HTML is written verbatim to the SSE stream. If any
    part of the HTML originates from user input, the caller **must** sanitise it
    before passing it to this function to prevent XSS.

  - **`patch_signals/2`** — Signal values are JSON-encoded via `Jason`, so they
    are safe against injection in the SSE stream itself. However, if signal
    values are later rendered into HTML on the server, standard output-encoding
    rules apply.

  - **`execute_script/2`** — Executes arbitrary JavaScript on the client. Only
    pass **server-controlled** strings. Never interpolate user input directly
    into the script string.

  - **`redirect_to/2`** — The URL is JSON-encoded via `Jason` before being
    embedded in the `window.location.href` assignment, preventing injection via
    single-quotes, backslashes, or `</script>` in the URL.

  - **`parse_signals/1`** — Signal data arrives from the browser (user-
    controlled). Treat all parsed values as untrusted input. Validate and
    sanitise before using them in queries, rendering, or downstream logic.
  """

  import Plug.Conn

  @typedoc """
  Controls how `patch_fragment/3` merges incoming HTML into the existing DOM.

  These values correspond directly to the `mode` data line in the Datastar
  SSE protocol as implemented in the Datastar JS client (RC.8+).

  | Value | Behaviour |
  |-------|-----------|
  | `"outer"` | **Default.** Morphs the element in place. Without a `:selector`, matches top-level elements by `id` and morphs each one in the DOM. |
  | `"inner"` | Replaces the *inner* HTML of the target element using morphing. |
  | `"replace"` | Replaces the target element with `replaceWith` (no morphing diff). |
  | `"prepend"` | Inserts HTML before the first child of the target. |
  | `"append"` | Inserts HTML after the last child of the target. |
  | `"before"` | Inserts HTML immediately before the target element. |
  | `"after"` | Inserts HTML immediately after the target element. |
  | `"remove"` | Removes the target element (no HTML content needed). |
  """
  @type merge_mode ::
          String.t()

  @valid_merge_modes ~w(outer inner replace prepend append before after remove)
  @default_merge_mode "outer"

  @doc """
  Initialises a chunked SSE response on the connection.

  Sets the required HTTP headers for Server-Sent Events and opens a chunked
  200 response. **Must be called before any other `Datastar.*` functions** in
  the pipeline.

  ## Headers set

  | Header | Value |
  |--------|-------|
  | `content-type` | `text/event-stream` — signals SSE to the browser |
  | `cache-control` | `no-cache, no-store, must-revalidate` — prevents caching |
  | `connection` | `keep-alive` — hints to proxies to keep the connection open |
  | `x-accel-buffering` | `no` — disables Nginx / Caddy response buffering |

  ## Example

      conn |> Datastar.init_sse()

  """
  @spec init_sse(Plug.Conn.t()) :: Plug.Conn.t()
  def init_sse(conn) do
    conn
    |> put_resp_header("content-type", "text/event-stream")
    |> put_resp_header("cache-control", "no-cache, no-store, must-revalidate")
    |> put_resp_header("connection", "keep-alive")
    |> put_resp_header("x-accel-buffering", "no")
    |> send_chunked(200)
  end

  @doc """
  Sends a `datastar-patch-elements` SSE event to patch HTML into the DOM.

  Datastar morphs the incoming HTML into the existing DOM by matching
  top-level elements by their `id` attribute (the default `"morph"` mode).
  Other merge modes can be selected via the `:merge_mode` option.

  Multi-line HTML is split into multiple `data: elements` lines as required
  by the SSE protocol.

  > #### Security {: .warning}
  >
  > HTML is written verbatim to the SSE stream. **Sanitise any user-supplied
  > content** before passing it to this function to prevent XSS.

  ## Options

  - `:selector` — CSS selector for the target element (e.g. `"#my-div"`).
    When omitted, Datastar matches top-level elements by `id` in `"morph"` mode.
    For modes like `"inner"`, `"prepend"`, `"append"`, etc., the Datastar client
    expects a selector, so callers should provide one when using those modes.
  - `:merge_mode` — How to apply the patch. Defaults to `"outer"`.
    See `t:merge_mode/0` for all allowed values.

  ## Examples

      # Default morph — element id must exist in the DOM
      conn |> Datastar.patch_fragment(~s(<div id="greeting">Hello!</div>))

      # Replace inner HTML of a container
      conn |> Datastar.patch_fragment("<li>New item</li>",
        selector: "#item-list",
        merge_mode: "append"
      )

  ## SSE format emitted

      event: datastar-patch-elements
      data: selector #greeting
      data: mode inner
      data: elements <div>Hello!</div>

  """
  @spec patch_fragment(Plug.Conn.t(), String.t(), keyword()) :: Plug.Conn.t()
  def patch_fragment(conn, html, opts \\ []) when is_binary(html) do
    selector = opts[:selector]
    mode = opts[:merge_mode] || @default_merge_mode

    if mode not in @valid_merge_modes do
      raise ArgumentError,
            "invalid merge_mode #{inspect(mode)}. Must be one of: #{Enum.join(@valid_merge_modes, ", ")}"
    end

    selector_line = if selector, do: "data: selector #{selector}\n", else: ""

    # Only emit mode line when it differs from Datastar's default merge mode ("outer").
    # The Datastar client defaults to "outer", which matches @default_merge_mode,
    # so we only need to send the line when explicitly overriding.
    mode_line = if mode == @default_merge_mode, do: "", else: "data: mode #{mode}\n"

    element_lines =
      html
      |> String.split("\n")
      |> Enum.map_join("\n", &"data: elements #{&1}")

    event = "event: datastar-patch-elements\n#{selector_line}#{mode_line}#{element_lines}\n\n"

    case chunk(conn, event) do
      {:ok, conn} -> conn
      # Client disconnected — treat as a normal end of the SSE stream rather
      # than raising a MatchError, which would generate noisy crash logs.
      {:error, _reason} -> conn
    end
  end

  @doc """
  Sends a `datastar-patch-signals` SSE event to update client-side signals.

  The `signals` map is JSON-encoded and sent to the Datastar client, which
  merges the values into its signal store. Existing signals with matching keys
  are updated; new keys are added. Setting a signal value to `nil` removes it
  from the client store.

  > #### Encoding {: .info}
  >
  > Signal values are encoded with `Jason.encode!/1`. Map keys may be atoms or
  > strings; atoms are serialised as camelCase strings by default.

  ## Examples

      conn |> Datastar.patch_signals(%{count: 42, loading: false})

      # Remove a signal by setting it to nil
      conn |> Datastar.patch_signals(%{temp_error: nil})

  ## SSE format emitted

      event: datastar-patch-signals
      data: signals {"count":42,"loading":false}

  """
  @spec patch_signals(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def patch_signals(conn, signals) when is_map(signals) do
    json = Jason.encode!(signals)
    event = "event: datastar-patch-signals\ndata: signals #{json}\n\n"

    case chunk(conn, event) do
      {:ok, conn} -> conn
      {:error, _reason} -> conn
    end
  end

  @doc """
  Executes a JavaScript snippet on the client.

  Internally sends a `datastar-patch-elements` event that appends a
  `<script>` tag to the document `<body>`. This is the Datastar-recommended
  pattern for executing arbitrary scripts from an SSE stream.

  > #### Security {: .warning}
  >
  > Only pass **server-controlled** strings to this function. Never interpolate
  > user input directly into `script` — doing so creates an XSS vulnerability.

  ## Example

      conn |> Datastar.execute_script("console.log('hello from Elixir')")

  ## SSE format emitted

      event: datastar-patch-elements
      data: selector body
      data: mode append
      data: elements <script>console.log('hello from Elixir')</script>

  """
  @spec execute_script(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def execute_script(conn, script) when is_binary(script) do
    patch_fragment(conn, "<script>#{script}</script>",
      merge_mode: "append",
      selector: "body"
    )
  end

  @doc """
  Redirects the browser to `url` via a client-side script event.

  Uses `execute_script/2` to send a `window.location.href` assignment wrapped
  in `setTimeout(..., 0)` so it fires after the current event-loop tick,
  giving Datastar time to process any preceding SSE events in the same
  response before the navigation occurs.

  The URL is JSON-encoded before embedding, preventing injection via
  single-quotes, backslashes, or `</script>` in the URL string.

  ## Example

      conn |> Datastar.redirect_to("/dashboard")

      # Works with absolute URLs too
      conn |> Datastar.redirect_to("https://example.com/logout")

  """
  @spec redirect_to(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def redirect_to(conn, url) when is_binary(url) do
    execute_script(conn, "setTimeout(() => { window.location.href = #{Jason.encode!(url)} }, 0)")
  end

  @doc """
  Sends a `datastar-patch-elements` event with `mode: remove` to remove a DOM element.

  Removes all elements matching `selector` from the DOM. No HTML content is
  needed — the `remove` merge mode requires only the selector.

  ## Example

      # Remove an item row after it has been deleted on the server
      conn |> Datastar.remove_fragment("#item-42")

  ## SSE format emitted

      event: datastar-patch-elements
      data: selector #item-42
      data: mode remove

  """
  @spec remove_fragment(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def remove_fragment(conn, selector) when is_binary(selector) do
    event = "event: datastar-patch-elements\ndata: selector #{selector}\ndata: mode remove\n\n"

    case chunk(conn, event) do
      {:ok, conn} -> conn
      {:error, _reason} -> conn
    end
  end

  @doc """
  No-op close marker for SSE pipelines.

  Including `close_sse/1` at the end of a pipeline documents intent: the
  response body is complete. In practice, the chunked connection is closed
  automatically when the controller action returns and Plug finalises the
  response.

  ## Example

      conn
      |> Datastar.init_sse()
      |> Datastar.patch_fragment(html)
      |> Datastar.close_sse()

  """
  @spec close_sse(Plug.Conn.t()) :: Plug.Conn.t()
  def close_sse(conn), do: conn

  @doc """
  Parses the Datastar signal map out of controller `params`.

  Datastar encodes signals differently depending on the HTTP method:

  - **GET** — All signals are serialised as a JSON string in the `?datastar=`
    query parameter. `params` looks like
    `%{"datastar" => "{\"key\": \"value\"}"}`. This clause decodes the nested
    JSON string and returns the resulting map.

  - **POST / PUT / PATCH / DELETE** — Datastar sends the signal map directly
    as the JSON request body. The body parser decodes it so `params` *is*
    already the signal map. Route and query parameters (e.g. `"id"`) are
    **not** filtered out; restrict to known keys with `Map.take/2` if needed.

  Returns `%{}` when signals cannot be parsed so callers always receive a map.

  > #### Security {: .warning}
  >
  > Signal data originates from the browser and must be treated as untrusted
  > user input. Validate and sanitise all values before using them in queries,
  > HTML rendering, or downstream business logic.

  ## Example

      def update(conn, params) do
        signals = Datastar.parse_signals(params)
        name = Map.get(signals, "newName", "")

        conn
        |> Datastar.init_sse()
        |> Datastar.patch_signals(%{saved: true, name: name})
        |> Datastar.close_sse()
      end

  """
  @spec parse_signals(any()) :: map()
  def parse_signals(%{"datastar" => json}) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, signals} when is_map(signals) -> signals
      _ -> %{}
    end
  end

  def parse_signals(params) when is_map(params), do: params

  def parse_signals(_params), do: %{}
end
