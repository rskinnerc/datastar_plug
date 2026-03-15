defmodule Datastar do
  @moduledoc """
  Stateless SSE helpers for [Datastar](https://data-star.dev) in any Plug/Phoenix app.

  `Datastar` provides a set of composable, stateless functions that write
  [Server-Sent Events (SSE)](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events)
  to a chunked `Plug.Conn` response. The Datastar JavaScript client library
  running in the browser receives these events and applies DOM patches, signal
  updates, script executions, and redirects — all without a full-page reload.

  > #### Compatibility {: .info}
  >
  > This library is built for **Datastar RC.8+**. If you're using an earlier
  > version, some functions or options may not work as expected.

  ## Installation

  Add `datastar_plug` to your `mix.exs` dependencies:

  ```elixir
  def deps do
    [
      {:datastar_plug, "~> 0.2.0"}
    ]
  end
  ```

  ## Quick Start

  ### Phoenix controller

  ```elixir
  defmodule MyAppWeb.ItemController do
    use MyAppWeb, :controller
    alias Datastar
    alias MyApp.Items

    # GET /items/:id/edit — triggered by a Datastar `data-init` attribute
    def edit(conn, %{"id" => id} = params) do
      signals = Datastar.parse_signals(params)
      item = Items.get!(id)
      form_html = render_to_string(conn, :edit_form, item: item)

      conn
      |> Datastar.init_sse()
      |> Datastar.patch_fragment(form_html, selector: "#item-form")
      |> Datastar.patch_signals(%{editMode: true, itemId: id})
      |> Datastar.close_sse()
    end

    # PUT /items/:id — save changes and update the display
    def update(conn, %{"id" => id} = params) do
      signals = Datastar.parse_signals(params)
      item_attrs = Map.take(signals, ["title", "description"])
      {:ok, item} = Items.update(id, item_attrs)
      display_html = render_to_string(conn, :display, item: item)

      conn
      |> Datastar.init_sse()
      |> Datastar.patch_fragment(display_html, selector: "#item-display")
      |> Datastar.patch_signals(%{editMode: false})
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

  ### Long-running SSE streams with connection checking

  ```elixir
  def stream(conn, _params) do
    conn = Datastar.init_sse(conn)
    do_stream(conn, items())
  end

  defp do_stream(conn, []), do: conn

  defp do_stream(conn, [item | rest]) do
    case Datastar.check_connection(conn) do
      {:ok, conn} ->
        conn
        |> Datastar.patch_fragment(render_item(item))
        |> do_stream(rest)

      {:error, _conn} ->
        # Client disconnected — stop streaming silently
        conn
    end
  end
  ```

  ## SSE Event Protocol

  Each SSE event emitted by this library follows the format required by the
  [Datastar SSE specification](https://data-star.dev/reference/sse_events):

  ```
  event: <event-type>\\n
  [id: <event-id>\\n]
  [retry: <ms>\\n]
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

  - **`patch_signals/3`** — Signal values are JSON-encoded via `Jason`, so they
    are safe against injection in the SSE stream itself. However, if signal
    values are later rendered into HTML on the server, standard output-encoding
    rules apply.

  - **`execute_script/3`** — Executes arbitrary JavaScript on the client. Only
    pass **server-controlled** strings. Never interpolate user input directly
    into the script string.

  - **`redirect_to/3`** — The URL is JSON-encoded via `Jason` before being
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
  @type merge_mode :: String.t()

  @typedoc """
  The XML namespace in which `patch_fragment/3` creates new elements.

  | Value | Description |
  |-------|-------------|
  | `"html"` | **Default.** Standard HTML elements. |
  | `"svg"` | SVG namespace — use when patching `<svg>` fragments. |
  | `"mathml"` | MathML namespace — use when patching mathematical notation. |
  """
  @type namespace :: String.t()

  @valid_merge_modes ~w(outer inner replace prepend append before after remove)
  @valid_namespaces ~w(html svg mathml)
  @default_merge_mode "outer"
  @default_namespace "html"

  # ---------------------------------------------------------------------------
  # Connection lifecycle
  # ---------------------------------------------------------------------------

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
  Checks whether the SSE connection is still alive.

  Sends a blank SSE comment line to the client. If the client has
  disconnected, the underlying `chunk/2` call will return `{:error, reason}`
  and this function returns `{:error, conn}`.

  Unlike the other SSE functions, `check_connection/1` returns a tagged
  tuple rather than a plain `Plug.Conn.t()` so that callers can branch on
  whether the connection is alive. This makes it useful in long-running SSE
  handlers where you want to stop streaming when the client disconnects.

  ## Example

      defp stream_items(conn, []), do: conn

      defp stream_items(conn, [item | rest]) do
        case Datastar.check_connection(conn) do
          {:ok, conn} ->
            conn
            |> Datastar.patch_fragment(render_item(item))
            |> stream_items(rest)

          {:error, _conn} ->
            conn
        end
      end

  """
  @spec check_connection(Plug.Conn.t()) :: {:ok, Plug.Conn.t()} | {:error, Plug.Conn.t()}
  def check_connection(conn) do
    # SSE comment line — valid SSE, ignored by any client parser.
    case chunk(conn, ": \n\n") do
      {:ok, conn} -> {:ok, conn}
      {:error, _reason} -> {:error, conn}
    end
  rescue
    ArgumentError -> {:error, conn}
  end

  # ---------------------------------------------------------------------------
  # DOM patching
  # ---------------------------------------------------------------------------

  @doc """
  Sends a `datastar-patch-elements` SSE event to patch HTML into the DOM.

  Datastar morphs the incoming HTML into the existing DOM using the `"outer"`
  mode by default (id-based element matching + morphing diff). Other merge
  modes can be selected via the `:merge_mode` option.

  Multi-line HTML is split into multiple `data: elements` lines as required
  by the SSE protocol.

  > #### Security {: .warning}
  >
  > HTML is written verbatim to the SSE stream. **Sanitise any user-supplied
  > content** before passing it to this function to prevent XSS.

  ## Options

  - `:selector` — CSS selector for the target element (e.g. `"#my-div"`).
    When omitted, Datastar matches top-level elements by `id` in `"outer"` or
    `"replace"` mode.
  - `:merge_mode` — How to apply the patch. Defaults to `"outer"`.
    See `t:merge_mode/0` for all allowed values.
  - `:namespace` — XML namespace for new elements. Defaults to `"html"`.
    Use `"svg"` or `"mathml"` when patching SVG or MathML fragments.
    See `t:namespace/0`.
  - `:use_view_transition` — When `true`, wraps the DOM patch in the browser's
    [View Transitions API](https://developer.mozilla.org/en-US/docs/Web/API/View_Transitions_API)
    for animated transitions. The browser must support the API; Datastar
    silently falls back to a plain patch when it does not. Defaults to `false`.
  - `:event_id` — Optional SSE event `id` field. Allows the client to replay
    missed events after a reconnect (standard SSE `Last-Event-ID` mechanism).
  - `:retry_duration` — Optional client reconnect delay in milliseconds
    (standard SSE `retry:` field). Only emitted when provided.

  ## Examples

      # Default morph — element id must exist in the DOM
      conn |> Datastar.patch_fragment(~s(<div id="greeting">Hello!</div>))

      # Append a new item to a list
      conn |> Datastar.patch_fragment("<li>New item</li>",
        selector: "#item-list",
        merge_mode: "append"
      )

      # Patch an SVG fragment
      conn |> Datastar.patch_fragment("<circle cx=\\"50\\" cy=\\"50\\" r=\\"40\\"/>",
        selector: "#chart",
        merge_mode: "inner",
        namespace: "svg"
      )

      # Animated patch with View Transitions
      conn |> Datastar.patch_fragment(html, use_view_transition: true)

      # With SSE event tracking
      conn |> Datastar.patch_fragment(html, event_id: "evt-42", retry_duration: 5000)

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
    namespace = opts[:namespace] || @default_namespace
    use_view_transition = opts[:use_view_transition] || false

    validate_merge_mode!(mode)
    validate_namespace!(namespace)

    header = build_event_header("datastar-patch-elements", opts)
    selector_line = if selector, do: "data: selector #{selector}\n", else: ""

    # Only emit mode line when it differs from Datastar's default merge mode ("outer").
    # The Datastar client defaults to "outer", which matches @default_merge_mode,
    # so we only need to send the line when explicitly overriding.
    mode_line = if mode == @default_merge_mode, do: "", else: "data: mode #{mode}\n"

    # Only emit namespace when it differs from the default "html".
    namespace_line =
      if namespace == @default_namespace, do: "", else: "data: namespace #{namespace}\n"

    # Only emit useViewTransition when true; false is the server-side default.
    view_transition_line =
      if use_view_transition, do: "data: useViewTransition true\n", else: ""

    element_lines =
      html
      |> String.split("\n")
      |> Enum.map_join("\n", &"data: elements #{&1}")

    event =
      "#{header}#{selector_line}#{mode_line}#{namespace_line}#{view_transition_line}#{element_lines}\n\n"

    write_chunk(conn, event)
  end

  @doc """
  Sends a `datastar-patch-elements` event with `mode: remove` to remove a DOM element.

  Removes all elements matching `selector` from the DOM. No HTML content is
  needed — the `remove` merge mode requires only the selector.

  ## Options

  - `:event_id` — Optional SSE event `id` field.
  - `:retry_duration` — Optional client reconnect delay in milliseconds.

  ## Example

      # Remove an item row after it has been deleted on the server
      conn |> Datastar.remove_fragment("#item-42")

  ## SSE format emitted

      event: datastar-patch-elements
      data: selector #item-42
      data: mode remove

  """
  @spec remove_fragment(Plug.Conn.t(), String.t(), keyword()) :: Plug.Conn.t()
  def remove_fragment(conn, selector, opts \\ []) when is_binary(selector) do
    header = build_event_header("datastar-patch-elements", opts)
    event = "#{header}data: selector #{selector}\ndata: mode remove\n\n"
    write_chunk(conn, event)
  end

  # ---------------------------------------------------------------------------
  # Signals
  # ---------------------------------------------------------------------------

  @doc """
  Sends a `datastar-patch-signals` SSE event to update client-side signals.

  The `signals` map is JSON-encoded and sent to the Datastar client, which
  merges the values into its signal store. Existing signals with matching keys
  are updated; new keys are added. Setting a signal value to `nil` removes it
  from the client store.

  > #### Encoding {: .info}
  >
  > Signal values are encoded with `Jason.encode!/1`. Map keys may be atoms or
  > strings; atoms are serialised as strings.

  ## Options

  - `:only_if_missing` — When `true`, only signals that do **not** already
    exist in the client signal store are patched. Existing signal values are
    left unchanged. Useful for setting initial/default values. Defaults to
    `false`.
  - `:event_id` — Optional SSE event `id` field.
  - `:retry_duration` — Optional client reconnect delay in milliseconds.

  ## Examples

      conn |> Datastar.patch_signals(%{count: 42, loading: false})

      # Remove a signal by setting it to nil
      conn |> Datastar.patch_signals(%{temp_error: nil})

      # Only set signals that the client doesn't already have
      conn |> Datastar.patch_signals(%{theme: "dark", locale: "en"}, only_if_missing: true)

  ## SSE format emitted

      event: datastar-patch-signals
      data: signals {"count":42,"loading":false}

      # With onlyIfMissing:
      event: datastar-patch-signals
      data: onlyIfMissing true
      data: signals {"theme":"dark"}

  """
  @spec patch_signals(Plug.Conn.t(), map(), keyword()) :: Plug.Conn.t()
  def patch_signals(conn, signals, opts \\ []) when is_map(signals) do
    only_if_missing = opts[:only_if_missing] || false
    header = build_event_header("datastar-patch-signals", opts)
    json = Jason.encode!(signals)

    only_if_missing_line =
      if only_if_missing, do: "data: onlyIfMissing true\n", else: ""

    event = "#{header}#{only_if_missing_line}data: signals #{json}\n\n"
    write_chunk(conn, event)
  end

  @doc """
  Removes one or more signals from the client signal store.

  Accepts a single dot-notated path string or a list of paths. Each path is
  converted into a nested map entry with a `nil` value and sent via
  `patch_signals/3`. Setting a signal to `nil` removes it from the Datastar
  client's signal store (standard JSON Merge Patch / RFC 7396 semantics).

  ## Options

  Same as `patch_signals/3`: `:only_if_missing`, `:event_id`, `:retry_duration`.

  ## Examples

      # Remove a single top-level signal
      conn |> Datastar.remove_signals("loading")

      # Remove a nested signal using dot notation
      conn |> Datastar.remove_signals("user.preferences.theme")

      # Remove multiple signals in one event
      conn |> Datastar.remove_signals(["user.name", "user.email", "cart"])

      # Shared-prefix paths are merged correctly
      conn |> Datastar.remove_signals(["user.firstName", "user.lastName"])
      # Sends: {"user":{"firstName":null,"lastName":null}}

  ## SSE format emitted

      event: datastar-patch-signals
      data: signals {"user":{"name":null,"email":null},"cart":null}

  """
  @spec remove_signals(Plug.Conn.t(), String.t() | [String.t()], keyword()) :: Plug.Conn.t()
  def remove_signals(conn, paths, opts \\ []) do
    signals =
      paths
      |> List.wrap()
      |> Enum.reduce(%{}, fn path, acc ->
        validate_signal_path!(path)

        path
        |> String.split(".")
        |> set_nil_at_path(acc)
      end)

    patch_signals(conn, signals, opts)
  end

  # ---------------------------------------------------------------------------
  # Script execution & navigation
  # ---------------------------------------------------------------------------

  @doc """
  Executes a JavaScript snippet on the client.

  Internally sends a `datastar-patch-elements` event that appends a `<script>`
  tag to the document `<body>`. This is the Datastar-recommended pattern for
  executing arbitrary scripts from an SSE stream.

  > #### Security {: .warning}
  >
  > Only pass **server-controlled** strings to this function. Never interpolate
  > user input directly into `script` — doing so creates an XSS vulnerability.

  ## Options

  - `:auto_remove` — When `true`, adds a `data-effect="el.remove()"` attribute
    to the injected `<script>` tag. Datastar's reactive system then removes the
    element from the DOM after it executes, keeping the DOM clean. Defaults to
    `false`.
  - `:event_id` — Optional SSE event `id` field.
  - `:retry_duration` — Optional client reconnect delay in milliseconds.

  ## Examples

      conn |> Datastar.execute_script("console.log('hello from Elixir')")

      # Auto-remove the script tag after execution
      conn |> Datastar.execute_script("doSomething()", auto_remove: true)

  ## SSE format emitted

      event: datastar-patch-elements
      data: selector body
      data: mode append
      data: elements <script>console.log('hello from Elixir')</script>

      # With auto_remove: true
      data: elements <script data-effect="el.remove()">doSomething()</script>

  """
  @spec execute_script(Plug.Conn.t(), String.t(), keyword()) :: Plug.Conn.t()
  def execute_script(conn, script, opts \\ []) when is_binary(script) do
    auto_remove = opts[:auto_remove] || false

    script_tag =
      if auto_remove,
        do: ~s[<script data-effect="el.remove()">#{script}</script>],
        else: "<script>#{script}</script>"

    sse_opts = Keyword.take(opts, [:event_id, :retry_duration])

    patch_fragment(conn, script_tag, [merge_mode: "append", selector: "body"] ++ sse_opts)
  end

  @doc """
  Redirects the browser to `url` via a client-side script event.

  Uses `execute_script/3` to send a `window.location.href` assignment wrapped
  in `setTimeout(..., 0)` so it fires after the current event-loop tick,
  giving Datastar time to process any preceding SSE events in the same
  response before the navigation occurs.

  The URL is JSON-encoded before embedding, preventing injection via
  single-quotes, backslashes, or `</script>` in the URL string.

  ## Options

  - `:event_id` — Optional SSE event `id` field.
  - `:retry_duration` — Optional client reconnect delay in milliseconds.

  ## Examples

      conn |> Datastar.redirect_to("/dashboard")

      # Works with absolute URLs too
      conn |> Datastar.redirect_to("https://example.com/logout")

      # With SSE event tracking
      conn |> Datastar.redirect_to("/login", event_id: "redirect-1")

  """
  @spec redirect_to(Plug.Conn.t(), String.t(), keyword()) :: Plug.Conn.t()
  def redirect_to(conn, url, opts \\ []) when is_binary(url) do
    execute_script(
      conn,
      "setTimeout(() => { window.location.href = #{Jason.encode!(url)} }, 0)",
      opts
    )
  end

  # ---------------------------------------------------------------------------
  # Signal parsing
  # ---------------------------------------------------------------------------

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

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Builds the opening lines of an SSE event: event type, optional id, optional retry.
  defp build_event_header(event_type, opts) do
    event_id = opts[:event_id]
    retry_duration = opts[:retry_duration]

    id_line = if event_id, do: "id: #{event_id}\n", else: ""

    retry_line =
      if is_integer(retry_duration) && retry_duration >= 0,
        do: "retry: #{retry_duration}\n",
        else: ""

    "event: #{event_type}\n#{id_line}#{retry_line}"
  end

  # Writes an SSE event string to the chunked connection.
  # On client disconnect ({:error, _}), returns the original conn unchanged.
  # Subsequent pipeline calls will also silently fail on disconnect — this is
  # intentional: it prevents noisy crash logs when browsers close the tab.
  defp write_chunk(conn, event) do
    case chunk(conn, event) do
      {:ok, conn} -> conn
      {:error, _reason} -> conn
    end
  end

  # Recursively builds a nested map with nil at the given key path.
  # Merges correctly when multiple paths share a prefix.
  defp set_nil_at_path([key], acc), do: Map.put(acc, key, nil)

  defp set_nil_at_path([key | rest], acc) do
    existing = Map.get(acc, key)
    nested = if is_map(existing), do: existing, else: %{}
    Map.put(acc, key, set_nil_at_path(rest, nested))
  end

  defp validate_merge_mode!(mode) do
    if mode not in @valid_merge_modes do
      raise ArgumentError,
            "invalid merge_mode #{inspect(mode)}. Must be one of: #{Enum.join(@valid_merge_modes, ", ")}"
    end
  end

  defp validate_namespace!(namespace) do
    if namespace not in @valid_namespaces do
      raise ArgumentError,
            "invalid namespace #{inspect(namespace)}. Must be one of: #{Enum.join(@valid_namespaces, ", ")}"
    end
  end

  defp validate_signal_path!(path) when is_binary(path) do
    segments = String.split(path, ".")

    if path == "" or Enum.any?(segments, &(&1 == "")) do
      raise ArgumentError,
            "invalid signal path #{inspect(path)}. Path must be a non-empty string with no empty segments (e.g. \"user.name\")."
    end
  end
end
