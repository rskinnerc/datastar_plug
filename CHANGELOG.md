# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-03-14

### Added

- `Datastar.check_connection/1` — Sends a blank SSE comment to the client to
  verify the connection is still alive. Returns `{:ok, conn}` on success or
  `{:error, conn}` when the client has disconnected. Useful for long-running
  SSE streams.
- `Datastar.remove_signals/3` — Removes one or more client-side signals by
  sending a `datastar-patch-signals` event with `nil` values. Accepts a single
  dot-notated path string or a list of paths; shared prefixes are merged
  correctly into a single JSON payload.
- `patch_fragment/3` — `:namespace` option — sets the XML namespace for new
  elements (`"html"` default, `"svg"`, or `"mathml"`).
- `patch_fragment/3` — `:use_view_transition` option — when `true`, wraps the
  DOM patch in the browser's View Transitions API.
- `patch_signals/3` — `:only_if_missing` option — only patches signals that do
  not already exist in the client signal store.
- `execute_script/3` — `:auto_remove` option — when `true`, adds
  `data-effect="el.remove()"` to the injected `<script>` tag so Datastar
  removes it from the DOM after execution.
- All SSE-emitting functions now accept `:event_id` and `:retry_duration`
  keyword options, emitting the standard SSE `id:` and `retry:` fields
  respectively.

### Changed

- Valid merge modes for `patch_fragment/3` are now `"outer"`, `"inner"`,
  `"replace"`, `"prepend"`, `"append"`, `"before"`, `"after"`, and `"remove"`.
  The previously advertised `"morph"` mode has been removed to align with the
  Datastar RC.8+ protocol, which uses `"outer"` as the default morph behaviour.

### Fixed

- `check_connection/1` now rescues `ArgumentError` (raised by `Plug.Conn.chunk/2`
  on non-chunked connections) and returns `{:error, conn}` instead of crashing.

## [0.1.0] - 2026-03-14

### Added

- `Datastar.init_sse/1` — Initialises a chunked `text/event-stream` response
  with the required SSE headers (`cache-control`, `connection`, `x-accel-buffering`).
- `Datastar.patch_fragment/3` — Sends a `datastar-patch-elements` SSE event to
  patch HTML into the DOM. Supports all Datastar merge modes (`morph`, `inner`,
  `outer`, `prepend`, `append`, `before`, `after`, `remove`) and an optional
  CSS selector. Multi-line HTML is split into one `data: elements` line per
  source line as required by the SSE protocol.
- `Datastar.patch_signals/2` — Sends a `datastar-patch-signals` SSE event to
  merge a map of values into the Datastar client signal store. Values are
  JSON-encoded via `Jason`.
- `Datastar.execute_script/2` — Executes a JavaScript snippet on the client by
  appending a `<script>` tag to the document `<body>` via a
  `datastar-patch-elements` event.
- `Datastar.redirect_to/2` — Redirects the browser to a URL using a
  `setTimeout`-wrapped `window.location.href` assignment. The URL is
  JSON-encoded to prevent injection.
- `Datastar.remove_fragment/2` — Removes DOM elements matching a CSS selector
  by sending a `datastar-patch-elements` event with `mode: remove`.
- `Datastar.close_sse/1` — No-op pipeline terminator that documents intent
  (the SSE response body is complete).
- `Datastar.parse_signals/1` — Decodes Datastar signals from controller params
  for both GET requests (signals as a JSON string in `?datastar=`) and
  POST/PUT/PATCH/DELETE requests (signals as the decoded JSON body). Returns
  `%{}` on parse failure so callers always receive a map.

[Unreleased]: https://github.com/rskinnerc/datastar_plug/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/rskinnerc/datastar_plug/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/rskinnerc/datastar_plug/releases/tag/v0.1.0
