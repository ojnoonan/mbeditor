# Rails Log Viewer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a read-only, real-time viewer for the active environment's Rails log file (`log/<env>.log`) inside the mbeditor browser editor.

**Architecture:** A pure-Ruby `LogTailService` does offset-based incremental reads of the log file (handling rotation/truncation). It is consumed by both an HTTP endpoint (`LogsController#tail`, used for initial load + polling fallback) and `EditorChannel`, which pushes new lines to each subscriber via ActionCable's `periodically` timer. The frontend has a `LogService` transport (WebSocket primary, HTTP-poll fallback) feeding a bottom-drawer `LogPanel` component.

**Tech Stack:** Rails engine (Ruby 3.x), ActionCable, Minitest; plain JS + React (no JS build step, no JS unit-test framework — JS verified via the preview server and a Capybara system test).

**Spec:** `docs/superpowers/specs/2026-06-16-rails-log-viewer-design.md`

**Conventions to follow:**
- Backend is TDD: write the Minitest test, watch it fail, implement, watch it pass, commit.
- Frontend JS has no unit-test harness; verify each JS task against the running preview server (port 3789, `bundle exec rails server` from `test/dummy` per `.claude/launch.json`), then a final system test covers it end-to-end.
- Run the full suite with `bundle exec rake test` (rbenv Ruby 3.4.5; ensure `~/.rbenv/shims` is on PATH).
- Commit after every task.

**Deviation from spec (intentional):** The service is constructed with an explicit **log file path** (not `workspace_root` + `resolve_path`). The log path is fixed and server-controlled (`Rails.root.join('log', "#{Rails.env}.log")`) with zero user input, so path-traversal protection is irrelevant; an injectable path also makes the service trivially testable with a temp file. The controller lives in a dedicated `LogsController` as the spec states.

---

## File Structure

**Create:**
- `app/services/mbeditor/log_tail_service.rb` — offset-based incremental log reader.
- `app/controllers/mbeditor/logs_controller.rb` — `GET /logs/tail` JSON endpoint.
- `app/assets/javascripts/mbeditor/log_service.js` — client transport (WS + HTTP fallback, offset/buffer management, ANSI strip).
- `app/assets/javascripts/mbeditor/components/LogPanel.js` — bottom-drawer UI.
- `test/services/mbeditor/log_tail_service_test.rb`
- `test/controllers/mbeditor/logs_controller_test.rb`
- `test/channels/mbeditor/editor_channel_test.rb` — first EditorChannel coverage.
- `test/system/mbeditor/log_viewer_test.rb`

**Modify:**
- `lib/mbeditor/route_map.rb` — add the `logs/tail` route.
- `app/channels/mbeditor/editor_channel.rb` — `start_log_tail`/`stop_log_tail` actions + `periodically` push.
- `app/assets/javascripts/mbeditor/websocket_service.js` — receive `type: 'log'` messages, expose `onLogLines`/`offLogLines`.
- `app/assets/javascripts/mbeditor/application.js` — `//= require` the two new JS files.
- `app/assets/javascripts/mbeditor/components/MbeditorApp.js` — panel state, toggle, status-bar button, render, keyboard shortcut.
- `app/assets/javascripts/mbeditor/components/ShortcutHelp.js` — add a shortcut row.
- `app/assets/stylesheets/mbeditor/editor.css` — drawer styles.
- `CHANGELOG.md` and `CONTEXT.md` — document the feature and the raw-logs caveat.

---

## Task 1: LogTailService — incremental reader

**Files:**
- Create: `app/services/mbeditor/log_tail_service.rb`
- Test: `test/services/mbeditor/log_tail_service_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/services/mbeditor/log_tail_service_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"
require "tmpdir"

module Mbeditor
  class LogTailServiceTest < ActiveSupport::TestCase
    test "returns empty result when the log file does not exist" do
      Dir.mktmpdir do |dir|
        svc = LogTailService.new(File.join(dir, "missing.log"))
        result = svc.read_since(0)
        assert_equal [], result[:lines]
        assert_equal 0, result[:offset]
        assert_equal false, result[:reset]
      end
    end

    test "initial load (nil offset) returns existing complete lines and reset: true" do
      with_log("a\nb\nc\n") do |svc, _path|
        result = svc.read_since(nil)
        assert_equal %w[a b c], result[:lines]
        assert_equal 6, result[:offset]
        assert_equal true, result[:reset]
      end
    end

    test "read_since advances offset and only returns newly appended complete lines" do
      with_log("a\nb\n") do |svc, path|
        first = svc.read_since(nil)
        File.open(path, "a") { |f| f.write("c\nd\n") }
        second = svc.read_since(first[:offset])
        assert_equal %w[c d], second[:lines]
        assert_equal 8, second[:offset]
        assert_equal false, second[:reset]
      end
    end

    test "never emits a partial trailing line; it is delivered once the newline arrives" do
      with_log("a\n", offset_after: true) do |svc, path|
        File.open(path, "a") { |f| f.write("partial") }
        mid = svc.read_since(2)
        assert_equal [], mid[:lines]
        assert_equal 2, mid[:offset], "offset must not advance past an incomplete line"

        File.open(path, "a") { |f| f.write("-done\n") }
        done = svc.read_since(mid[:offset])
        assert_equal ["partial-done"], done[:lines]
      end
    end

    test "detects truncation/rotation: offset past EOF resets to start" do
      with_log("old long content\n") do |svc, path|
        File.write(path, "new\n") # shrinks file below the previous offset
        result = svc.read_since(50)
        assert_equal %w[new], result[:lines]
        assert_equal 4, result[:offset]
        assert_equal true, result[:reset]
      end
    end

    test "caps bytes per read so a huge append is delivered across calls" do
      with_log("") do |svc, path|
        big = (["x" * 99] * 4000).join("\n") + "\n" # ~400 KB, > BYTE_CAP
        File.write(path, big)
        first = svc.read_since(0)
        assert first[:offset] < big.bytesize, "should not consume the whole file at once"
        assert first[:lines].length.positive?
        second = svc.read_since(first[:offset])
        assert second[:lines].length.positive?
      end
    end

    private

    def with_log(content, offset_after: false)
      Dir.mktmpdir do |dir|
        path = File.join(dir, "development.log")
        File.write(path, content)
        yield LogTailService.new(path), path
      end
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec rake test TEST=test/services/mbeditor/log_tail_service_test.rb`
Expected: FAIL — `NameError: uninitialized constant Mbeditor::LogTailService`.

- [ ] **Step 3: Implement the service**

Create `app/services/mbeditor/log_tail_service.rb`:

```ruby
# frozen_string_literal: true

require "pathname"

module Mbeditor
  # Reads a log file incrementally from a byte offset. Pure Ruby, no subprocess.
  #
  # read_since(offset) -> { lines: Array<String>, offset: Integer, reset: Boolean }
  #   offset == nil  -> initial load: last INITIAL_TAIL_BYTES, reset: true
  #   offset >  size -> file rotated/truncated: re-read from 0, reset: true
  #   else           -> read new bytes from offset, capped at BYTE_CAP
  #
  # Only complete lines (terminated by "\n") are ever returned; the byte offset
  # advances solely past consumed complete lines, so a partial trailing line is
  # held back and delivered once its newline arrives.
  class LogTailService
    BYTE_CAP           = 256 * 1024
    INITIAL_TAIL_BYTES = 64 * 1024

    def initialize(log_path)
      @log_path = Pathname.new(log_path.to_s)
    end

    def read_since(offset)
      return empty(0) unless @log_path.exist?

      size = @log_path.size
      if offset.nil?
        start = [size - INITIAL_TAIL_BYTES, 0].max
        read_range(start, size, reset: true, trim_leading: start.positive?)
      elsif offset.to_i > size
        read_range(0, [size, BYTE_CAP].min, reset: true, trim_leading: false)
      else
        start = offset.to_i
        read_range(start, [start + BYTE_CAP, size].min, reset: false, trim_leading: false)
      end
    end

    private

    def empty(offset, reset: false)
      { lines: [], offset: offset, reset: reset }
    end

    def read_range(start, stop, reset:, trim_leading:)
      return empty(start, reset: reset) if stop <= start

      chunk = File.open(@log_path, "rb") do |f|
        f.seek(start)
        f.read(stop - start) || ""
      end

      last_nl = chunk.rindex("\n")
      return empty(start, reset: reset) if last_nl.nil? # no complete line yet

      consumed = chunk[0..last_nl]
      lines = consumed.force_encoding("UTF-8").scrub.split("\n")
      lines.shift if trim_leading && !lines.empty? # drop partial first line on initial tail
      { lines: lines, offset: start + consumed.bytesize, reset: reset }
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bundle exec rake test TEST=test/services/mbeditor/log_tail_service_test.rb`
Expected: PASS (6 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add app/services/mbeditor/log_tail_service.rb test/services/mbeditor/log_tail_service_test.rb
git commit -m "feat: add LogTailService for incremental log reads"
```

---

## Task 2: LogsController + route

**Files:**
- Create: `app/controllers/mbeditor/logs_controller.rb`
- Modify: `lib/mbeditor/route_map.rb`
- Test: `test/controllers/mbeditor/logs_controller_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/controllers/mbeditor/logs_controller_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class LogsControllerTest < ActionDispatch::IntegrationTest
    include Engine.routes.url_helpers

    def log_path
      Rails.root.join("log", "#{Rails.env}.log")
    end

    test "GET /logs/tail returns lines, offset and reset as JSON" do
      File.write(log_path, "alpha\nbravo\n")
      get "/mbeditor/logs/tail"
      assert_response :success
      body = JSON.parse(response.body)
      assert_includes body["lines"], "alpha"
      assert_includes body["lines"], "bravo"
      assert_equal true, body["reset"]
      assert body["offset"].is_a?(Integer)
    end

    test "GET /logs/tail?offset= only returns lines appended after that offset" do
      File.write(log_path, "one\n")
      first = JSON.parse(get_json("/mbeditor/logs/tail"))
      File.open(log_path, "a") { |f| f.write("two\n") }
      second = JSON.parse(get_json("/mbeditor/logs/tail?offset=#{first['offset']}"))
      assert_equal ["two"], second["lines"]
    end

    private

    def get_json(path)
      get path
      response.body
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec rake test TEST=test/controllers/mbeditor/logs_controller_test.rb`
Expected: FAIL — routing error (no route matches `/mbeditor/logs/tail`).

- [ ] **Step 3: Add the route**

Edit `lib/mbeditor/route_map.rb`. After the line `post 'test', to: 'editors#run_test'` add:

```ruby
    get    'logs/tail',       to: 'logs#tail'
```

- [ ] **Step 4: Implement the controller**

Create `app/controllers/mbeditor/logs_controller.rb`:

```ruby
# frozen_string_literal: true

module Mbeditor
  class LogsController < ApplicationController
    # GET /logs/tail[?offset=N]
    # Reads the active environment's log file incrementally. Used for the
    # initial load (no offset) and as the HTTP polling fallback (with offset).
    def tail
      offset = params[:offset].present? ? params[:offset].to_i : nil
      result = LogTailService.new(log_path).read_since(offset)
      render json: result
    end

    private

    def log_path
      Rails.root.join("log", "#{Rails.env}.log")
    end
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bundle exec rake test TEST=test/controllers/mbeditor/logs_controller_test.rb`
Expected: PASS (2 runs, 0 failures).

- [ ] **Step 6: Commit**

```bash
git add app/controllers/mbeditor/logs_controller.rb lib/mbeditor/route_map.rb test/controllers/mbeditor/logs_controller_test.rb
git commit -m "feat: add GET /logs/tail endpoint"
```

---

## Task 3: EditorChannel push via periodically

**Files:**
- Modify: `app/channels/mbeditor/editor_channel.rb`
- Test: `test/channels/mbeditor/editor_channel_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/channels/mbeditor/editor_channel_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class EditorChannelTest < ActionCable::Channel::TestCase
    tests Mbeditor::EditorChannel

    test "subscribes and streams from the editor channel" do
      subscribe
      assert subscription.confirmed?
      assert_has_stream "mbeditor_editor"
    end

    test "push_log_lines transmits new lines only while watching" do
      subscribe
      fake = Object.new
      def fake.read_since(_offset)
        { lines: ["GET /things 200 OK"], offset: 42, reset: false }
      end

      Mbeditor::LogTailService.stub(:new, fake) do
        # Not watching yet -> nothing transmitted.
        subscription.send(:push_log_lines)
        assert_empty transmissions

        subscription.start_log_tail("offset" => 0)
        subscription.send(:push_log_lines)
      end

      msg = transmissions.last
      assert_equal "log", msg["type"]
      assert_equal ["GET /things 200 OK"], msg["lines"]
      assert_equal 42, msg["offset"]

      subscription.stop_log_tail
      assert_equal false, subscription.instance_variable_get(:@log_watching)
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec rake test TEST=test/channels/mbeditor/editor_channel_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'start_log_tail'`.

- [ ] **Step 3: Implement the channel changes**

Edit `app/channels/mbeditor/editor_channel.rb`. Add the two public actions after `save_branch_state` (before `private`):

```ruby
    def start_log_tail(data)
      raw = data && data["offset"]
      @log_offset = raw.nil? ? nil : raw.to_i
      @log_watching = true
    end

    def stop_log_tail(_data = nil)
      @log_watching = false
    end
```

Immediately after the class's `def subscribed ... end` (still in the class body) add the periodic declaration, guarded so it is a no-op when ActionCable is unavailable (the `Object` fallback base):

```ruby
    # Push newly appended log lines to this subscriber ~once a second while the
    # client has the log panel open. Guarded so the class still loads when
    # ActionCable is absent (CableBaseClass == Object).
    periodically :push_log_lines, every: 1 if respond_to?(:periodically)
```

Add the private push method and log path inside the existing `private` section:

```ruby
    def push_log_lines
      return unless @log_watching

      result = LogTailService.new(log_path).read_since(@log_offset)
      @log_offset = result[:offset]
      return if result[:lines].empty? && !result[:reset]

      transmit(type: "log", lines: result[:lines], offset: result[:offset], reset: result[:reset])
    rescue StandardError
      # Never let a log-tail failure crash the WebSocket connection.
    end

    def log_path
      Rails.root.join("log", "#{Rails.env}.log")
    end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bundle exec rake test TEST=test/channels/mbeditor/editor_channel_test.rb`
Expected: PASS (2 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add app/channels/mbeditor/editor_channel.rb test/channels/mbeditor/editor_channel_test.rb
git commit -m "feat: stream log lines over EditorChannel"
```

---

## Task 4: websocket_service — receive log messages

**Files:**
- Modify: `app/assets/javascripts/mbeditor/websocket_service.js`

No JS unit harness — verified indirectly by Task 7's manual check and Task 9's system test. This task is mechanical wiring; verify by loading the preview and confirming no console errors.

- [ ] **Step 1: Add a log-line callback registry and dispatch**

In `app/assets/javascripts/mbeditor/websocket_service.js`, find the private state near `_filesChangedCallbacks` and add a parallel array. Then extend the `received` handler (currently lines ~115-119) and the emit helper.

Replace:

```javascript
          received: function (data) {
            if (data && data.type === 'files_changed') {
              _emitFilesChanged(data);
            }
          }
```

with:

```javascript
          received: function (data) {
            if (!data) return;
            if (data.type === 'files_changed') {
              _emitFilesChanged(data);
            } else if (data.type === 'log') {
              _emitLogLines(data);
            }
          }
```

After the `_emitFilesChanged` function add:

```javascript
  function _emitLogLines(data) {
    _logLinesCallbacks.forEach(function (fn) {
      try { fn(data); } catch (e) { /* ignore */ }
    });
  }
```

Near the declaration of `_filesChangedCallbacks` add:

```javascript
  var _logLinesCallbacks = [];
```

- [ ] **Step 2: Expose subscribe/unsubscribe in the public API**

After `offFilesChanged` add:

```javascript
  // Register a callback invoked when the server transmits a { type: 'log' } message.
  function onLogLines(fn) {
    _logLinesCallbacks.push(fn);
  }

  function offLogLines(fn) {
    _logLinesCallbacks = _logLinesCallbacks.filter(function (f) { return f !== fn; });
  }
```

And add them to the returned object:

```javascript
  return {
    connect: connect,
    disconnect: disconnect,
    isConnected: isConnected,
    perform: perform,
    onFilesChanged: onFilesChanged,
    offFilesChanged: offFilesChanged,
    onLogLines: onLogLines,
    offLogLines: offLogLines
  };
```

- [ ] **Step 3: Verify no load errors**

Ensure preview running (`preview_start` "Dummy App (Rails)"), reload `/mbeditor`, then check `preview_console_logs level: error`.
Expected: no errors; `WebSocketService.onLogLines` is a function (verify via `preview_eval`: `typeof WebSocketService.onLogLines`).

- [ ] **Step 4: Commit**

```bash
git add app/assets/javascripts/mbeditor/websocket_service.js
git commit -m "feat: receive log-tail messages in websocket_service"
```

---

## Task 5: log_service.js — client transport

**Files:**
- Create: `app/assets/javascripts/mbeditor/log_service.js`
- Modify: `app/assets/javascripts/mbeditor/application.js`

- [ ] **Step 1: Create the service**

Create `app/assets/javascripts/mbeditor/log_service.js`:

```javascript
'use strict';

// LogService — streams the Rails log into a bounded in-memory buffer.
// Primary transport: WebSocket (EditorChannel `start_log_tail`). Fallback:
// HTTP polling of GET /logs/tail. ANSI escape codes are stripped for v1.
var LogService = (function () {
  var MAX_LINES     = 2000;          // bounded buffer to keep the DOM light
  var POLL_INTERVAL = 1500;          // ms, HTTP fallback cadence
  var ANSI_RE       = /\x1b\[[0-9;]*m/g;

  var _lines      = [];
  var _offset     = null;            // null => initial load
  var _active     = false;
  var _pollTimer  = null;
  var _usingWs    = false;
  var _subscribers = [];

  function _strip(line) { return line.replace(ANSI_RE, ''); }

  function _basePath() { return window.mbeditorBasePath(); }

  function _apply(data) {
    if (!data) return;
    if (data.reset) _lines = [];
    if (typeof data.offset === 'number') _offset = data.offset;
    if (data.lines && data.lines.length) {
      for (var i = 0; i < data.lines.length; i++) _lines.push(_strip(data.lines[i]));
      if (_lines.length > MAX_LINES) _lines = _lines.slice(_lines.length - MAX_LINES);
    }
    _notify();
  }

  function _notify() {
    _subscribers.forEach(function (fn) {
      try { fn(_lines); } catch (e) { /* ignore */ }
    });
  }

  function _fetchOnce() {
    var url = _basePath() + '/logs/tail';
    if (_offset !== null) url += '?offset=' + _offset;
    return axios.get(url)
      .then(function (res) { _apply(res.data); })
      .catch(function () { /* transient; next tick retries */ });
  }

  function _startPolling() {
    _usingWs = false;
    _fetchOnce();
    _pollTimer = setInterval(function () { if (_active) _fetchOnce(); }, POLL_INTERVAL);
  }

  function _onWsLog(data) { if (_active) _apply(data); }

  // Begin streaming. Loads initial tail over HTTP, then prefers WS push.
  function start() {
    if (_active) return;
    _active = true;
    _offset = null;
    _lines = [];
    _fetchOnce().then(function () {
      if (window.WebSocketService && WebSocketService.isConnected()) {
        _usingWs = true;
        WebSocketService.onLogLines(_onWsLog);
        WebSocketService.perform('start_log_tail', { offset: _offset });
      } else {
        _startPolling();
      }
    });
  }

  function stop() {
    if (!_active) return;
    _active = false;
    if (_usingWs && window.WebSocketService) {
      WebSocketService.perform('stop_log_tail', {});
      WebSocketService.offLogLines(_onWsLog);
    }
    if (_pollTimer) { clearInterval(_pollTimer); _pollTimer = null; }
  }

  function clear() { _lines = []; _notify(); }

  function getLines() { return _lines; }

  // Subscribe to buffer updates; returns an unsubscribe function.
  function subscribe(fn) {
    _subscribers.push(fn);
    return function () {
      _subscribers = _subscribers.filter(function (f) { return f !== fn; });
    };
  }

  return {
    start: start,
    stop: stop,
    clear: clear,
    getLines: getLines,
    subscribe: subscribe
  };
})();

window.LogService = LogService;
```

- [ ] **Step 2: Register it in the asset manifest**

Edit `app/assets/javascripts/mbeditor/application.js`. After `//= require mbeditor/git_service` add:

```javascript
//= require mbeditor/log_service
```

- [ ] **Step 3: Verify it loads**

Reload `/mbeditor` in the preview; `preview_eval`: `typeof window.LogService.start` → expect `"function"`. `preview_console_logs level: error` → no errors.

- [ ] **Step 4: Commit**

```bash
git add app/assets/javascripts/mbeditor/log_service.js app/assets/javascripts/mbeditor/application.js
git commit -m "feat: add LogService client transport"
```

---

## Task 6: LogPanel.js — bottom drawer UI

**Files:**
- Create: `app/assets/javascripts/mbeditor/components/LogPanel.js`
- Modify: `app/assets/javascripts/mbeditor/application.js`
- Modify: `app/assets/stylesheets/mbeditor/editor.css`

- [ ] **Step 1: Create the component**

Create `app/assets/javascripts/mbeditor/components/LogPanel.js`:

```javascript
'use strict';

// LogPanel — bottom drawer that renders the live Rails log. Auto-scrolls to the
// tail, pauses auto-scroll when the user scrolls up, and supports a substring
// filter and clear. Driven entirely by LogService.
var LogPanel = function LogPanel(_ref) {
  var onClose = _ref.onClose;

  var _lines = React.useState([]);
  var lines = _lines[0], setLines = _lines[1];
  var _filter = React.useState('');
  var filter = _filter[0], setFilter = _filter[1];
  var _autoScroll = React.useState(true);
  var autoScroll = _autoScroll[0], setAutoScroll = _autoScroll[1];

  var bodyRef = React.useRef(null);

  React.useEffect(function () {
    LogService.start();
    var unsub = LogService.subscribe(function (next) {
      // copy so React sees a new array reference
      setLines(next.slice());
    });
    setLines(LogService.getLines().slice());
    return function () {
      unsub();
      LogService.stop();
    };
  }, []);

  React.useEffect(function () {
    if (autoScroll && bodyRef.current) {
      bodyRef.current.scrollTop = bodyRef.current.scrollHeight;
    }
  }, [lines, autoScroll]);

  var onScroll = function onScroll() {
    var el = bodyRef.current;
    if (!el) return;
    var atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 24;
    setAutoScroll(atBottom);
  };

  var shown = filter
    ? lines.filter(function (l) { return l.toLowerCase().indexOf(filter.toLowerCase()) !== -1; })
    : lines;

  return React.createElement(
    'div',
    { className: 'ide-log-drawer' },
    React.createElement(
      'div',
      { className: 'ide-log-header' },
      React.createElement('i', { className: 'fas fa-stream' }),
      React.createElement('span', { className: 'ide-log-title' }, 'Rails log'),
      React.createElement('input', {
        className: 'ide-log-filter',
        type: 'text',
        placeholder: 'Filter…',
        value: filter,
        onChange: function (e) { setFilter(e.target.value); }
      }),
      !autoScroll && React.createElement('span', { className: 'ide-log-paused' }, 'paused'),
      React.createElement('button', {
        type: 'button', className: 'ide-log-btn',
        title: 'Clear', onClick: function () { LogService.clear(); }
      }, React.createElement('i', { className: 'fas fa-ban' })),
      React.createElement('button', {
        type: 'button', className: 'ide-log-btn',
        title: 'Close', onClick: onClose
      }, React.createElement('i', { className: 'fas fa-times' }))
    ),
    React.createElement(
      'div',
      { className: 'ide-log-body', ref: bodyRef, onScroll: onScroll },
      shown.map(function (line, i) {
        return React.createElement('div', { className: 'ide-log-line', key: i }, line);
      })
    )
  );
};

window.LogPanel = LogPanel;
```

- [ ] **Step 2: Register in the manifest**

Edit `app/assets/javascripts/mbeditor/application.js`. After `//= require mbeditor/components/TestResultsPanel` add:

```javascript
//= require mbeditor/components/LogPanel
```

- [ ] **Step 3: Add drawer styles**

Append to `app/assets/stylesheets/mbeditor/editor.css`:

```css
/* ── Rails log drawer ─────────────────────────────────────────────────────── */
.ide-log-drawer {
  position: absolute;
  left: 0;
  right: 0;
  bottom: 22px; /* sit above the status bar */
  height: 240px;
  display: flex;
  flex-direction: column;
  background: var(--ide-panel-bg, #1e1e1e);
  border-top: 1px solid var(--ide-border, #333);
  z-index: 40;
}
.ide-log-header {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 4px 10px;
  border-bottom: 1px solid var(--ide-border, #333);
  font-size: 12px;
  color: var(--ide-fg-muted, #ccc);
}
.ide-log-title { font-weight: 600; }
.ide-log-filter {
  margin-left: auto;
  background: var(--ide-input-bg, #2d2d2d);
  color: var(--ide-fg, #eee);
  border: 1px solid var(--ide-border, #333);
  border-radius: 3px;
  padding: 2px 6px;
  font-size: 12px;
  width: 180px;
}
.ide-log-paused { color: #cca700; font-size: 11px; }
.ide-log-btn {
  background: transparent;
  border: none;
  color: var(--ide-fg-muted, #ccc);
  cursor: pointer;
  padding: 2px 6px;
}
.ide-log-btn:hover { color: var(--ide-fg, #fff); }
.ide-log-body {
  flex: 1;
  overflow: auto;
  padding: 6px 10px;
  font-family: var(--ide-mono, monospace);
  font-size: 12px;
  line-height: 1.4;
  white-space: pre-wrap;
  word-break: break-word;
}
.ide-log-line { color: var(--ide-fg, #d4d4d4); }
```

- [ ] **Step 4: Verify it loads (rendered in Task 7)**

Reload preview; `preview_eval`: `typeof window.LogPanel` → expect `"function"`. `preview_console_logs level: error` → none. (Visual verification happens in Task 7 once it is wired into MbeditorApp.)

- [ ] **Step 5: Commit**

```bash
git add app/assets/javascripts/mbeditor/components/LogPanel.js app/assets/javascripts/mbeditor/application.js app/assets/stylesheets/mbeditor/editor.css
git commit -m "feat: add LogPanel bottom-drawer component"
```

---

## Task 7: Wire the panel into MbeditorApp + shortcut + help

**Files:**
- Modify: `app/assets/javascripts/mbeditor/components/MbeditorApp.js`
- Modify: `app/assets/javascripts/mbeditor/components/ShortcutHelp.js`

MbeditorApp.js is large; mirror the existing `showGitPanel` wiring exactly (state field, ref, toggle, status-bar button, conditional render, keyboard shortcut). Use the line anchors below as reference points — match the surrounding code, do not assume exact line numbers.

- [ ] **Step 1: Add panel visibility state**

Near the `showGitPanel` `useState` block (around line 421), add an analogous block:

```javascript
  var _useStateLog = useState(false);
  var _useStateLog2 = _slicedToArray(_useStateLog, 2);
  var showLogPanel = _useStateLog2[0];
  var setShowLogPanel = _useStateLog2[1];
```

- [ ] **Step 2: Add the toggle function**

Near `toggleGitPanel` (around line 2531) add:

```javascript
  var toggleLogPanel = function toggleLogPanel() {
    setShowLogPanel(function (prev) { return !prev; });
  };
```

- [ ] **Step 3: Add a status-bar button**

Next to the Git status-bar button (around line 3223) add:

```javascript
  React.createElement(
    "button",
    { type: "button", className: "statusbar-btn", onClick: toggleLogPanel, title: "Toggle Rails log (Ctrl+Shift+L)" },
    React.createElement("i", { className: "fas fa-stream" }),
    !editorPrefs.toolbarIconOnly && " Logs"
  ),
```

- [ ] **Step 4: Render the panel**

Near where `GitPanel` is conditionally rendered (around line 4708) add:

```javascript
  showLogPanel && !zenMode && React.createElement(window.LogPanel || LogPanel, {
    onClose: function () { setShowLogPanel(false); }
  }),
```

- [ ] **Step 5: Add the keyboard shortcut**

In the `onKeyDown` hotkeys handler (the same one that handles Ctrl+P / Ctrl+S, around line 1076), add after the existing bindings:

```javascript
      if ((e.ctrlKey || e.metaKey) && e.shiftKey && (e.key === 'L' || e.key === 'l')) {
        e.preventDefault();
        setShowLogPanel(function (prev) { return !prev; });
      }
```

- [ ] **Step 6: Add a ShortcutHelp row**

In `app/assets/javascripts/mbeditor/components/ShortcutHelp.js`, beside the other rows (around line 104) add:

```javascript
                  React.createElement(Row, { keys: 'Ctrl+Shift+L', desc: 'Toggle Rails log panel' }),
```

- [ ] **Step 7: Verify in the preview**

1. Reload `/mbeditor`.
2. `preview_console_logs level: error` → none.
3. `preview_click` the new **Logs** status-bar button (selector: `button.statusbar-btn[title^="Toggle Rails log"]`).
4. `preview_eval` to append a line to the dummy log so there is content to show:
   `(async()=>{ await fetch('/mbeditor/ping'); return true; })()` (a request writes to the dev log).
5. `preview_snapshot` → confirm the drawer (`.ide-log-drawer`) is present with log lines.
6. `preview_screenshot` → capture the open drawer as proof.

- [ ] **Step 8: Commit**

```bash
git add app/assets/javascripts/mbeditor/components/MbeditorApp.js app/assets/javascripts/mbeditor/components/ShortcutHelp.js
git commit -m "feat: wire log panel toggle, shortcut and help into the editor"
```

---

## Task 8: System test (end-to-end)

**Files:**
- Create: `test/system/mbeditor/log_viewer_test.rb`

- [ ] **Step 1: Write the system test**

Mirror the structure of the existing `test/system/mbeditor/slow_server_test.rb` for setup/driver. Create `test/system/mbeditor/log_viewer_test.rb`:

```ruby
# frozen_string_literal: true

require "application_system_test_case"

module Mbeditor
  class LogViewerTest < ApplicationSystemTestCase
    test "opening the log panel shows freshly logged lines" do
      marker = "LOGVIEWER-MARKER-#{SecureRandom.hex(4)}"
      Rails.logger.info(marker)
      Rails.logger.flush if Rails.logger.respond_to?(:flush)

      visit "/mbeditor"
      assert_selector ".statusbar-btn", wait: 10

      find(".statusbar-btn[title^='Toggle Rails log']").click
      assert_selector ".ide-log-drawer", wait: 5
      assert_text marker, wait: 5
    end
  end
end
```

> Note: if `application_system_test_case.rb` does not exist in `test/`, check how `slow_server_test.rb` requires its base class and match that exactly (it may use a custom helper). Adjust the `require` line accordingly.

- [ ] **Step 2: Run the system test**

Run: `bundle exec rake test:system TEST=test/system/mbeditor/log_viewer_test.rb`
Expected: PASS. If the headless driver isn't configured for `rake test:system`, run it the same way `slow_server_test.rb` is run (check its top-of-file comments / the CI config).

- [ ] **Step 3: Commit**

```bash
git add test/system/mbeditor/log_viewer_test.rb
git commit -m "test: system test for the Rails log viewer"
```

---

## Task 9: Documentation

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `CONTEXT.md`

- [ ] **Step 1: Add a CHANGELOG entry**

Under the unreleased / next-version section of `CHANGELOG.md`, add:

```markdown
### Added
- **Rails log viewer** — a bottom-drawer panel (toggle via the status bar or
  `Ctrl+Shift+L`) that streams the active environment's `log/<env>.log` in real
  time over ActionCable, with HTTP polling fallback. Read-only.

### Security
- The log viewer displays log contents **verbatim**, which may include request
  params, tokens or SQL values. It is read-only and gated by the host app's
  auth like every other editor route, but operators should be aware logs can
  contain secrets.
```

- [ ] **Step 2: Add a CONTEXT.md note**

Add a short subsection to `CONTEXT.md` describing the log viewer: that it tails `log/<env>.log` via `LogTailService` (offset-based, rotation-aware), is served by `LogsController#tail` (HTTP) and `EditorChannel` (`start_log_tail`/`stop_log_tail` + `periodically` push), and renders raw logs (no redaction) by design.

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md CONTEXT.md
git commit -m "docs: document the Rails log viewer"
```

---

## Final verification

- [ ] Run the full suite: `bundle exec rake test` — expect all green (was 495 tests; this adds LogTailService, LogsController, and EditorChannel tests).
- [ ] Confirm the Ctrl+P print fix (already in the working tree) is committed or intentionally pending.
- [ ] Manual preview pass: open the editor, toggle the log drawer, trigger a request, confirm lines stream and auto-scroll; scroll up to confirm pause; type in the filter; clear.
```
