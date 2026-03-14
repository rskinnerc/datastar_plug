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
  # patch_fragment/3
  # ---------------------------------------------------------------------------

  describe "patch_fragment/3" do
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

    test "terminates event with a blank line (double newline)" do
      body =
        sse_conn()
        |> Datastar.patch_fragment("<div id='x'>Hi</div>")
        |> resp_body()

      assert body =~ "\n\n"
    end

    test "raises ArgumentError when an invalid merge_mode is given" do
      assert_raise ArgumentError, ~r/invalid merge_mode/, fn ->
        Datastar.patch_fragment(sse_conn(), "<div>Test</div>", merge_mode: "invalid")
      end
    end

    test "returns a Plug.Conn" do
      result = Datastar.patch_fragment(sse_conn(), "<div id='x'>Hi</div>")
      assert %Plug.Conn{} = result
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

    test "selector appears before mode in the event payload" do
      body =
        sse_conn()
        |> Datastar.patch_fragment("<li>X</li>", selector: "#list", merge_mode: "append")
        |> resp_body()

      {selector_pos, _} = :binary.match(body, "data: selector")
      {mode_pos, _} = :binary.match(body, "data: mode")
      assert selector_pos < mode_pos
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

  # ---------------------------------------------------------------------------
  # patch_signals/2
  # ---------------------------------------------------------------------------

  describe "patch_signals/2" do
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

    test "encodes nil values" do
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

  # ---------------------------------------------------------------------------
  # execute_script/2
  # ---------------------------------------------------------------------------

  describe "execute_script/2" do
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

  # ---------------------------------------------------------------------------
  # redirect_to/2
  # ---------------------------------------------------------------------------

  describe "redirect_to/2" do
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

    test "works with an absolute URL" do
      body =
        sse_conn()
        |> Datastar.redirect_to("https://example.com/logout")
        |> resp_body()

      assert body =~ ~s("https://example.com/logout")
    end

    test "returns a Plug.Conn" do
      result = Datastar.redirect_to(sse_conn(), "/home")
      assert %Plug.Conn{} = result
    end
  end

  # ---------------------------------------------------------------------------
  # remove_fragment/2
  # ---------------------------------------------------------------------------

  describe "remove_fragment/2" do
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
  # parse_signals/1
  # ---------------------------------------------------------------------------

  describe "parse_signals/1 — GET (nested JSON string)" do
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
  end

  describe "parse_signals/1 — POST (decoded map from body parser)" do
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
  end

  describe "parse_signals/1 — fallback" do
    test "returns an empty map for nil input" do
      assert Datastar.parse_signals(nil) == %{}
    end

    test "returns an empty map for a list input" do
      assert Datastar.parse_signals([1, 2, 3]) == %{}
    end

    test "returns an empty map for a binary input (non-map)" do
      assert Datastar.parse_signals("raw string") == %{}
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
        |> Datastar.close_sse()
        |> resp_body()

      assert body =~ "event: datastar-patch-elements"
      assert body =~ "event: datastar-patch-signals"
      assert body =~ "data: elements <script>"
      assert body =~ "data: selector #spinner"
      assert body =~ "data: mode remove"
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
  end
end
