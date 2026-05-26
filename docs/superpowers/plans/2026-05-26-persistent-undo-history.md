# Persistent Undo History Per Branch — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist Monaco editor undo history per file per branch on the server so reloading the page (or switching VMs) restores full Ctrl+Z history back to the first edit on that branch.

**Architecture:** On every content change, compact edit ops (`[sl,sc,el,ec,text]`) are buffered in `HistoryService` and flushed to a new server endpoint on meaningful events (save, tab close, visibility, unload). On file open, history is fetched and replayed on a detached Monaco model, then the model is swapped in transparently after Phase 1 already shows the file.

**Tech Stack:** Plain JS (no build step), Ruby/Rails engine, file-based JSON storage in `tmp/mbeditor_history/`, Minitest for controller tests.

**Note on log silencing:** The existing `Mbeditor::Rack::SilencePingRequest` middleware already silences all `/mbeditor/` traffic — no new middleware is needed.

---

## File Map

| File | Action |
|------|--------|
| `config/routes.rb` | Add 2 routes |
| `app/controllers/mbeditor/editors_controller.rb` | Add `file_history`, `save_file_history` actions; extend `prune_branch_states`; add `history_file_path`, `compact_history_ops` private helpers |
| `test/controllers/mbeditor/editors_controller_test.rb` | Add controller tests |
| `app/assets/javascripts/mbeditor/history_service.js` | New file — all client capture/flush/fetch logic |
| `app/assets/javascripts/mbeditor/components/EditorPanel.js` | Wire `onDidChangeContent` → HistoryService; add Phase 2 two-phase load |
| `app/assets/javascripts/mbeditor/tab_manager.js` | Flush on `closeTab` |
| `app/assets/javascripts/mbeditor/components/MbeditorApp.js` | Flush on save; wire `visibilitychange` and `beforeunload` |
| `app/assets/javascripts/mbeditor/application.js` (or equivalent manifest) | Include `history_service` |

---

## Task 1: Backend — Routes + GET `file_history`

**Files:**
- Modify: `config/routes.rb`
- Modify: `app/controllers/mbeditor/editors_controller.rb`
- Test: `test/controllers/mbeditor/editors_controller_test.rb`

- [ ] **Step 1.1: Write failing tests**

Add to `editors_controller_test.rb` after the `prune_branch_states` test block:

```ruby
# ---------------------------------------------------------------------------
# file_history
# ---------------------------------------------------------------------------

test "file_history returns empty hash when no history exists" do
  get "/mbeditor/file_history", params: { branch: "main", path: "app/models/user.rb" }
  assert_response :ok
  assert_equal({}, json)
end

test "file_history returns 400 for invalid branch name" do
  get "/mbeditor/file_history", params: { branch: "../../etc", path: "app/models/user.rb" }
  assert_response :bad_request
end

test "file_history returns 403 for path outside workspace" do
  get "/mbeditor/file_history", params: { branch: "main", path: "/etc/passwd" }
  assert_response :forbidden
end

test "file_history returns base and ops after save" do
  post "/mbeditor/file_history", params: {
    branch: "main",
    path: "app/models/user.rb",
    ops: [[1,1,1,1,"hello"]],
    base: "class User; end\n"
  }, as: :json
  assert_response :no_content

  get "/mbeditor/file_history", params: { branch: "main", path: "app/models/user.rb" }
  assert_response :ok
  assert_equal "class User; end\n", json["base"]
  assert_equal [[1,1,1,1,"hello"]], json["ops"]
end

test "file_history prunes and returns empty when history is older than 7 days" do
  hist_dir = File.join(@workspace, "tmp", "mbeditor_history")
  FileUtils.mkdir_p(hist_dir)
  branch_hash = Digest::SHA256.hexdigest("main")[0,16]
  file_hash   = Digest::SHA256.hexdigest("app/models/user.rb")[0,16]
  hist_file   = File.join(hist_dir, "#{branch_hash}_#{file_hash}.json")
  File.write(hist_file, {
    branch: "main", path: "app/models/user.rb",
    base: "x", ops: [], t: (Time.now.utc - 8 * 24 * 3600).iso8601
  }.to_json)

  get "/mbeditor/file_history", params: { branch: "main", path: "app/models/user.rb" }
  assert_response :ok
  assert_equal({}, json)
  assert_not File.exist?(hist_file), "history file should be pruned"
end

test "file_history returns empty and deletes corrupted history file" do
  hist_dir = File.join(@workspace, "tmp", "mbeditor_history")
  FileUtils.mkdir_p(hist_dir)
  branch_hash = Digest::SHA256.hexdigest("main")[0,16]
  file_hash   = Digest::SHA256.hexdigest("app/models/user.rb")[0,16]
  hist_file   = File.join(hist_dir, "#{branch_hash}_#{file_hash}.json")
  File.write(hist_file, "not json {{{{")

  get "/mbeditor/file_history", params: { branch: "main", path: "app/models/user.rb" }
  assert_response :ok
  assert_equal({}, json)
  assert_not File.exist?(hist_file), "corrupt file should be deleted"
end
```

- [ ] **Step 1.2: Run tests to verify they fail**

```bash
bundle exec rake test TEST=test/controllers/mbeditor/editors_controller_test.rb TESTOPTS="--name=/file_history/"
```

Expected: failures like `ActionController::RoutingError` or `NoMethodError`.

- [ ] **Step 1.3: Add routes**

In `config/routes.rb`, add after line 20 (`post 'prune_branch_states'`):

```ruby
  get  'file_history', to: 'editors#file_history'
  post 'file_history', to: 'editors#save_file_history'
```

- [ ] **Step 1.4: Add `require "digest"` to controller**

In `app/controllers/mbeditor/editors_controller.rb`, add after the existing requires (line 8):

```ruby
require "digest"
```

- [ ] **Step 1.5: Add `HISTORY_MAX_OPS`, `HISTORY_COMPACT_TARGET` constants and `file_history` action**

In `editors_controller.rb`, add after the `SAFE_BRANCH_NAME` constant (line 95):

```ruby
HISTORY_MAX_OPS      = 10_000
HISTORY_COMPACT_TARGET = 5_000
```

Add the `file_history` action after `prune_branch_states` (after line 159):

```ruby
# GET /mbeditor/file_history?branch=X&path=Y
def file_history
  branch = sanitize_branch_name(params[:branch])
  return render json: {}, status: :bad_request unless branch

  path = resolve_path(params[:path])
  return render json: {}, status: :forbidden unless path

  rel  = relative_path(path)
  hist = history_file_path(branch, rel)
  return render json: {} unless File.exist?(hist)

  data = JSON.parse(File.read(hist))

  if data['t']
    age = Time.now.utc - Time.parse(data['t'])
    if age > 7 * 24 * 3600
      FileUtils.rm_f(hist)
      return render json: {}
    end
  end

  render json: { base: data['base'], ops: data['ops'] || [] }
rescue JSON::ParserError
  FileUtils.rm_f(hist) rescue nil
  render json: {}
rescue StandardError
  render json: {}
end
```

- [ ] **Step 1.6: Add private helpers**

In the `private` section of `editors_controller.rb` (before `broadcast_files_changed`), add:

```ruby
def history_file_path(branch, rel_path)
  branch_hash = Digest::SHA256.hexdigest(branch.to_s)[0, 16]
  file_hash   = Digest::SHA256.hexdigest(rel_path.to_s)[0, 16]
  workspace_root.join('tmp', 'mbeditor_history', "#{branch_hash}_#{file_hash}.json")
end

def compact_history_ops(base, ops)
  text = base.to_s
  ops.each do |op|
    sl, sc, el, ec, ins = op[0].to_i, op[1].to_i, op[2].to_i, op[3].to_i, op[4].to_s
    lines = text.split("\n", -1)
    sl0  = [[sl - 1, 0].max, [lines.length - 1, 0].max].min
    el0  = [[el - 1, 0].max, [lines.length - 1, 0].max].min
    sc0  = sc - 1
    ec0  = ec - 1
    prefix    = (lines[sl0] || '')[0, sc0] || ''
    suffix    = (lines[el0] || '')[ec0..] || ''
    ins_lines = ins.split("\n", -1)
    new_seg   = if ins_lines.length <= 1
      [prefix + (ins_lines[0] || '') + suffix]
    else
      [prefix + ins_lines[0]] + ins_lines[1..-2] + [ins_lines[-1] + suffix]
    end
    text = (lines[0...sl0] + new_seg + lines[(el0 + 1)..]).join("\n")
  end
  text
rescue StandardError
  base.to_s
end
```

- [ ] **Step 1.7: Run tests**

```bash
bundle exec rake test TEST=test/controllers/mbeditor/editors_controller_test.rb TESTOPTS="--name=/file_history/"
```

Expected: the GET tests pass; the POST-dependent test (`file_history returns base and ops after save`) still fails.

- [ ] **Step 1.8: Commit**

```bash
git add config/routes.rb app/controllers/mbeditor/editors_controller.rb test/controllers/mbeditor/editors_controller_test.rb
git commit -m "feat: add file_history GET endpoint and private helpers"
```

---

## Task 2: Backend — POST `save_file_history`

**Files:**
- Modify: `app/controllers/mbeditor/editors_controller.rb`
- Test: `test/controllers/mbeditor/editors_controller_test.rb`

- [ ] **Step 2.1: Write failing tests**

Add to `editors_controller_test.rb` (after the GET tests from Task 1):

```ruby
test "save_file_history returns 400 for invalid branch name" do
  post "/mbeditor/file_history", params: {
    branch: "bad name!", path: "app/models/user.rb",
    ops: [], base: "x"
  }, as: :json
  assert_response :bad_request
end

test "save_file_history returns 403 for path outside workspace" do
  post "/mbeditor/file_history", params: {
    branch: "main", path: "/etc/passwd",
    ops: [[1,1,1,1,"x"]], base: "x"
  }, as: :json
  assert_response :forbidden
end

test "save_file_history returns 400 when base is missing on first write" do
  post "/mbeditor/file_history", params: {
    branch: "main", path: "app/models/user.rb",
    ops: [[1,1,1,1,"hello"]]
  }, as: :json
  assert_response :bad_request
end

test "save_file_history appends ops on subsequent writes" do
  post "/mbeditor/file_history", params: {
    branch: "main", path: "app/models/user.rb",
    ops: [[1,1,1,1,"hello"]], base: "class User; end\n"
  }, as: :json
  assert_response :no_content

  post "/mbeditor/file_history", params: {
    branch: "main", path: "app/models/user.rb",
    ops: [[1,6,1,6," world"]]
  }, as: :json
  assert_response :no_content

  get "/mbeditor/file_history", params: { branch: "main", path: "app/models/user.rb" }
  assert_equal 2, json["ops"].length
  assert_equal [1,6,1,6," world"], json["ops"].last
end

test "save_file_history compacts when ops exceed HISTORY_MAX_OPS" do
  base = "line\n"
  first_ops = Array.new(Mbeditor::EditorsController::HISTORY_MAX_OPS) { [1,1,1,1,"x"] }

  post "/mbeditor/file_history", params: {
    branch: "main", path: "app/models/user.rb",
    ops: first_ops, base: base
  }, as: :json
  assert_response :no_content

  post "/mbeditor/file_history", params: {
    branch: "main", path: "app/models/user.rb",
    ops: [[1,1,1,1,"y"]]
  }, as: :json
  assert_response :no_content

  get "/mbeditor/file_history", params: { branch: "main", path: "app/models/user.rb" }
  assert json["ops"].length < Mbeditor::EditorsController::HISTORY_MAX_OPS + 2
end

test "save_file_history returns 204 with empty ops array" do
  post "/mbeditor/file_history", params: {
    branch: "main", path: "app/models/user.rb",
    ops: [], base: "x"
  }, as: :json
  assert_response :no_content
end
```

- [ ] **Step 2.2: Run tests to verify they fail**

```bash
bundle exec rake test TEST=test/controllers/mbeditor/editors_controller_test.rb TESTOPTS="--name=/save_file_history/"
```

Expected: failures with routing or missing action errors.

- [ ] **Step 2.3: Add `save_file_history` action**

In `editors_controller.rb`, add after `file_history`:

```ruby
# POST /mbeditor/file_history
def save_file_history
  branch = sanitize_branch_name(params[:branch])
  return render json: { error: 'Invalid branch name' }, status: :bad_request unless branch

  path = resolve_path(params[:path])
  return render json: { error: 'Forbidden' }, status: :forbidden unless path

  rel      = relative_path(path)
  new_ops  = params[:ops]
  return render json: { error: 'ops must be an array' }, status: :bad_request unless new_ops.is_a?(Array)
  return head :no_content if new_ops.empty?

  new_ops_clean = new_ops.map { |op| Array(op).first(5) }

  hist = history_file_path(branch, rel)
  FileUtils.mkdir_p(File.dirname(hist))

  File.open(hist, File::RDWR | File::CREAT) do |f|
    f.flock(File::LOCK_EX)
    existing = f.size > 0 ? (JSON.parse(f.read) rescue {}) : {}

    if existing.empty?
      base = params[:base].to_s
      return render json: { error: 'base required for initial history' }, status: :bad_request if base.empty?
      existing = { 'branch' => branch, 'path' => rel, 'base' => base, 'ops' => [], 't' => Time.now.utc.iso8601 }
    end

    existing['ops'] = (existing['ops'] || []) + new_ops_clean
    existing['t']   = Time.now.utc.iso8601

    if existing['ops'].length > HISTORY_MAX_OPS
      to_compact      = existing['ops'].shift(HISTORY_COMPACT_TARGET)
      existing['base'] = compact_history_ops(existing['base'], to_compact)
    end

    f.truncate(0)
    f.rewind
    f.write(existing.to_json)
  end

  head :no_content
rescue StandardError => e
  render json: { error: e.message }, status: :unprocessable_content
end
```

- [ ] **Step 2.4: Run all file_history tests**

```bash
bundle exec rake test TEST=test/controllers/mbeditor/editors_controller_test.rb TESTOPTS="--name=/file_history|save_file_history/"
```

Expected: all pass.

- [ ] **Step 2.5: Commit**

```bash
git add app/controllers/mbeditor/editors_controller.rb test/controllers/mbeditor/editors_controller_test.rb
git commit -m "feat: add file_history POST endpoint with compaction"
```

---

## Task 3: Extend `prune_branch_states` to prune history

**Files:**
- Modify: `app/controllers/mbeditor/editors_controller.rb`
- Test: `test/controllers/mbeditor/editors_controller_test.rb`

- [ ] **Step 3.1: Write failing test**

Add to `editors_controller_test.rb`:

```ruby
test "prune_branch_states also deletes history files for deleted branches" do
  system("git", "-C", @workspace, "init", "-q")
  system("git", "-C", @workspace, "-c", "user.email=t@t.com", "-c", "user.name=T", "commit", "--allow-empty", "-m", "init", "-q")

  # Save history for a branch that won't exist in the repo
  post "/mbeditor/file_history", params: {
    branch: "ghost-branch-xyz",
    path: "app/models/user.rb",
    ops: [[1,1,1,1,"x"]],
    base: "x"
  }, as: :json
  assert_response :no_content

  branch_hash = Digest::SHA256.hexdigest("ghost-branch-xyz")[0,16]
  file_hash   = Digest::SHA256.hexdigest("app/models/user.rb")[0,16]
  hist_file   = File.join(@workspace, "tmp", "mbeditor_history", "#{branch_hash}_#{file_hash}.json")
  assert File.exist?(hist_file), "history file should exist before prune"

  post "/mbeditor/prune_branch_states", as: :json
  assert_response :ok
  assert_not File.exist?(hist_file), "history file should be deleted after prune"
end
```

- [ ] **Step 3.2: Run test to verify it fails**

```bash
bundle exec rake test TEST=test/controllers/mbeditor/editors_controller_test.rb TESTOPTS="--name=/prune_branch_states also deletes history/"
```

Expected: FAIL — history file still exists after prune.

- [ ] **Step 3.3: Extend `prune_branch_states`**

In `editors_controller.rb`, modify `prune_branch_states` to add history pruning after the existing `render json: { pruned: pruned }` call. Replace the entire `prune_branch_states` action with:

```ruby
def prune_branch_states
  state_path = workspace_root.join("tmp", "mbeditor_branch_states.json")

  root = workspace_root.to_s
  out, _err, status = Open3.capture3("git", "-C", root, "branch", "--format=%(refname:short)")
  return render json: { pruned: [] } unless status.success?

  local_branches = out.split("\n").map(&:strip).reject(&:empty?)
  pruned = []

  if File.exist?(state_path)
    File.open(state_path, File::RDWR) do |f|
      f.flock(File::LOCK_EX)
      all    = JSON.parse(f.read) rescue {}
      pruned = all.keys - local_branches
      if pruned.any?
        pruned.each { |b| all.delete(b) }
        f.truncate(0)
        f.rewind
        f.write(all.to_json)
      end
    end
  end

  hist_dir = workspace_root.join('tmp', 'mbeditor_history')
  if File.directory?(hist_dir)
    Dir.glob(File.join(hist_dir, '*.json')) do |hist_file|
      data = JSON.parse(File.read(hist_file)) rescue nil
      next unless data.is_a?(Hash) && data['branch']
      FileUtils.rm_f(hist_file) unless local_branches.include?(data['branch'])
    end
  end

  render json: { pruned: pruned }
rescue StandardError => e
  render json: { error: e.message }, status: :unprocessable_content
end
```

- [ ] **Step 3.4: Run all history tests**

```bash
bundle exec rake test TEST=test/controllers/mbeditor/editors_controller_test.rb TESTOPTS="--name=/file_history|save_file_history|prune_branch_states/"
```

Expected: all pass.

- [ ] **Step 3.5: Run full test suite**

```bash
bundle exec rake test
```

Expected: all 403+ tests pass.

- [ ] **Step 3.6: Commit**

```bash
git add app/controllers/mbeditor/editors_controller.rb test/controllers/mbeditor/editors_controller_test.rb
git commit -m "feat: extend prune_branch_states to clean up stale file history"
```

---

## Task 4: `HistoryService` — new JS module

**Files:**
- Create: `app/assets/javascripts/mbeditor/history_service.js`

No JS test framework exists in this project; the service is exercised through system tests.

- [ ] **Step 4.1: Check the asset manifest to see how JS files are included**

```bash
cat app/assets/javascripts/mbeditor/application.js 2>/dev/null || \
  grep -r "history_service\|require_tree\|require mbeditor" app/assets/javascripts/ | head -10
```

Note the pattern used to include JS files (likely `//= require` directives).

- [ ] **Step 4.2: Create `history_service.js`**

Create `app/assets/javascripts/mbeditor/history_service.js`:

```javascript
'use strict';

var HistoryService = (function () {
  // _tracking[filePath] = { branch }
  var _tracking = {};
  // _pending["branch:filePath"] = [[sl,sc,el,ec,text], ...]
  var _pending = {};
  // _bases["branch:filePath"] = "original content" — cleared after first flush
  var _bases = {};
  // _replayingPaths: Set of filePaths currently undergoing Phase 2 replay
  var _replayingPaths = {};
  // _idleTimers["branch:filePath"] = timerHandle
  var _idleTimers = {};

  var IDLE_MS = 30000;

  function _key(branch, filePath) {
    return branch + ':' + filePath;
  }

  function beginTracking(branch, filePath, baseContent) {
    _tracking[filePath] = { branch: branch };
    var k = _key(branch, filePath);
    _pending[k] = _pending[k] || [];
    _bases[k] = baseContent;
  }

  function resumeTracking(branch, filePath) {
    _tracking[filePath] = { branch: branch };
    var k = _key(branch, filePath);
    _pending[k] = _pending[k] || [];
  }

  function stopTracking(filePath) {
    var rec = _tracking[filePath];
    if (!rec) return;
    var k = _key(rec.branch, filePath);
    clearTimeout(_idleTimers[k]);
    delete _idleTimers[k];
    flush(rec.branch, filePath);
    delete _tracking[filePath];
  }

  function setReplayInProgress(filePath, inProgress) {
    if (inProgress) {
      _replayingPaths[filePath] = true;
    } else {
      delete _replayingPaths[filePath];
    }
  }

  function recordOps(filePath, changes) {
    if (_replayingPaths[filePath]) return;
    var rec = _tracking[filePath];
    if (!rec) return;
    var k = _key(rec.branch, filePath);
    var bucket = _pending[k] = _pending[k] || [];
    for (var i = 0; i < changes.length; i++) {
      var c = changes[i];
      bucket.push([
        c.range.startLineNumber,
        c.range.startColumn,
        c.range.endLineNumber,
        c.range.endColumn,
        c.text
      ]);
    }
    clearTimeout(_idleTimers[k]);
    _idleTimers[k] = setTimeout(function () { flush(rec.branch, filePath); }, IDLE_MS);
  }

  function flush(branch, filePath) {
    var k = _key(branch, filePath);
    var ops = _pending[k];
    if (!ops || ops.length === 0) return;
    _pending[k] = [];
    clearTimeout(_idleTimers[k]);
    delete _idleTimers[k];

    var body = { branch: branch, path: filePath, ops: ops };
    if (_bases.hasOwnProperty(k)) {
      body.base = _bases[k];
      delete _bases[k];
    }

    try {
      fetch(window.mbeditorBasePath() + '/file_history', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Mbeditor-Client': '1'
        },
        body: JSON.stringify(body)
      }).catch(function () {
        // On failure, put ops back so next flush retries
        var existing = _pending[k] || [];
        _pending[k] = ops.concat(existing);
        if (body.base !== undefined && !_bases.hasOwnProperty(k)) {
          _bases[k] = body.base;
        }
      });
    } catch (e) {}
  }

  function flushAll(options) {
    var useKeepalive = options && options.keepalive;
    Object.keys(_tracking).forEach(function (filePath) {
      var rec = _tracking[filePath];
      var k = _key(rec.branch, filePath);
      var ops = _pending[k];
      if (!ops || ops.length === 0) return;
      var remaining = ops.slice();
      _pending[k] = [];
      clearTimeout(_idleTimers[k]);
      delete _idleTimers[k];

      var body = { branch: rec.branch, path: filePath, ops: remaining };
      if (_bases.hasOwnProperty(k)) {
        body.base = _bases[k];
        delete _bases[k];
      }

      try {
        fetch(window.mbeditorBasePath() + '/file_history', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'X-Mbeditor-Client': '1'
          },
          keepalive: useKeepalive === true,
          body: JSON.stringify(body)
        });
      } catch (e) {}
    });
  }

  function fetchHistory(branch, filePath) {
    return fetch(
      window.mbeditorBasePath() + '/file_history' +
      '?branch=' + encodeURIComponent(branch) +
      '&path='   + encodeURIComponent(filePath),
      { headers: { 'X-Mbeditor-Client': '1' } }
    ).then(function (res) {
      if (!res.ok) return null;
      return res.json();
    }).then(function (data) {
      if (!data || !data.ops || data.ops.length === 0) return null;
      return data;
    }).catch(function () { return null; });
  }

  // Global flush triggers
  document.addEventListener('visibilitychange', function () {
    if (document.visibilityState === 'hidden') flushAll({});
  });

  window.addEventListener('beforeunload', function () {
    flushAll({ keepalive: true });
  });

  function flushForPath(filePath) {
    var rec = _tracking[filePath];
    if (rec) flush(rec.branch, filePath);
  }

  return {
    beginTracking:       beginTracking,
    resumeTracking:      resumeTracking,
    stopTracking:        stopTracking,
    setReplayInProgress: setReplayInProgress,
    recordOps:           recordOps,
    flush:               flush,
    flushAll:            flushAll,
    flushForPath:        flushForPath,
    fetchHistory:        fetchHistory
  };
})();
```

- [ ] **Step 4.3: Include the file in the asset pipeline**

In `app/assets/javascripts/mbeditor/application.js`, add after line 4 (`//= require mbeditor/file_service`):

```javascript
//= require mbeditor/history_service
```

- [ ] **Step 4.4: Run the full test suite**

```bash
bundle exec rake test
```

Expected: all tests still pass (new JS file has no Ruby tests).

- [ ] **Step 4.5: Commit**

```bash
git add app/assets/javascripts/mbeditor/history_service.js app/assets/javascripts/mbeditor/application.js
git commit -m "feat: add HistoryService for client-side op capture and server flush"
```

---

## Task 5: Wire capture into `EditorPanel.js`

**Files:**
- Modify: `app/assets/javascripts/mbeditor/components/EditorPanel.js`

- [ ] **Step 5.1: Add `beginTracking`/`resumeTracking` call after model creation**

Locate the block at lines 523–530 (new model) and 514–519 (reused model). Add tracking calls.

After the `if (_modelEntry && ...) { ... } else { ... }` block that sets up `modelObj` (ends around line 530), add:

```javascript
    // Begin or resume HistoryService tracking for this file/branch.
    if (typeof HistoryService !== 'undefined') {
      var _histBranch = EditorStore.getState().gitBranch || '';
      if (_histBranch) {
        if (_reusingModel) {
          HistoryService.resumeTracking(_histBranch, tab.path);
        } else {
          HistoryService.beginTracking(_histBranch, tab.path, tab.content || '');
        }
      }
    }
```

- [ ] **Step 5.2: Wire `recordOps` inside the `onDidChangeContent` handler**

At line 698, the handler starts:
```javascript
    var contentDisposable = modelObj.onDidChangeContent(function (e) {
```

Add `HistoryService.recordOps` call at the **top** of that handler, before the AVI logic:

```javascript
    var contentDisposable = modelObj.onDidChangeContent(function (e) {
      if (typeof HistoryService !== 'undefined') {
        HistoryService.recordOps(tab.path, e.changes);
      }
      // ... rest of existing handler unchanged ...
```

- [ ] **Step 5.3: Run tests to verify no regressions**

```bash
bundle exec rake test
```

Expected: all tests pass.

- [ ] **Step 5.4: Commit**

```bash
git add app/assets/javascripts/mbeditor/components/EditorPanel.js
git commit -m "feat: wire HistoryService capture into EditorPanel onDidChangeContent"
```

---

## Task 6: Wire flush triggers — tab close, save, visibility, unload

**Files:**
- Modify: `app/assets/javascripts/mbeditor/tab_manager.js`
- Modify: `app/assets/javascripts/mbeditor/components/MbeditorApp.js`

Note: `visibilitychange` and `beforeunload` are already handled globally inside `HistoryService.js` (see Task 4). This task covers the per-file flush on tab close and save.

- [ ] **Step 6.1: Flush on `closeTab` in `tab_manager.js`**

Locate `closeTab` at line 351. Add a flush call at the top of the function, before the `var state = EditorStore.getState()` line:

```javascript
  function closeTab(paneId, path) {
    if (typeof HistoryService !== 'undefined') {
      HistoryService.flushForPath(path);
    }
    var state = EditorStore.getState();
    // ... rest of existing closeTab unchanged ...
```

- [ ] **Step 6.2: Flush on save in `MbeditorApp.js`**

Locate `handleSave` at line 1850. After the `FileService.saveFile(tab.path, tab.content).then(function () {` success block and before `.catch(`, add a flush call inside the `.then` callback (right after `_clearDraft(tab.path)`):

```javascript
      if (typeof HistoryService !== 'undefined') {
        HistoryService.flushForPath(tab.path);
      }
```

- [ ] **Step 6.3: Run tests to verify no regressions**

```bash
bundle exec rake test
```

Expected: all tests pass.

- [ ] **Step 6.4: Commit**

```bash
git add app/assets/javascripts/mbeditor/history_service.js app/assets/javascripts/mbeditor/tab_manager.js app/assets/javascripts/mbeditor/components/MbeditorApp.js
git commit -m "feat: wire HistoryService flush on tab close and file save"
```

---

## Task 7: Two-phase load — background replay and model swap

**Files:**
- Modify: `app/assets/javascripts/mbeditor/components/EditorPanel.js`

This is the most complex task. Read it fully before starting.

**How Phase 2 works:**
1. After the editor is set up and `setEditorReady(true)` is called, schedule Phase 2 via `requestIdleCallback` (fallback: `setTimeout(fn, 200)`).
2. Skip Phase 2 if the model is being reused (`_reusingModel === true`) — it already has its undo stack.
3. Fetch history from server. If no history, done.
4. Create Model B with `base` content (detached — not in editor).
5. Set `replayInProgress = true` on HistoryService to suppress recording during replay.
6. Replay ops onto Model B via `model.pushEditOperations()`.
7. Set `replayInProgress = false`.
8. Verify `modelB.getValue() === currentContent`. On mismatch, dispose B and bail.
9. If user edited Model A during replay, capture those ops from a buffer and apply them to Model B.
10. Save view state → `editor.setModel(modelB)` → restore view state → update `window.__mbeditorModels[tab.path]` → dispose Model A.

**Capturing concurrent edits during replay (step 9):** Before fetching history, subscribe to Model A's `onDidChangeContent` into a separate `_phase2Buffer` array. After swap, apply buffered ops to Model B and start recording on Model B.

- [ ] **Step 7.1: Locate insertion point**

The Phase 2 trigger code goes between line 739 (end of `contentDisposable` assignment) and line 741 (`return function() {`). Specifically, after:

```javascript
    });   // ← end of onDidChangeContent handler (line ~739)

    return function () {   // ← cleanup starts (line 741)
```

- [ ] **Step 7.2: Add Phase 2 trigger and swap logic**

Insert the following between the end of the `contentDisposable` assignment and the `return function()` at line 741:

```javascript
    // Phase 2: background undo-history replay.
    // Only run for newly-created models (reused models already have their undo stack).
    if (!_reusingModel && typeof HistoryService !== 'undefined') {
      var _phase2Branch  = EditorStore.getState().gitBranch || '';
      var _phase2Path    = tab.path;
      var _phase2Content = tab.content || '';
      var _phase2Buf     = [];   // ops buffered while replay is in flight
      var _phase2Active  = true; // cleared in cleanup if tab is unmounted before Phase 2 finishes

      // Capture edits that happen to Model A while we're fetching/replaying.
      var _phase2ModelA = modelObj;
      var _phase2Listener = _phase2ModelA.onDidChangeContent(function (ev) {
        if (!_phase2Active) return;
        for (var _ci = 0; _ci < ev.changes.length; _ci++) {
          var _c = ev.changes[_ci];
          _phase2Buf.push([
            _c.range.startLineNumber, _c.range.startColumn,
            _c.range.endLineNumber,   _c.range.endColumn,
            _c.text
          ]);
        }
      });

      var _runPhase2 = function () {
        if (!_phase2Active || !_phase2Branch) return;
        HistoryService.fetchHistory(_phase2Branch, _phase2Path).then(function (hist) {
          if (!_phase2Active) return;
          if (!hist || !hist.ops || hist.ops.length === 0) {
            _phase2Listener.dispose();
            return;
          }

          // Build Model B (detached) from the recorded base.
          var _lang = modelObj.getLanguageId();
          var modelB = window.monaco.editor.createModel(hist.base, _lang);

          HistoryService.setReplayInProgress(_phase2Path, true);
          try {
            for (var _oi = 0; _oi < hist.ops.length; _oi++) {
              var _op = hist.ops[_oi];
              modelB.pushEditOperations([], [{
                range: new window.monaco.Range(_op[0], _op[1], _op[2], _op[3]),
                text:  _op[4] || ''
              }], function () { return null; });
            }
          } catch (e) {
            HistoryService.setReplayInProgress(_phase2Path, false);
            _phase2Listener.dispose();
            modelB.dispose();
            return;
          }
          HistoryService.setReplayInProgress(_phase2Path, false);

          // Verify final content matches what the editor currently shows.
          var _expectedContent = _phase2ModelA.getValue();
          if (modelB.getValue() !== _expectedContent) {
            _phase2Listener.dispose();
            modelB.dispose();
            return;
          }

          // Apply any edits the user made to Model A while replay was running.
          if (_phase2Buf.length > 0) {
            try {
              for (var _bi = 0; _bi < _phase2Buf.length; _bi++) {
                var _bop = _phase2Buf[_bi];
                modelB.pushEditOperations([], [{
                  range: new window.monaco.Range(_bop[0], _bop[1], _bop[2], _bop[3]),
                  text:  _bop[4] || ''
                }], function () { return null; });
              }
            } catch (e) {
              _phase2Listener.dispose();
              modelB.dispose();
              return;
            }
          }

          _phase2Listener.dispose();
          if (!_phase2Active) { modelB.dispose(); return; }

          // Transparent swap: same content, same position, full undo stack.
          if (modelB.getLanguageId() !== _lang) {
            window.monaco.editor.setModelLanguage(modelB, _lang);
          }
          modelB._mbeditorPath = _phase2Path;

          var _vs = editor.saveViewState();
          editor.setModel(modelB);
          if (_vs) editor.restoreViewState(_vs);

          // Update the model cache entry.
          var _oldEntry = window.__mbeditorModels[_phase2Path];
          if (_oldEntry && _oldEntry.model !== modelB) {
            var _oldModel = _oldEntry.model;
            window.__mbeditorModels[_phase2Path] = {
              model:        modelB,
              aviBase:      aviBaseRef.current,
              aviMax:       modelB.getAlternativeVersionId(),
              lastAccessed: Date.now(),
              cleanVersionId: _oldEntry.cleanVersionId
            };
            // Dispose old model after a tick so any in-flight operations complete.
            setTimeout(function () {
              if (_oldModel && !_oldModel.isDisposed()) _oldModel.dispose();
            }, 0);
          }
        }).catch(function () {
          // Network or parse error — history simply unavailable, editor still works.
          _phase2Listener.dispose();
        });
      };

      // Run after browser is idle (fallback: 200ms).
      if (typeof requestIdleCallback !== 'undefined') {
        requestIdleCallback(_runPhase2, { timeout: 2000 });
      } else {
        setTimeout(_runPhase2, 200);
      }

      // If the tab is unmounted before Phase 2 completes, cancel it.
      var _phase2CleanupFn = function () { _phase2Active = false; _phase2Listener.dispose(); };
    }
```

- [ ] **Step 7.3: Add cleanup for Phase 2 inside the existing `return function()`**

In the cleanup function (starting at line 741), after the existing cleanup code but before `editor.dispose()`, add:

```javascript
      if (typeof _phase2CleanupFn !== 'undefined') _phase2CleanupFn();
```

- [ ] **Step 7.4: Run the full test suite**

```bash
bundle exec rake test
```

Expected: all 403+ tests pass.

- [ ] **Step 7.5: Commit**

```bash
git add app/assets/javascripts/mbeditor/components/EditorPanel.js
git commit -m "feat: two-phase load — replay undo history on detached model and swap transparently"
```

---

## Task 8: System-level smoke test and CHANGES.md update

**Files:**
- Modify: `CHANGES.md`

- [ ] **Step 8.1: Manual smoke test**

```bash
cd test/dummy && rails server
```

1. Open the editor at `http://localhost:3000/mbeditor`.
2. Open a file and make several edits (type, delete, paste).
3. Verify no history-related errors appear in the browser console.
4. Verify the Rails server log does NOT show POST `/mbeditor/file_history` lines.
5. Reload the page. Verify Ctrl+Z steps back through edits made before reload.
6. Switch git branches (if available). Verify edits on the original branch are still undoable after switching back.
7. Save the file. Make more edits. Verify Ctrl+Z can undo past the save.

- [ ] **Step 8.2: Verify history file on disk**

```bash
ls tmp/mbeditor_history/
cat tmp/mbeditor_history/*.json | python3 -m json.tool | head -30
```

Verify: file exists, contains `branch`, `path`, `base`, `ops`, `t` fields.

- [ ] **Step 8.3: Update CHANGES.md**

Add an entry to `CHANGES.md` describing the new feature.

- [ ] **Step 8.4: Final commit**

```bash
git add CHANGES.md
git commit -m "docs: record persistent undo history feature in CHANGES.md"
```
