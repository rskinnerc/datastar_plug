defmodule DatastarTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Datastar

  # ---------------------------------------------------------------------------
  # Test helpers
  # ---------------------------------------------------------------------------

  # Opens a fresh GET conn and initialises a chunked SSE response.
  defp sse_conn, do: Datastar.init_sse(conn(:get, "/"))

  # Collects all chunks written to the conn into a single binary.
  # Plug.Test appends each chunk to `conn.resp_body`.
  defp resp_body(conn), do: conn.resp_body

  # ---------------------------------------------------------------------------
  # init_sse/1
  # ---------------------------------------------------------------------------

  describe "init_sse/1" do
    test "sets content-type to text/event-stream" do
      conn = Datastar.init_sse(conn(:get, "/"))
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
    end

    test "sets cache-control header" do
      conn = Datastar.init_sse(conn(:get, "/"))
      assert get_resp_header(conn, "cache-control") == ["no-cache, no-store, must-revalidate"]
    end

    test "sets connection keep-alive header" do
      conn = Datastar.init_sse(conn(:get, "/"))
      assert get_resp_header(conn, "connection") == ["keep-alive"]
    end

    test "disables proxy buffering via x-accel-buffering header" do
      conn = Datastar.init_sse(conn(:get, "/"))
      assert get_resp_header(conn, "x-accel-buffering") == ["no"]
    end

    test "opens a chunked response with status 200" do
      conn = Datastar.init_sse(conn(:get, "/"))
      assert conn.status == 200
      assert conn.state == :chunked
    end

    test "returns a Plug.Conn" do
      result = Datastar.init_sse(conn(:get, "/"))
      assert %Plug.Conn{} = result
    end
  end

  # ---------------------------------------------------------------------------
  # close_sse/1
  # ---------------------------------------------------------------------------

  describe "close_sse/1" do
    test "is a no-op and returns the conn unchanged" do
      conn_before = sse_conn()
      conn_after = Datastar.close_sse(conn_before)
      assert conn_before == conn_after
    end

    test "returns a Plug.Conn" do
      result = Datastar.close_sse(sse_conn())
      assert %Plug.Conn{} = result
    end
  end

  # ---------------------------------------------------------------------------
  # check_connection/1
  # ---------------------------------------------------------------------------

  describe "check_connection/1" do
    test "returns {:ok, conn} on a live connection" do
      assert {:ok, %Plug.Conn{}} = Datastar.check_connection(sse_conn())
    end

    test "the returned conn is still usable for further writes" do
      {:ok, conn} = Datastar.check_connection(sse_conn())
      result = Datastar.patch_signals(conn, %{alive: true})
      assert result.resp_body =~ "datastar-patch-signals"
    end

    test "sends a comment line that does not constitute an SSE event" do
      {:ok, conn} = Datastar.check_connection(sse_conn())
      # A comment line starts with ': ' and is NOT an event line
      assert conn.resp_body =~ ": "
      refute conn.resp_body =~ "event:"
    end

    test "returns {:error, conn} on a dead connection" do
      # Simulate a disconnected conn by using a non-chunked conn
      # (chunk/2 raises when the connection is not chunked - we patch around
      #  this via the :error path of write_chunk/2)
      bad_conn = conn(:get, "/")
      # In Plug.Test a non-chunked conn returns {:error, :not_chunked} on chunk/2
      assert {:error, %Plug.Conn{}} = Datastar.check_connection(bad_conn)
    end
  end

  # ---------------------------------------------------------------------------
  # patch_fragment/3
  # ---------------------------------------------------------------------------

  describe "patch_fragment/3 - basic SSE output" do
    test "emits datastar-patch-elements event type" do
      body =
        sse_conn()
        |> Datastar.patch_fragment("<div id='x'>Hi</div>")
        |> resp_body()

      assert body =~ "event: datastar-patch-elements"
    end

    test "emits elements data line for single-line HTML" do
      html = ~s(<div id="greeting">Hello!</div>)

      body =
        sse_conn()
        |> Datastar.patch_fragment(html)
        |> resp_body()

      assert body =~ "data: elements #{html}"
    end

    test "emits one data: elements line per HTML line for multi-line HTML" do
      html = "<div id=\"container\">\n  <span>content</span>\n</div>"

      body =
        sse_conn()
        |> Datastar.patch_fragment(html)
        |> resp_body()

      assert body =~ "data: elements <div id=\"container\">"
      assert body =~ "data: elements   <span>content</span>"
      assert body =~ "data: elements </div>"
    end

    test "terminates event with a blank line (double newline)" do
      body =
        sse_conn()
        |> Datastar.patch_fragment("<div id='x'>Hi</div>")
        |> resp_body()

      assert body =~ "\n\n"
    end

    test "returns a Plug.Conn" do
      result = Datastar.patch_fragment(sse_conn(), "<div id='x'>Hi</div>")
      assert %Plug.Conn{} = result
    end

    test "HTML containing special characters is written verbatim" do
      html = ~s[<div id="x">&lt;script&gt;alert('xss')&lt;/script&gt;</div>]

      body =
        sse_conn()
        |> Datastar.patch_fragment(html)
        |> resp_body()

      assert body =~ html
    end
  end

  describe "patch_fragment/3 - :selector option" do
    test "does NOT emit a selector line when :selector option is absent" do
      body =
        sse_conn()
        |> Datastar.patch_fragment("<div id='x'>Hi</div>")
        |> resp_body()

      refute body =~ "data: selector"
    end

    test "emits data: selector line when :selector option is provided" do
      body =
        sse_conn()
        |> Datastar.patch_fragment("<li>Item</li>", selector: "#my-list", merge_mode: "inner")
        |> resp_body()

      assert body =~ "data: selector #my-list"
    end

    test "selector appears before mode in the event payload" do
      body =
        sse_conn()
        |> Datastar.patch_fragment("<li>X</li>", selector: "#list", merge_mode: "append")
        |> resp_body()

      {selector_pos, _} = :binary.match(body, "data: selector")
      {mode_pos, _} = :binary.match(body, "data: mode")
      assert selector_pos < mode_pos
    end
  end

  describe "patch_fragment/3 - :merge_mode option" do
    test "does NOT emit a mode line when using default outer mode" do
      body =
        sse_conn()
        |> Datastar.patch_fragment("<div id='x'>Hi</div>")
        |> resp_body()

      refute body =~ "data: mode"
    end

    test "emits data: mode line when merge_mode is not outer (the default)" do
      body =
        sse_conn()
        |> Datastar.patch_fragment("<li>Item</li>", merge_mode: "append", selector: "#list")
        |> resp_body()

      assert body =~ "data: mode append"
    end

    test "raises ArgumentError when an invalid merge_mode is given" do
      assert_raise ArgumentError, ~r/invalid merge_mode/, fn ->
        Datastar.patch_fragment(sse_conn(), "<div>Test</div>", merge_mode: "invalid")
      end
    end

    test "raises ArgumentError for merge_mode 'morph' (removed in v0.2.0)" do
      assert_raise ArgumentError, ~r/invalid merge_mode/, fn ->
        Datastar.patch_fragment(sse_conn(), "<div id='x'>X</div>", merge_mode: "morph")
      end
    end

    test "all valid merge modes are accepted without raising" do
      for mode <- ~w(outer inner replace prepend append before after remove) do
        assert %Plug.Conn{} =
                 Datastar.patch_fragment(sse_conn(), "<div id='x'>Hi</div>",
                   merge_mode: mode,
                   selector: "#x"
                 )
      end
    end

    test "'outer' mode is the default and does not emit a mode line" do
      body =
        sse_conn()
        |> Datastar.patch_fragment("<div id='x'>Hi</div>", merge_mode: "outer")
        |> resp_body()

      refute body =~ "data: mode"
    end

    test "'replace' mode emits data: mode replace" do
      body =
        sse_conn()
        |> Datastar.patch_fragment("<div id='x'>Hi</div>",
          merge_mode: "replace",
          selector: "#x"
        )
        |> resp_body()

      assert body =~ "data: mode replace"
    end
  end

  describe "patch_fragment/3 - :namespace option" do
    test "does NOT emit a namespace line when using default html namespace" do
      body =
        sse_conn()
        |> Datastar.patch_fragment("<div id='x'>Hi</div>")
        |> resp_body()

      refute body =~ "data: namespace"
    end

    test "does NOT emit a namespace line when namespace is explicitly 'html'" do
      body =
        sse_conn()
        |> Datastar.patch_fragment("<div id='x'>Hi</div>", namespace: "html")
        |> resp_body()

      refute body =~ "data: namespace"
    end

    test "emits data: namespace svg when namespace is 'svg'" do
      body =
        sse_conn()
        |> Datastar.patch_fragment(~s(<circle cx="50" cy="50" r="40"/>),
          selector: "#chart",
          merge_mode: "inner",
          namespace: "svg"
        )
        |> resp_body()

      assert body =~ "data: namespace svg"
    end

    test "emits data: namespace mathml when namespace is 'mathml'" do
      body =
        sse_conn()
        |> Datastar.patch_fragment("<mfrac><mn>1</mn><mn>2</mn></mfrac>",
          selector: "#formula",
          merge_mode: "inner",
          namespace: "mathml"
        )
        |> resp_body()

      assert body =~ "data: namespace mathml"
    end

    test "raises ArgumentError for an invalid namespace" do
      assert_raise ArgumentError, ~r/invalid namespace/, fn ->
        Datastar.patch_fragment(sse_conn(), "<div>X</div>", namespace: "xhtml")
      end
    end

    test "namespace line appears after mode in the event payload" do
      body =
        sse_conn()
        |> Datastar.patch_fragment("<circle/>",
          selector: "#chart",
          merge_mode: "append",
          namespace: "svg"
        )
        |> resp_body()

      {mode_pos, _} = :binary.match(body, "data: mode")
      {namespace_pos, _} = :binary.match(body, "data: namespace")
      assert mode_pos < namespace_pos
    end
  end

  describe "patch_fragment/3 - :use_view_transition option" do
    test "does NOT emit useViewTransition line by default" do
      body =
        sse_conn()
        |> Datastar.patch_fragment("<div id='x'>Hi</div>")
        |> resp_body()

      refute body =~ "useViewTransition"
    end

    test "does NOT emit useViewTransition when explicitly set to false" do
      body =
        sse_conn()
        |> Datastar.patch_fragment("<div id='x'>Hi</div>", use_view_transition: false)
        |> resp_body()

      refute body =~ "useViewTransition"
    end

    test "emits data: useViewTransition true when use_view_transition: true" do
      body =
        sse_conn()
        |> Datastar.patch_fragment("<div id='x'>Hi</div>", use_view_transition: true)
        |> resp_body()

      assert body =~ "data: useViewTransition true"
    end

    test "useViewTransition line appears before elements in the payload" do
      body =
        sse_conn()
        |> Datastar.patch_fragment("<div id='x'>Hi</div>", use_view_transition: true)
        |> resp_body()

      {vt_pos, _} = :binary.match(body, "useViewTransition")
      {el_pos, _} = :binary.match(body, "data: elements")
      assert vt_pos < el_pos
    end
  end

  describe "patch_fragment/3 - SSE :event_id and :retry_duration options" do
    test "emits id: line when event_id is provided" do
      body =
        sse_conn()
        |> Datastar.patch_fragment("<div id='x'>Hi</div>", event_id: "evt-42")
        |> resp_body()

      assert body =~ "id: evt-42"
    end

    test "does NOT emit id: line when event_id is absent" do
      body =
        sse_conn()
        |> Datastar.patch_fragment("<div id='x'>Hi</div>")
        |> resp_body()

      refute body =~ "id: "
    end

    test "emits retry: line when retry_duration is provided" do
      body =
        sse_conn()
        |> Datastar.patch_fragment("<div id='x'>Hi</div>", retry_duration: 5000)
        |> resp_body()

      assert body =~ "retry: 5000"
    end

    test "does NOT emit retry: line when retry_duration is absent" do
      body =
        sse_conn()
        |> Datastar.patch_fragment("<div id='x'>Hi</div>")
        |> resp_body()

      refute body =~ "retry:"
    end

    test "id: and retry: lines appear after event: and before data: lines" do
      body =
        sse_conn()
        |> Datastar.patch_fragment("<div id='x'>Hi</div>",
          event_id: "e1",
          retry_duration: 3000
        )
        |> resp_body()

      {event_pos, _} = :binary.match(body, "event:")
      {id_pos, _} = :binary.match(body, "id:")
      {retry_pos, _} = :binary.match(body, "retry:")
      {data_pos, _} = :binary.match(body, "data:")
      assert event_pos < id_pos
      assert id_pos < retry_pos
      assert retry_pos < data_pos
    end

    test "all new opts combine with existing opts correctly" do
      body =
        sse_conn()
        |> Datastar.patch_fragment("<div id='x'>Hi</div>",
          selector: "#x",
          merge_mode: "inner",
          namespace: "html",
          use_view_transition: true,
          event_id: "e-99",
          retry_duration: 2000
        )
        |> resp_body()

      assert body =~ "event: datastar-patch-elements"
      assert body =~ "id: e-99"
      assert body =~ "retry: 2000"
      assert body =~ "data: selector #x"
      assert body =~ "data: mode inner"
      refute body =~ "data: namespace"
      assert body =~ "data: useViewTransition true"
      assert body =~ "data: elements"
    end
  end

  # ---------------------------------------------------------------------------
  # remove_fragment/3
  # ---------------------------------------------------------------------------

  describe "remove_fragment/3" do
    test "emits datastar-patch-elements event type" do
      body =
        sse_conn()
        |> Datastar.remove_fragment("#item-42")
        |> resp_body()

      assert body =~ "event: datastar-patch-elements"
    end

    test "emits data: selector line with the given selector" do
      body =
        sse_conn()
        |> Datastar.remove_fragment("#item-42")
        |> resp_body()

      assert body =~ "data: selector #item-42"
    end

    test "emits data: mode remove" do
      body =
        sse_conn()
        |> Datastar.remove_fragment("#item-42")
        |> resp_body()

      assert body =~ "data: mode remove"
    end

    test "does NOT emit data: elements line (no content needed for remove)" do
      body =
        sse_conn()
        |> Datastar.remove_fragment("#item-42")
        |> resp_body()

      refute body =~ "data: elements"
    end

    test "terminates event with a blank line (double newline)" do
      body =
        sse_conn()
        |> Datastar.remove_fragment("#my-el")
        |> resp_body()

      assert body =~ "\n\n"
    end

    test "returns a Plug.Conn" do
      result = Datastar.remove_fragment(sse_conn(), "#item-42")
      assert %Plug.Conn{} = result
    end

    test "accepts compound CSS selectors" do
      body =
        sse_conn()
        |> Datastar.remove_fragment(".card[data-id='7']")
        |> resp_body()

      assert body =~ "data: selector .card[data-id='7']"
    end

    test "emits id: line when event_id is provided" do
      body =
        sse_conn()
        |> Datastar.remove_fragment("#x", event_id: "rm-1")
        |> resp_body()

      assert body =~ "id: rm-1"
    end

    test "emits retry: line when retry_duration is provided" do
      body =
        sse_conn()
        |> Datastar.remove_fragment("#x", retry_duration: 3000)
        |> resp_body()

      assert body =~ "retry: 3000"
    end
  end

  # ---------------------------------------------------------------------------
  # patch_signals/3
  # ---------------------------------------------------------------------------

  describe "patch_signals/3 - basic SSE output" do
    test "emits datastar-patch-signals event type" do
      body =
        sse_conn()
        |> Datastar.patch_signals(%{count: 1})
        |> resp_body()

      assert body =~ "event: datastar-patch-signals"
    end

    test "emits data: signals line with JSON-encoded map" do
      body =
        sse_conn()
        |> Datastar.patch_signals(%{count: 42})
        |> resp_body()

      assert body =~ ~s(data: signals {"count":42})
    end

    test "encodes multiple signal keys" do
      body =
        sse_conn()
        |> Datastar.patch_signals(%{loading: false, total: 10})
        |> resp_body()

      assert body =~ "data: signals"
      assert body =~ ~s("loading":false)
      assert body =~ ~s("total":10)
    end

    test "encodes string keys" do
      body =
        sse_conn()
        |> Datastar.patch_signals(%{"status" => "ok"})
        |> resp_body()

      assert body =~ ~s("status":"ok")
    end

    test "encodes nil values (removes the signal from the client)" do
      body =
        sse_conn()
        |> Datastar.patch_signals(%{removed: nil})
        |> resp_body()

      assert body =~ ~s("removed":null)
    end

    test "terminates event with a blank line" do
      body =
        sse_conn()
        |> Datastar.patch_signals(%{x: 1})
        |> resp_body()

      assert body =~ "\n\n"
    end

    test "returns a Plug.Conn" do
      result = Datastar.patch_signals(sse_conn(), %{x: 1})
      assert %Plug.Conn{} = result
    end

    test "accepts an empty map" do
      body =
        sse_conn()
        |> Datastar.patch_signals(%{})
        |> resp_body()

      assert body =~ "data: signals {}"
    end
  end

  describe "patch_signals/3 - :only_if_missing option" do
    test "does NOT emit onlyIfMissing line by default" do
      body =
        sse_conn()
        |> Datastar.patch_signals(%{count: 1})
        |> resp_body()

      refute body =~ "onlyIfMissing"
    end

    test "does NOT emit onlyIfMissing when explicitly false" do
      body =
        sse_conn()
        |> Datastar.patch_signals(%{count: 1}, only_if_missing: false)
        |> resp_body()

      refute body =~ "onlyIfMissing"
    end

    test "emits data: onlyIfMissing true when only_if_missing: true" do
      body =
        sse_conn()
        |> Datastar.patch_signals(%{theme: "dark"}, only_if_missing: true)
        |> resp_body()

      assert body =~ "data: onlyIfMissing true"
    end

    test "onlyIfMissing line appears before the signals line" do
      body =
        sse_conn()
        |> Datastar.patch_signals(%{theme: "dark"}, only_if_missing: true)
        |> resp_body()

      {oim_pos, _} = :binary.match(body, "onlyIfMissing")
      {sig_pos, _} = :binary.match(body, "data: signals")
      assert oim_pos < sig_pos
    end
  end

  describe "patch_signals/3 - SSE :event_id and :retry_duration options" do
    test "emits id: line when event_id is provided" do
      body =
        sse_conn()
        |> Datastar.patch_signals(%{x: 1}, event_id: "sig-1")
        |> resp_body()

      assert body =~ "id: sig-1"
    end

    test "emits retry: line when retry_duration is provided" do
      body =
        sse_conn()
        |> Datastar.patch_signals(%{x: 1}, retry_duration: 4000)
        |> resp_body()

      assert body =~ "retry: 4000"
    end

    test "all opts combine correctly" do
      body =
        sse_conn()
        |> Datastar.patch_signals(%{theme: "dark"},
          only_if_missing: true,
          event_id: "s-1",
          retry_duration: 2000
        )
        |> resp_body()

      assert body =~ "id: s-1"
      assert body =~ "retry: 2000"
      assert body =~ "data: onlyIfMissing true"
      assert body =~ ~s("theme":"dark")
    end
  end

  # ---------------------------------------------------------------------------
  # remove_signals/3
  # ---------------------------------------------------------------------------

  describe "remove_signals/3 - path parsing" do
    test "removes a top-level signal by setting it to null" do
      body =
        sse_conn()
        |> Datastar.remove_signals("loading")
        |> resp_body()

      assert body =~ ~s("loading":null)
    end

    test "removes a nested signal via dot notation" do
      body =
        sse_conn()
        |> Datastar.remove_signals("user.name")
        |> resp_body()

      assert body =~ ~s("user":{"name":null})
    end

    test "removes deeply nested signals via dot notation" do
      body =
        sse_conn()
        |> Datastar.remove_signals("app.settings.theme.color")
        |> resp_body()

      assert body =~ ~s("app":)
      assert body =~ ~s("settings":)
      assert body =~ ~s("theme":)
      assert body =~ ~s("color":null)
    end

    test "removes multiple top-level signals in one event" do
      body =
        sse_conn()
        |> Datastar.remove_signals(["loading", "error"])
        |> resp_body()

      assert body =~ ~s("loading":null)
      assert body =~ ~s("error":null)
    end

    test "removes multiple nested signals in one event" do
      body =
        sse_conn()
        |> Datastar.remove_signals(["user.name", "user.email"])
        |> resp_body()

      assert body =~ ~s("user":)
      assert body =~ ~s("name":null)
      assert body =~ ~s("email":null)
    end

    test "merges shared prefixes correctly - does not overwrite sibling keys" do
      body =
        sse_conn()
        |> Datastar.remove_signals(["user.firstName", "user.lastName"])
        |> resp_body()

      decoded =
        body
        |> extract_signals_json()
        |> Jason.decode!()

      assert decoded["user"]["firstName"] == nil
      assert decoded["user"]["lastName"] == nil
      assert map_size(decoded["user"]) == 2
    end

    test "handles a list with a single path identically to a plain string" do
      body_string =
        sse_conn()
        |> Datastar.remove_signals("key")
        |> resp_body()

      body_list =
        sse_conn()
        |> Datastar.remove_signals(["key"])
        |> resp_body()

      assert extract_signals_json(body_string) == extract_signals_json(body_list)
    end

    test "emits datastar-patch-signals event type" do
      body =
        sse_conn()
        |> Datastar.remove_signals("loading")
        |> resp_body()

      assert body =~ "event: datastar-patch-signals"
    end

    test "returns a Plug.Conn" do
      result = Datastar.remove_signals(sse_conn(), "loading")
      assert %Plug.Conn{} = result
    end
  end

  describe "remove_signals/3 - inherited opts" do
    test "passes only_if_missing: true through to patch_signals" do
      body =
        sse_conn()
        |> Datastar.remove_signals("temp", only_if_missing: true)
        |> resp_body()

      assert body =~ "data: onlyIfMissing true"
    end

    test "passes event_id through to patch_signals" do
      body =
        sse_conn()
        |> Datastar.remove_signals("temp", event_id: "rm-sig-1")
        |> resp_body()

      assert body =~ "id: rm-sig-1"
    end

    test "passes retry_duration through to patch_signals" do
      body =
        sse_conn()
        |> Datastar.remove_signals("temp", retry_duration: 3000)
        |> resp_body()

      assert body =~ "retry: 3000"
    end
  end

  # ---------------------------------------------------------------------------
  # execute_script/3
  # ---------------------------------------------------------------------------

  describe "execute_script/3 - basic output" do
    test "wraps script in a <script> tag" do
      body =
        sse_conn()
        |> Datastar.execute_script("console.log('hi')")
        |> resp_body()

      assert body =~ "data: elements <script>console.log('hi')</script>"
    end

    test "targets the body element as selector" do
      body =
        sse_conn()
        |> Datastar.execute_script("console.log('hi')")
        |> resp_body()

      assert body =~ "data: selector body"
    end

    test "uses append merge mode" do
      body =
        sse_conn()
        |> Datastar.execute_script("console.log('hi')")
        |> resp_body()

      assert body =~ "data: mode append"
    end

    test "emits datastar-patch-elements event type" do
      body =
        sse_conn()
        |> Datastar.execute_script("console.log('hi')")
        |> resp_body()

      assert body =~ "event: datastar-patch-elements"
    end

    test "returns a Plug.Conn" do
      result = Datastar.execute_script(sse_conn(), "1 + 1")
      assert %Plug.Conn{} = result
    end

    test "preserves the full script body unchanged" do
      script = "document.getElementById('x').classList.add('active')"

      body =
        sse_conn()
        |> Datastar.execute_script(script)
        |> resp_body()

      assert body =~ script
    end
  end

  describe "execute_script/3 - :auto_remove option" do
    test "does NOT add data-effect attribute by default" do
      body =
        sse_conn()
        |> Datastar.execute_script("console.log('hi')")
        |> resp_body()

      refute body =~ "data-effect"
    end

    test "does NOT add data-effect when auto_remove: false" do
      body =
        sse_conn()
        |> Datastar.execute_script("console.log('hi')", auto_remove: false)
        |> resp_body()

      refute body =~ "data-effect"
    end

    test "adds data-effect='el.remove()' when auto_remove: true" do
      body =
        sse_conn()
        |> Datastar.execute_script("doSomething()", auto_remove: true)
        |> resp_body()

      assert body =~ ~s[data-effect="el.remove()"]
    end

    test "script body is still present when auto_remove: true" do
      body =
        sse_conn()
        |> Datastar.execute_script("doSomething()", auto_remove: true)
        |> resp_body()

      assert body =~ "doSomething()"
    end

    test "auto_remove script tag has correct format" do
      body =
        sse_conn()
        |> Datastar.execute_script("run()", auto_remove: true)
        |> resp_body()

      assert body =~ ~s[<script data-effect="el.remove()">run()</script>]
    end
  end

  describe "execute_script/3 - SSE :event_id and :retry_duration options" do
    test "emits id: line when event_id is provided" do
      body =
        sse_conn()
        |> Datastar.execute_script("run()", event_id: "script-1")
        |> resp_body()

      assert body =~ "id: script-1"
    end

    test "emits retry: line when retry_duration is provided" do
      body =
        sse_conn()
        |> Datastar.execute_script("run()", retry_duration: 2500)
        |> resp_body()

      assert body =~ "retry: 2500"
    end

    test "all opts combine correctly" do
      body =
        sse_conn()
        |> Datastar.execute_script("run()",
          auto_remove: true,
          event_id: "s-99",
          retry_duration: 1500
        )
        |> resp_body()

      assert body =~ "id: s-99"
      assert body =~ "retry: 1500"
      assert body =~ ~s[data-effect="el.remove()"]
      assert body =~ "run()"
    end
  end

  # ---------------------------------------------------------------------------
  # redirect_to/3
  # ---------------------------------------------------------------------------

  describe "redirect_to/3" do
    test "emits a script that sets window.location.href" do
      body =
        sse_conn()
        |> Datastar.redirect_to("/dashboard")
        |> resp_body()

      assert body =~ ~s(window.location.href = "/dashboard")
    end

    test "wraps the redirect in setTimeout for deferred execution" do
      body =
        sse_conn()
        |> Datastar.redirect_to("/home")
        |> resp_body()

      assert body =~ "setTimeout"
    end

    test "sends the event via execute_script (targets body with append)" do
      body =
        sse_conn()
        |> Datastar.redirect_to("/home")
        |> resp_body()

      assert body =~ "data: selector body"
      assert body =~ "data: mode append"
    end

    test "URL is JSON-encoded to safely handle query strings" do
      body =
        sse_conn()
        |> Datastar.redirect_to("/path?a=1&b=2")
        |> resp_body()

      assert body =~ ~s("/path?a=1&b=2")
    end

    test "URL is JSON-encoded to prevent single-quote injection" do
      body =
        sse_conn()
        |> Datastar.redirect_to("/path?x=it's")
        |> resp_body()

      # Jason encodes the apostrophe safely inside a JSON string
      assert body =~ ~s("/path?x=it's")
    end

    test "works with an absolute URL including scheme and domain" do
      # Build the URL at runtime to avoid Elixir 1.18 lexer quirks with URL schemes
      url = "https" <> "://example.com/logout"

      body =
        sse_conn()
        |> Datastar.redirect_to(url)
        |> resp_body()

      assert body =~ "example.com/logout"
      assert body =~ "window.location.href"
    end

    test "returns a Plug.Conn" do
      result = Datastar.redirect_to(sse_conn(), "/home")
      assert %Plug.Conn{} = result
    end

    test "emits id: line when event_id is provided" do
      body =
        sse_conn()
        |> Datastar.redirect_to("/home", event_id: "redir-1")
        |> resp_body()

      assert body =~ "id: redir-1"
    end

    test "emits retry: line when retry_duration is provided" do
      body =
        sse_conn()
        |> Datastar.redirect_to("/home", retry_duration: 2000)
        |> resp_body()

      assert body =~ "retry: 2000"
    end
  end

  # ---------------------------------------------------------------------------
  # parse_signals/1
  # ---------------------------------------------------------------------------

  describe "parse_signals/1 - GET: nested JSON string" do
    test "decodes a JSON string from the 'datastar' key" do
      params = %{"datastar" => ~s({"name":"Alice","count":3})}
      assert Datastar.parse_signals(params) == %{"name" => "Alice", "count" => 3}
    end

    test "returns an empty map when the JSON string is an empty object" do
      assert Datastar.parse_signals(%{"datastar" => "{}"}) == %{}
    end

    test "returns an empty map when the JSON string is invalid" do
      assert Datastar.parse_signals(%{"datastar" => "not-json"}) == %{}
    end

    test "returns an empty map when the JSON value is an array (not a map)" do
      assert Datastar.parse_signals(%{"datastar" => "[1,2,3]"}) == %{}
    end

    test "passes through the map when the datastar value is not a string" do
      assert Datastar.parse_signals(%{"datastar" => 42}) == %{"datastar" => 42}
    end

    test "handles nested signal objects" do
      params = %{"datastar" => ~s({"user":{"name":"Bob"},"count":7})}
      result = Datastar.parse_signals(params)
      assert result["user"]["name"] == "Bob"
      assert result["count"] == 7
    end
  end

  describe "parse_signals/1 - POST: decoded map from body parser" do
    test "returns the params map directly when no 'datastar' wrapper key" do
      params = %{"title" => "hello", "done" => false}
      assert Datastar.parse_signals(params) == params
    end

    test "returns the params map including route parameters" do
      params = %{"id" => "7", "title" => "updated"}
      assert Datastar.parse_signals(params) == params
    end

    test "returns an empty map when given an empty map" do
      assert Datastar.parse_signals(%{}) == %{}
    end

    test "returns nested maps unchanged" do
      params = %{"user" => %{"name" => "Alice"}}
      assert Datastar.parse_signals(params) == params
    end
  end

  describe "parse_signals/1 - fallback" do
    test "returns an empty map for nil input" do
      assert Datastar.parse_signals(nil) == %{}
    end

    test "returns an empty map for a list input" do
      assert Datastar.parse_signals([1, 2, 3]) == %{}
    end

    test "returns an empty map for a binary input (non-map)" do
      assert Datastar.parse_signals("raw string") == %{}
    end

    test "returns an empty map for an integer input" do
      assert Datastar.parse_signals(42) == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # Pipeline composition
  # ---------------------------------------------------------------------------

  describe "pipeline composition" do
    test "multiple events can be chained in a single pipeline" do
      body =
        sse_conn()
        |> Datastar.patch_fragment(~s(<div id="title">Hi</div>))
        |> Datastar.patch_signals(%{loaded: true})
        |> Datastar.close_sse()
        |> resp_body()

      assert body =~ "event: datastar-patch-elements"
      assert body =~ ~s(data: elements <div id="title">Hi</div>)
      assert body =~ "event: datastar-patch-signals"
      assert body =~ ~s("loaded":true)
    end

    test "all event types can appear in a single response" do
      body =
        sse_conn()
        |> Datastar.patch_fragment(~s(<div id="x">updated</div>))
        |> Datastar.patch_signals(%{ready: true})
        |> Datastar.execute_script("console.log('done')")
        |> Datastar.remove_fragment("#spinner")
        |> Datastar.remove_signals("loading")
        |> Datastar.close_sse()
        |> resp_body()

      assert body =~ "event: datastar-patch-elements"
      assert body =~ "event: datastar-patch-signals"
      assert body =~ "data: elements <script>"
      assert body =~ "data: selector #spinner"
      assert body =~ "data: mode remove"
      assert body =~ ~s("loading":null)
    end

    test "events appear in pipeline order" do
      body =
        sse_conn()
        |> Datastar.patch_fragment(~s(<div id="a">first</div>))
        |> Datastar.patch_signals(%{step: 1})
        |> resp_body()

      {elements_pos, _} = :binary.match(body, "datastar-patch-elements")
      {signals_pos, _} = :binary.match(body, "datastar-patch-signals")
      assert elements_pos < signals_pos
    end

    test "remove_signals and patch_signals can be interleaved" do
      body =
        sse_conn()
        |> Datastar.patch_signals(%{loading: true})
        |> Datastar.remove_signals("error")
        |> Datastar.patch_signals(%{data: "ready"})
        |> resp_body()

      assert body =~ ~s("loading":true)
      assert body =~ ~s("error":null)
      assert body =~ ~s("data":"ready")
    end
  end

  # ---------------------------------------------------------------------------
  # Private helper: extract_signals_json/1
  # ---------------------------------------------------------------------------

  # Extracts the JSON string from a `data: signals {...}` line in a raw SSE body.
  defp extract_signals_json(body) do
    body
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case Regex.run(~r/^data: signals (.+)$/, String.trim(line)) do
        [_, json] -> json
        _ -> nil
      end
    end)
  end
end
