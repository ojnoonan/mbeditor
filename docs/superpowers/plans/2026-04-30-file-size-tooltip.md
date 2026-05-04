# File Size Tooltip Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show auto-scaled file size (B / KB / MB) in the explorer sidebar tooltip when hovering over a file.

**Architecture:** Add `size` (bytes, Integer) to each file entry returned by `build_tree` on the backend; add a `formatSize` JS helper in `FileTree.js` and append the formatted size to the existing `title` prop on `.tree-item-name`. Folders get no size. No new endpoints.

**Tech Stack:** Ruby / Rails controller, plain React (no JSX build step).

---

### Task 1: Backend — include `size` in file tree entries

**Files:**
- Modify: `app/controllers/mbeditor/editors_controller.rb:1064-1080` (`build_tree`)
- Test: `test/controllers/mbeditor/editors_controller_test.rb` (after line 143)

- [ ] **Step 1: Write the failing test**

  Insert after the existing `"files returns file tree"` test (line 143):

  ```ruby
  test "files includes size for file entries but not folders" do
    get "/mbeditor/files"
    assert_response :ok

    files   = json.select { |n| n["type"] == "file" }
    folders = json.select { |n| n["type"] == "folder" }

    assert files.any?,   "expected at least one file at root"
    assert folders.any?, "expected at least one folder at root"

    files.each   { |f| assert f.key?("size"),    "file #{f["name"]} missing size key" }
    folders.each { |d| assert_nil d["size"],      "folder #{d["name"]} should not have size" }
    files.each   { |f| assert_kind_of Integer, f["size"] }
    files.each   { |f| assert f["size"] >= 0 }
  end
  ```

- [ ] **Step 2: Run test to verify it fails**

  ```bash
  bundle exec ruby -Itest test/controllers/mbeditor/editors_controller_test.rb \
    -n "test_files_includes_size_for_file_entries_but_not_folders"
  ```
  Expected: FAIL — `"file README.md missing size key"`

- [ ] **Step 3: Implement — add `size` to file entries in `build_tree`**

  In `app/controllers/mbeditor/editors_controller.rb`, replace the `build_tree` method (lines 1064-1080):

  ```ruby
  def build_tree(dir, max_depth: 10, depth: 0)
    return [] if depth >= max_depth

    entries = Dir.entries(dir).sort.reject { |entry| entry == "." || entry == ".." }
    entries.filter_map do |name|
      full = File.join(dir, name)
      rel  = relative_path(full)

      if File.directory?(full)
        { name: name, type: "folder", path: rel, children: build_tree(full, depth: depth + 1) }
      else
        size = File.size(full) rescue nil
        { name: name, type: "file", path: rel, size: size }
      end
    end
  rescue Errno::EACCES
    []
  end
  ```

- [ ] **Step 4: Run test to verify it passes**

  ```bash
  bundle exec ruby -Itest test/controllers/mbeditor/editors_controller_test.rb \
    -n "test_files_includes_size_for_file_entries_but_not_folders"
  ```
  Expected: PASS

- [ ] **Step 5: Run full test suite**

  ```bash
  bundle exec rake test
  ```
  Expected: all existing tests continue to pass (size field is additive — no existing assertion breaks).

- [ ] **Step 6: Commit**

  ```bash
  git add app/controllers/mbeditor/editors_controller.rb \
          test/controllers/mbeditor/editors_controller_test.rb
  git commit -m "feat: include file size in tree API response"
  ```

---

### Task 2: Frontend — formatSize helper + tooltip

**Files:**
- Modify: `app/assets/javascripts/mbeditor/components/FileTree.js` (add helper near top; update line ~480)

- [ ] **Step 1: Add `formatSize` helper near the top of `FileTree.js`**

  Find the line `var FileTree = function FileTree(` (around line 15) and insert the helper immediately before it:

  ```javascript
  function formatSize(bytes) {
    if (typeof bytes !== 'number' || bytes < 0) return '';
    if (bytes < 1024)        return bytes + ' B';
    if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
    return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
  }
  ```

- [ ] **Step 2: Update the `title` prop on `.tree-item-name`**

  In `FileTree.js`, find the `.tree-item-name` element (around line 480):

  ```javascript
  { className: 'tree-item-name', title: node.path },
  ```

  Replace with:

  ```javascript
  { className: 'tree-item-name', title: node.type === 'file' && node.size != null ? node.path + ' — ' + formatSize(node.size) : node.path },
  ```

  (`—` is an em dash `—`.)

- [ ] **Step 3: Run the full test suite to confirm no regressions**

  ```bash
  bundle exec rake test
  ```
  Expected: all tests pass.

- [ ] **Step 4: Verify visually in the browser**

  Start the dummy app if not running:
  ```bash
  cd test/dummy && rails server
  ```
  Open `http://localhost:3000/mbeditor`, hover over any file in the explorer sidebar. The native browser tooltip should show e.g. `app/models/user.rb — 2.3 KB`. Hover over a folder — tooltip should show path only (no size).

- [ ] **Step 5: Commit**

  ```bash
  git add app/assets/javascripts/mbeditor/components/FileTree.js
  git commit -m "feat: show auto-scaled file size in explorer tooltip"
  ```
