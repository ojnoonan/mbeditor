# Drag-and-Drop External File Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user drag files and folders from their operating system onto the mbeditor file explorer to import them into the workspace, with an explicit prompt when a target path already exists.

**Architecture:** A new `Mbeditor::FileImportService` writes uploaded entries to disk and owns conflict resolution. A new `POST /mbeditor/import` multipart endpoint validates every target path through the existing `resolve_path` + `path_blocked_for_operations?` guards, enforces batch limits, and delegates. The client uploads in up to two passes: pass one with `on_conflict=ask` writes the non-conflicting entries and reports the rest untouched; if there are conflicts, a modal collects Overwrite / Keep both / Skip and pass two re-sends only those entries.

**Tech Stack:** Rails engine (Ruby, Minitest), plain ES5 JavaScript + React via `React.createElement` (no build step, no JSX, no arrow functions, no `async`/`await` — match the surrounding style), Sprockets asset pipeline, axios.

**Spec:** `docs/superpowers/specs/2026-07-22-drag-drop-file-import-design.md`

---

## File Structure

| Path | Kind | Responsibility |
| --- | --- | --- |
| `app/services/mbeditor/file_import_service.rb` | create | Write entries to disk; resolve conflicts (ask / overwrite / rename) |
| `test/services/mbeditor/file_import_service_test.rb` | create | Unit tests for the above |
| `lib/mbeditor/route_map.rb` | modify | Add `post 'import'` |
| `app/controllers/mbeditor/editors_controller.rb` | modify | Add `import` action, batch limits, per-entry path validation |
| `test/controllers/mbeditor/editors_controller_test.rb` | modify | Endpoint tests |
| `app/assets/javascripts/mbeditor/file_import.js` | create | `FileImport` global: DataTransfer walking, FormData building, path joining |
| `app/assets/javascripts/mbeditor/file_service.js` | modify | Add `importFiles(formData)` |
| `app/assets/javascripts/mbeditor/components/ImportConflictModal.js` | create | The conflict dialog |
| `app/assets/javascripts/mbeditor/components/FileTree.js` | modify | Detect external drops on folder rows and the root container |
| `app/assets/javascripts/mbeditor/components/MbeditorApp.js` | modify | Two-pass orchestration, modal state, wire `onImportFiles` |
| `app/assets/javascripts/mbeditor/application.js` | modify | Sprockets requires for the two new JS files |
| `app/assets/stylesheets/mbeditor/editor.css` | modify | Drop-target highlight + modal list styles |
| `CHANGELOG.md`, `CLAUDE.md` | modify | Document the feature and the new service |

Directory walking and FormData building live in `file_import.js` rather than inside `FileTree.js` or `MbeditorApp.js` — both of those files are already large, and the DataTransfer logic is pure, framework-free, and worth isolating.

One deliberate split from the spec: the spec listed "a target resolving outside the workspace root is rejected" among the *service* tests. `FileImportService` does no sandboxing of its own — the controller clears every path through `resolve_path` and `path_blocked_for_operations?` before the service sees it, exactly as `FileOperationService` already works. That case is therefore covered by a controller test (Task 4) rather than a service test.

---

### Task 1: FileImportService — writing entries and reporting conflicts

**Files:**
- Create: `app/services/mbeditor/file_import_service.rb`
- Test: `test/services/mbeditor/file_import_service_test.rb`

- [ ] **Step 1: Write the failing tests**

Create `test/services/mbeditor/file_import_service_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"
require "stringio"

module Mbeditor
  class FileImportServiceTest < ActiveSupport::TestCase
    # The service accepts anything that responds to #read and #size, which is
    # what ActionDispatch::Http::UploadedFile gives us in the controller.
    def upload(content)
      StringIO.new(content)
    end

    def entry(dir, rel, content)
      { target_path: File.join(dir, rel), io: upload(content) }
    end

    test "import writes a file and returns it under imported" do
      Dir.mktmpdir do |dir|
        result = FileImportService.new(dir).import([entry(dir, "notes.txt", "hello")])

        assert_equal [{ path: "notes.txt", name: "notes.txt" }], result[:imported]
        assert_empty result[:conflicts]
        assert_empty result[:errors]
        assert_equal "hello", File.read(File.join(dir, "notes.txt"))
      end
    end

    test "import creates intermediate directories for nested targets" do
      Dir.mktmpdir do |dir|
        result = FileImportService.new(dir).import([entry(dir, "assets/img/logo.svg", "<svg/>")])

        assert_equal ["assets/img/logo.svg"], result[:imported].map { |e| e[:path] }
        assert_equal "<svg/>", File.read(File.join(dir, "assets/img/logo.svg"))
      end
    end

    test "import preserves binary content byte for byte" do
      Dir.mktmpdir do |dir|
        bytes = "\x89PNG\r\n\x1a\n\x00\x01\x02\xff".dup.force_encoding(Encoding::BINARY)
        FileImportService.new(dir).import([entry(dir, "logo.png", bytes)])

        assert_equal bytes, File.binread(File.join(dir, "logo.png"))
      end
    end

    test "ask mode reports an existing target without touching it" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "notes.txt"), "original")

        result = FileImportService.new(dir).import(
          [entry(dir, "notes.txt", "replacement")], on_conflict: :ask
        )

        assert_empty result[:imported]
        assert_equal [{ path: "notes.txt" }], result[:conflicts]
        assert_equal "original", File.read(File.join(dir, "notes.txt"))
      end
    end

    test "ask mode writes the free entries in a batch that also conflicts" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "taken.txt"), "original")

        result = FileImportService.new(dir).import(
          [entry(dir, "taken.txt", "replacement"), entry(dir, "free.txt", "new")],
          on_conflict: :ask
        )

        assert_equal ["free.txt"], result[:imported].map { |e| e[:path] }
        assert_equal ["taken.txt"], result[:conflicts].map { |e| e[:path] }
        assert_equal "original", File.read(File.join(dir, "taken.txt"))
        assert_equal "new", File.read(File.join(dir, "free.txt"))
      end
    end

    test "import rejects an unknown on_conflict mode" do
      Dir.mktmpdir do |dir|
        assert_raises(ArgumentError) do
          FileImportService.new(dir).import([entry(dir, "a.txt", "x")], on_conflict: :clobber)
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bundle exec rake test TEST=test/services/mbeditor/file_import_service_test.rb
```

Expected: FAIL with `NameError: uninitialized constant Mbeditor::FileImportService`.

- [ ] **Step 3: Write the minimal implementation**

Create `app/services/mbeditor/file_import_service.rb`:

```ruby
# frozen_string_literal: true

require "fileutils"
require "pathname"

module Mbeditor
  # Writes files dragged into the explorer from outside the browser.
  #
  # Conflict handling is a two-pass protocol driven by the client. Pass one
  # runs with on_conflict: :ask — every entry whose target is free is written,
  # and the rest come back under :conflicts untouched. The client resolves
  # them and re-sends just those entries with :overwrite or :rename. Because
  # the existence check and the write happen inside the same call there is no
  # window between checking and writing.
  #
  # Callers must hand over target paths that have already cleared the
  # controller's resolve_path / path_blocked_for_operations? guards; this
  # service does no sandboxing of its own.
  class FileImportService
    MAX_FILE_SIZE_BYTES = FileOperationService::MAX_FILE_SIZE_BYTES
    CONFLICT_MODES = %i[ask overwrite rename].freeze

    def initialize(workspace_root)
      @workspace_root = Pathname(workspace_root)
    end

    # entries: [{ target_path: <absolute String>, io: <#read, #size> }]
    # => { imported: [{path:, name:}], conflicts: [{path:}], errors: [{path:, error:}] }
    def import(entries, on_conflict: :ask)
      mode = on_conflict.to_sym
      raise ArgumentError, "unknown on_conflict: #{on_conflict}" unless CONFLICT_MODES.include?(mode)

      result = { imported: [], conflicts: [], errors: [] }
      Array(entries).each { |entry| import_entry(entry, mode, result) }
      result
    end

    private

    def import_entry(entry, mode, result)
      target = entry[:target_path].to_s
      io     = entry[:io]

      if File.exist?(target)
        case mode
        when :ask
          return result[:conflicts] << { path: relative_path(target) }
        when :rename
          target = free_path(target)
        end
      end

      write(target, io)
      result[:imported] << { path: relative_path(target), name: File.basename(target) }
    end

    def write(target, io)
      FileUtils.mkdir_p(File.dirname(target))
      io.rewind if io.respond_to?(:rewind)
      File.open(target, "wb") { |f| IO.copy_stream(io, f) }
    end

    # "logo.png" -> "logo 2.png" -> "logo 3.png" ...
    def free_path(target)
      dir  = File.dirname(target)
      ext  = File.extname(target)
      base = File.basename(target, ext)
      counter = 2
      counter += 1 while File.exist?(File.join(dir, "#{base} #{counter}#{ext}"))
      File.join(dir, "#{base} #{counter}#{ext}")
    end

    def relative_path(path)
      Pathname(path).relative_path_from(@workspace_root).to_s
    rescue ArgumentError
      path
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bundle exec rake test TEST=test/services/mbeditor/file_import_service_test.rb
```

Expected: PASS, 6 runs, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add app/services/mbeditor/file_import_service.rb test/services/mbeditor/file_import_service_test.rb && git commit -m "feat: add FileImportService with ask-mode conflict reporting"
```

---

### Task 2: FileImportService — overwrite and rename modes

**Files:**
- Modify: `app/services/mbeditor/file_import_service.rb`
- Test: `test/services/mbeditor/file_import_service_test.rb`

Note: `free_path` was written in Task 1 and already implements the rename search; these tests pin its behavior, including the collision chain.

- [ ] **Step 1: Write the failing tests**

Append inside the `FileImportServiceTest` class, before the final `end`s:

```ruby
    test "overwrite mode replaces the existing file" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "notes.txt"), "original")

        result = FileImportService.new(dir).import(
          [entry(dir, "notes.txt", "replacement")], on_conflict: :overwrite
        )

        assert_equal ["notes.txt"], result[:imported].map { |e| e[:path] }
        assert_empty result[:conflicts]
        assert_equal "replacement", File.read(File.join(dir, "notes.txt"))
      end
    end

    test "rename mode writes to a free name with the counter before the extension" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "logo.png"), "original")

        result = FileImportService.new(dir).import(
          [entry(dir, "logo.png", "new")], on_conflict: :rename
        )

        assert_equal ["logo 2.png"], result[:imported].map { |e| e[:path] }
        assert_equal "logo 2.png", result[:imported].first[:name]
        assert_equal "original", File.read(File.join(dir, "logo.png"))
        assert_equal "new", File.read(File.join(dir, "logo 2.png"))
      end
    end

    test "rename mode walks past an existing counter to the next free name" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "logo.png"), "original")
        File.write(File.join(dir, "logo 2.png"), "second")

        result = FileImportService.new(dir).import(
          [entry(dir, "logo.png", "third")], on_conflict: :rename
        )

        assert_equal ["logo 3.png"], result[:imported].map { |e| e[:path] }
        assert_equal "third", File.read(File.join(dir, "logo 3.png"))
      end
    end

    test "rename mode handles a name with no extension" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "Makefile"), "original")

        result = FileImportService.new(dir).import(
          [entry(dir, "Makefile", "new")], on_conflict: :rename
        )

        assert_equal ["Makefile 2"], result[:imported].map { |e| e[:path] }
      end
    end

    test "rename mode makes room for each entry of a batch that targets one name" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "logo.png"), "original")

        result = FileImportService.new(dir).import(
          [entry(dir, "logo.png", "a"), entry(dir, "logo.png", "b")], on_conflict: :rename
        )

        assert_equal ["logo 2.png", "logo 3.png"], result[:imported].map { |e| e[:path] }
      end
    end
```

- [ ] **Step 2: Run the tests to verify they pass**

```bash
bundle exec rake test TEST=test/services/mbeditor/file_import_service_test.rb
```

Expected: PASS, 11 runs, 0 failures. If any fail, fix `free_path` in `app/services/mbeditor/file_import_service.rb` — no other change should be needed.

- [ ] **Step 3: Commit**

```bash
git add test/services/mbeditor/file_import_service_test.rb && git commit -m "test: cover overwrite and rename conflict modes"
```

---

### Task 3: FileImportService — per-entry error cases

**Files:**
- Modify: `app/services/mbeditor/file_import_service.rb`
- Test: `test/services/mbeditor/file_import_service_test.rb`

- [ ] **Step 1: Write the failing tests**

Append inside `FileImportServiceTest`:

```ruby
    test "an oversized entry becomes an error and is not written" do
      Dir.mktmpdir do |dir|
        big = "x" * (FileImportService::MAX_FILE_SIZE_BYTES + 1)

        result = FileImportService.new(dir).import([entry(dir, "big.bin", big)])

        assert_empty result[:imported]
        assert_equal ["big.bin"], result[:errors].map { |e| e[:path] }
        assert_match(/too large/i, result[:errors].first[:error])
        refute File.exist?(File.join(dir, "big.bin"))
      end
    end

    test "an oversized entry does not stop its siblings from importing" do
      Dir.mktmpdir do |dir|
        big = "x" * (FileImportService::MAX_FILE_SIZE_BYTES + 1)

        result = FileImportService.new(dir).import(
          [entry(dir, "big.bin", big), entry(dir, "small.txt", "ok")]
        )

        assert_equal ["small.txt"], result[:imported].map { |e| e[:path] }
        assert_equal ["big.bin"], result[:errors].map { |e| e[:path] }
      end
    end

    test "a target occupied by a directory is an error under every mode" do
      FileImportService::CONFLICT_MODES.each do |mode|
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "assets"))

          result = FileImportService.new(dir).import(
            [entry(dir, "assets", "not a folder")], on_conflict: mode
          )

          assert_empty result[:imported], "mode #{mode} imported over a directory"
          assert_empty result[:conflicts], "mode #{mode} reported a directory as a conflict"
          assert_equal ["assets"], result[:errors].map { |e| e[:path] }
          assert File.directory?(File.join(dir, "assets"))
        end
      end
    end

    test "an unwritable target becomes an error rather than raising" do
      skip "root ignores directory permissions" if Process.uid.zero?

      Dir.mktmpdir do |dir|
        locked = File.join(dir, "locked")
        FileUtils.mkdir_p(locked)
        File.chmod(0o500, locked)

        result = FileImportService.new(dir).import([entry(dir, "locked/x.txt", "nope")])

        assert_empty result[:imported]
        assert_equal ["locked/x.txt"], result[:errors].map { |e| e[:path] }
      ensure
        File.chmod(0o700, locked) if locked && File.directory?(locked)
      end
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bundle exec rake test TEST=test/services/mbeditor/file_import_service_test.rb
```

Expected: FAIL — the oversized tests fail because the file is written anyway, the directory test fails with `Errno::EISDIR`, and the unwritable test fails with `Errno::EACCES` escaping the call.

- [ ] **Step 3: Add the guards to the implementation**

In `app/services/mbeditor/file_import_service.rb`, replace `import_entry` with:

```ruby
    def import_entry(entry, mode, result)
      target = entry[:target_path].to_s
      io     = entry[:io]

      if io.size.to_i > MAX_FILE_SIZE_BYTES
        return result[:errors] << {
          path: relative_path(target),
          error: "File is too large (limit is #{MAX_FILE_SIZE_BYTES / 1024 / 1024} MB)"
        }
      end

      # A directory is never replaced, whatever the mode: overwriting one would
      # mean deleting a subtree the user cannot see from the drop.
      if File.directory?(target)
        return result[:errors] << {
          path: relative_path(target),
          error: "A folder already exists at this path"
        }
      end

      if File.exist?(target)
        case mode
        when :ask
          return result[:conflicts] << { path: relative_path(target) }
        when :rename
          target = free_path(target)
        end
      end

      write(target, io)
      result[:imported] << { path: relative_path(target), name: File.basename(target) }
    rescue SystemCallError, IOError => e
      result[:errors] << { path: relative_path(entry[:target_path].to_s), error: e.message }
    end
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bundle exec rake test TEST=test/services/mbeditor/file_import_service_test.rb
```

Expected: PASS, 15 runs, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add app/services/mbeditor/file_import_service.rb test/services/mbeditor/file_import_service_test.rb && git commit -m "feat: per-entry error handling for file import"
```

---

### Task 4: The import endpoint

**Files:**
- Modify: `lib/mbeditor/route_map.rb`
- Modify: `app/controllers/mbeditor/editors_controller.rb`
- Test: `test/controllers/mbeditor/editors_controller_test.rb`

- [ ] **Step 1: Write the failing tests**

Add to `test/controllers/mbeditor/editors_controller_test.rb`, inside the class:

```ruby
    # ---------------------------------------------------------------------------
    # import
    # ---------------------------------------------------------------------------

    # Rack::Test::UploadedFile needs a file on disk; @upload_dir holds the
    # sources so they are never confused with workspace contents.
    def uploaded(name, content)
      @upload_dir ||= Dir.mktmpdir("mbeditor_uploads_")
      source = File.join(@upload_dir, name)
      FileUtils.mkdir_p(File.dirname(source))
      File.binwrite(source, content)
      Rack::Test::UploadedFile.new(source, "application/octet-stream", true)
    end

    test "import writes a dropped file into the workspace" do
      post "/mbeditor/import", params: {
        files: [uploaded("notes.txt", "hello")],
        paths: ["notes.txt"],
        on_conflict: "ask"
      }

      assert_response :ok
      assert_equal ["notes.txt"], json["imported"].map { |e| e["path"] }
      assert_empty json["conflicts"]
      assert_empty json["errors"]
      assert_equal "hello", File.read(File.join(@workspace, "notes.txt"))
    end

    test "import preserves binary content byte for byte" do
      bytes = "\x89PNG\r\n\x1a\n\x00\x01\x02\xff".dup.force_encoding(Encoding::BINARY)

      post "/mbeditor/import", params: {
        files: [uploaded("logo.png", bytes)],
        paths: ["app/assets/logo.png"],
        on_conflict: "ask"
      }

      assert_response :ok
      assert_equal bytes, File.binread(File.join(@workspace, "app/assets/logo.png"))
    end

    test "import reports an existing target as a conflict without writing it" do
      post "/mbeditor/import", params: {
        files: [uploaded("README.md", "replacement")],
        paths: ["README.md"],
        on_conflict: "ask"
      }

      assert_response :ok
      assert_equal ["README.md"], json["conflicts"].map { |e| e["path"] }
      assert_equal "# Hello\n", File.read(File.join(@workspace, "README.md"))
    end

    test "import overwrites when asked to" do
      post "/mbeditor/import", params: {
        files: [uploaded("README.md", "replacement")],
        paths: ["README.md"],
        on_conflict: "overwrite"
      }

      assert_response :ok
      assert_equal ["README.md"], json["imported"].map { |e| e["path"] }
      assert_equal "replacement", File.read(File.join(@workspace, "README.md"))
    end

    test "import rejects a path outside the workspace as an entry error" do
      post "/mbeditor/import", params: {
        files: [uploaded("evil.txt", "x")],
        paths: ["../evil.txt"],
        on_conflict: "ask"
      }

      assert_response :ok
      assert_empty json["imported"]
      assert_equal ["../evil.txt"], json["errors"].map { |e| e["path"] }
    end

    test "import rejects an excluded path as an entry error" do
      post "/mbeditor/import", params: {
        files: [uploaded("cache.txt", "x")],
        paths: ["tmp/cache.txt"],
        on_conflict: "ask"
      }

      assert_response :ok
      assert_empty json["imported"]
      assert_equal ["tmp/cache.txt"], json["errors"].map { |e| e["path"] }
      refute File.exist?(File.join(@workspace, "tmp", "cache.txt"))
    end

    test "import without the client header is forbidden" do
      # Bypass the header-injecting override defined at the top of this class.
      integration_session.post "/mbeditor/import", params: {
        files: [uploaded("notes.txt", "hello")],
        paths: ["notes.txt"]
      }

      assert_response :forbidden
      refute File.exist?(File.join(@workspace, "notes.txt"))
    end
```

Add the upload directory cleanup to the existing `teardown`, as its first line:

```ruby
      FileUtils.rm_rf(@upload_dir) if @upload_dir
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bundle exec rake test TEST=test/controllers/mbeditor/editors_controller_test.rb TESTOPTS="--name=/import/"
```

Expected: FAIL with `ActionController::RoutingError: No route matches [POST] "/mbeditor/import"`.

- [ ] **Step 3: Add the route**

In `lib/mbeditor/route_map.rb`, add after the `post 'create_dir'` line:

```ruby
    post   'import',          to: 'editors#import'
```

- [ ] **Step 4: Add the controller action**

In `app/controllers/mbeditor/editors_controller.rb`, add these constants next to the existing `TOTAL_LINES_CACHE_MAX` constant near the top of the class:

```ruby
    # Kept below Rack's multipart_part_limit (128 file parts in Rack 3.2), which
    # is enforced during param parsing — outside the action, where this
    # controller's rescue cannot turn it into a clean 422. A batch larger than
    # the Rack limit raises MultipartPartLimitError and surfaces as a 500, so
    # this guard is only reachable if it trips first.
    IMPORT_MAX_FILES = 100
    IMPORT_MAX_TOTAL_BYTES = 50 * 1024 * 1024
```

Then add the action immediately after `create_dir`:

```ruby
    # POST /mbeditor/import — write files dragged in from outside the browser.
    #
    # Multipart: files[] carries the bodies, paths[] the parallel list of
    # workspace-relative targets, on_conflict one of ask/overwrite/rename.
    # A structurally invalid batch is a 422; per-entry problems come back in
    # the :errors array so one bad path never sinks the whole drop.
    def import
      files = Array(params[:files])
      paths = Array(params[:paths]).map(&:to_s)
      mode  = params[:on_conflict].presence || "ask"

      error = import_batch_error(files, paths, mode)
      return render json: { error: error }, status: :unprocessable_content if error

      entries = []
      errors  = []
      files.each_with_index do |file, i|
        full = resolve_path(paths[i])
        if full.nil? || path_blocked_for_operations?(full)
          errors << { path: paths[i], error: "Cannot write to this path" }
        else
          entries << { target_path: full, io: file }
        end
      end

      result = FileImportService.new(workspace_root).import(entries, on_conflict: mode.to_sym)
      result[:errors] = errors + result[:errors]

      written = result[:imported].map { |e| File.join(workspace_root.to_s, e[:path]) }
      broadcast_files_changed(written) if written.any?

      render json: result
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end
```

And add this private helper next to `path_blocked_for_operations?`:

```ruby
    # Returns a message when the import batch is structurally unusable, nil
    # when it is worth handing to FileImportService.
    def import_batch_error(files, paths, mode)
      return "Nothing to import" if files.empty?
      return "files and paths must be the same length" unless files.length == paths.length
      unless FileImportService::CONFLICT_MODES.include?(mode.to_s.to_sym)
        return "Unknown on_conflict: #{mode}"
      end
      # A String responds to #size but not #read, so this also rejects a batch
      # that smuggles plain params in through files[].
      unless files.all? { |f| f.respond_to?(:read) && f.respond_to?(:size) }
        return "files must be uploaded files"
      end
      return "Too many files — #{IMPORT_MAX_FILES} maximum per drop." if files.length > IMPORT_MAX_FILES

      total = files.sum { |f| f.size.to_i }
      if total > IMPORT_MAX_TOTAL_BYTES
        return "Drop is too large (#{human_size(total)}). Limit is #{human_size(IMPORT_MAX_TOTAL_BYTES)}."
      end

      nil
    end
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
bundle exec rake test TEST=test/controllers/mbeditor/editors_controller_test.rb TESTOPTS="--name=/import/"
```

Expected: PASS, 7 runs, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/mbeditor/route_map.rb app/controllers/mbeditor/editors_controller.rb test/controllers/mbeditor/editors_controller_test.rb && git commit -m "feat: add POST /mbeditor/import endpoint"
```

---

### Task 5: Batch limit and validation tests

**Files:**
- Test: `test/controllers/mbeditor/editors_controller_test.rb`

The guards were written in Task 4; these tests pin them.

- [ ] **Step 1: Write the tests**

Append inside the class:

```ruby
    test "import rejects a batch whose files and paths lengths differ" do
      post "/mbeditor/import", params: {
        files: [uploaded("a.txt", "a")],
        paths: ["a.txt", "b.txt"],
        on_conflict: "ask"
      }

      assert_response :unprocessable_content
      assert_match(/same length/, json["error"])
    end

    test "import rejects an unknown conflict mode" do
      post "/mbeditor/import", params: {
        files: [uploaded("a.txt", "a")],
        paths: ["a.txt"],
        on_conflict: "clobber"
      }

      assert_response :unprocessable_content
      assert_match(/on_conflict/, json["error"])
      refute File.exist?(File.join(@workspace, "a.txt"))
    end

    # 101 file parts stays under Rack's multipart_part_limit of 128, so the
    # request reaches the action and the guard answers with a real 422. Raising
    # IMPORT_MAX_FILES to 128 or beyond would make this a 500 instead.
    test "import rejects a batch over the file count limit" do
      count = EditorsController::IMPORT_MAX_FILES + 1
      files = Array.new(count) { |i| uploaded("f#{i}.txt", "x") }
      paths = Array.new(count) { |i| "f#{i}.txt" }

      post "/mbeditor/import", params: { files: files, paths: paths, on_conflict: "ask" }

      assert_response :unprocessable_content
      assert_match(/Too many files/, json["error"])
      refute File.exist?(File.join(@workspace, "f0.txt"))
    end

    test "import rejects a batch over the total size limit" do
      # Two files of 30 MB each clear the per-file 5 MB check only because the
      # batch guard runs first — this asserts the batch guard, not the entry one.
      chunk = "x" * (30 * 1024 * 1024)

      post "/mbeditor/import", params: {
        files: [uploaded("big1.bin", chunk), uploaded("big2.bin", chunk)],
        paths: ["big1.bin", "big2.bin"],
        on_conflict: "ask"
      }

      assert_response :unprocessable_content
      assert_match(/too large/i, json["error"])
    end

    test "import rejects an empty batch" do
      post "/mbeditor/import", params: { on_conflict: "ask" }

      assert_response :unprocessable_content
      assert_match(/Nothing to import/, json["error"])
    end
```

- [ ] **Step 2: Run the tests to verify they pass**

```bash
bundle exec rake test TEST=test/controllers/mbeditor/editors_controller_test.rb TESTOPTS="--name=/import/"
```

Expected: PASS, 12 runs, 0 failures.

- [ ] **Step 3: Run the whole suite**

```bash
bundle exec rake test
```

Expected: 0 failures, 0 errors. The count should be the pre-existing 495 tests plus the ones added here.

- [ ] **Step 4: Commit**

```bash
git add test/controllers/mbeditor/editors_controller_test.rb && git commit -m "test: cover import batch limits and validation"
```

---

### Task 6: FileService.importFiles

**Files:**
- Modify: `app/assets/javascripts/mbeditor/file_service.js`

No JS test harness exists in this repo; frontend tasks are verified in the dummy app in Task 11.

- [ ] **Step 1: Add the method**

In `app/assets/javascripts/mbeditor/file_service.js`, add next to `createFile`:

```js
  // Multipart import of files dragged in from outside the browser. The
  // default 30 s axios timeout is too tight for a large drop on a slow disk,
  // so this one call gets a longer leash.
  function importFiles(formData) {
    return axios.post(window.mbeditorBasePath() + '/import', formData, {
      timeout: 120000
    }).then(function (res) { return res.data; });
  }
```

Do not set `Content-Type` by hand — the browser must add the multipart boundary itself.

- [ ] **Step 2: Export it**

In the returned object literal at the bottom of the IIFE, add next to `createFile: createFile,`:

```js
    importFiles: importFiles,
```

- [ ] **Step 3: Commit**

```bash
git add app/assets/javascripts/mbeditor/file_service.js && git commit -m "feat: FileService.importFiles multipart call"
```

---

### Task 7: FileImport — DataTransfer walking

**Files:**
- Create: `app/assets/javascripts/mbeditor/file_import.js`
- Modify: `app/assets/javascripts/mbeditor/application.js`

- [ ] **Step 1: Write the module**

Create `app/assets/javascripts/mbeditor/file_import.js`:

```js
'use strict';

// Turns a drop's DataTransfer into a flat list of { file, relativePath }
// entries and packs them into the multipart body the /import endpoint wants.
//
// Directory drops are walked with webkitGetAsEntry — non-standard, but the
// only way any browser exposes a dropped folder. Where it is missing we fall
// back to dataTransfer.files, which is flat: files import, folders vanish.
var FileImport = (function () {
  // Mirrors EditorsController::IMPORT_MAX_FILES. Trimming client-side means a
  // stray node_modules drop reports a clear message instead of a 422 — and
  // keeps the batch under Rack's 128-file-part multipart limit, which would
  // otherwise reject the request as a 500 before the server guard can run.
  var MAX_ENTRIES = 100;

  function hasExternalFiles(dataTransfer) {
    if (!dataTransfer || !dataTransfer.types) return false;
    return Array.prototype.indexOf.call(dataTransfer.types, 'Files') !== -1;
  }

  // MUST be called synchronously from the drop handler: DataTransferItem
  // objects are neutered the moment the handler returns, so every entry is
  // pulled off the item list up front and only then walked asynchronously.
  function collectEntries(dataTransfer) {
    var items = dataTransfer.items;
    var roots = [];
    var supportsEntries = typeof DataTransferItem !== 'undefined' &&
      DataTransferItem.prototype.webkitGetAsEntry;

    if (items && items.length && supportsEntries) {
      for (var i = 0; i < items.length; i++) {
        if (items[i].kind !== 'file') continue;
        var entry = items[i].webkitGetAsEntry();
        if (entry) roots.push(entry);
      }
    }

    if (roots.length === 0) {
      var flat = [];
      var files = dataTransfer.files || [];
      for (var j = 0; j < files.length; j++) {
        flat.push({ file: files[j], relativePath: files[j].name });
      }
      return Promise.resolve({
        entries: flat.slice(0, MAX_ENTRIES),
        truncated: flat.length > MAX_ENTRIES,
        foldersSkipped: !!(items && items.length > flat.length)
      });
    }

    var collected = [];
    return walkAll(roots, collected).then(function () {
      return {
        entries: collected.slice(0, MAX_ENTRIES),
        truncated: collected.length > MAX_ENTRIES,
        foldersSkipped: false
      };
    });
  }

  function walkAll(entries, out) {
    return entries.reduce(function (chain, entry) {
      return chain.then(function () { return walk(entry, out); });
    }, Promise.resolve());
  }

  function walk(entry, out) {
    if (entry.isFile) {
      return new Promise(function (resolve) {
        entry.file(function (file) {
          out.push({ file: file, relativePath: stripLeadingSlash(entry.fullPath) });
          resolve();
        }, function () { resolve(); });
      });
    }
    if (!entry.isDirectory) return Promise.resolve();

    var reader = entry.createReader();
    // readEntries hands back at most ~100 children per call and signals the
    // end of the directory with an empty batch, so it has to be called until
    // it runs dry rather than once.
    var readBatch = function () {
      return new Promise(function (resolve) {
        reader.readEntries(function (batch) { resolve(batch); }, function () { resolve([]); });
      }).then(function (batch) {
        if (!batch || batch.length === 0) return null;
        return walkAll(batch, out).then(readBatch);
      });
    };
    return readBatch();
  }

  function stripLeadingSlash(p) {
    return String(p || '').replace(/^\/+/, '');
  }

  // '' as the folder means the workspace root.
  function joinPath(folder, relativePath) {
    var rel = stripLeadingSlash(relativePath);
    if (!folder) return rel;
    return folder.replace(/\/+$/, '') + '/' + rel;
  }

  function buildFormData(entries, targetFolderPath, onConflict) {
    var fd = new FormData();
    fd.append('on_conflict', onConflict);
    entries.forEach(function (e) {
      fd.append('files[]', e.file, e.file.name);
      fd.append('paths[]', joinPath(targetFolderPath, e.relativePath));
    });
    return fd;
  }

  return {
    MAX_ENTRIES: MAX_ENTRIES,
    hasExternalFiles: hasExternalFiles,
    collectEntries: collectEntries,
    joinPath: joinPath,
    buildFormData: buildFormData
  };
})();

// Expose globally for sprockets require
window.FileImport = FileImport;
```

- [ ] **Step 2: Register it with Sprockets**

In `app/assets/javascripts/mbeditor/application.js`, add after the `file_service` line:

```js
//= require mbeditor/file_import
```

- [ ] **Step 3: Verify the asset compiles**

```bash
cd test/dummy && bin/rails runner 'puts Rails.application.assets["mbeditor/application.js"].to_s.include?("FileImport") ? "OK" : "MISSING"'
```

Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
git add app/assets/javascripts/mbeditor/file_import.js app/assets/javascripts/mbeditor/application.js && git commit -m "feat: FileImport module for walking dropped directories"
```

---

### Task 8: FileTree — accept external drops

**Files:**
- Modify: `app/assets/javascripts/mbeditor/components/FileTree.js`
- Modify: `app/assets/stylesheets/mbeditor/editor.css`

- [ ] **Step 1: Add the prop and state**

In `app/assets/javascripts/mbeditor/components/FileTree.js`, add after the `onMove` prop line (~line 30):

```js
  var onImportFiles = _ref.onImportFiles; // fn(entries[], destFolderPath, meta) — external file drop
```

Add after the `dragOverFolder` state block (~line 54):

```js
  // Target of an in-flight *external* drag: a folder path, '' for the tree
  // root, or null when no external drag is over the tree. Kept separate from
  // dragOverFolder so the two drop kinds highlight differently.
  var _useStateExt = useState(null);
  var _useStateExt2 = _slicedToArray(_useStateExt, 2);
  var externalDragOver = _useStateExt2[0];
  var setExternalDragOver = _useStateExt2[1];
```

- [ ] **Step 2: Add the shared drop starter**

Add just above `var renderRow = ...` (search for `var renderRow`):

```js
  // collectEntries must be kicked off synchronously inside the drop handler —
  // see the note in file_import.js.
  var startExternalImport = function(dataTransfer, targetFolderPath) {
    if (!onImportFiles) return;
    FileImport.collectEntries(dataTransfer).then(function(res) {
      if (res.entries.length > 0) onImportFiles(res.entries, targetFolderPath, res);
    });
  };

  var isRowTarget = function(e) {
    return !!(e.target && e.target.closest && e.target.closest('.tree-item'));
  };
```

- [ ] **Step 3: Extend the row handlers**

Replace the `onDragOver`, `onDragLeave`, `onDrop`, and `onDragEnd` handlers in `renderRow` (currently at `app/assets/javascripts/mbeditor/components/FileTree.js:473-493`) with:

```js
            onDragOver: function(e) {
              if (!isFolder) return; // file rows accept neither kind of drop
              var external = FileImport.hasExternalFiles(e.dataTransfer);
              e.preventDefault();
              e.stopPropagation();
              e.dataTransfer.dropEffect = external ? 'copy' : 'move';
              if (external) {
                if (externalDragOver !== node.path) setExternalDragOver(node.path);
                if (dragOverFolder !== null) setDragOverFolder(null);
              } else if (dragOverFolder !== node.path) {
                setDragOverFolder(node.path);
              }
            },
            onDragLeave: function() {
              if (dragOverFolder === node.path) setDragOverFolder(null);
              if (externalDragOver === node.path) setExternalDragOver(null);
            },
            onDrop: function(e) {
              e.preventDefault();
              e.stopPropagation();
              setDragOverFolder(null);
              setExternalDragOver(null);
              if (!isFolder) return;
              if (FileImport.hasExternalFiles(e.dataTransfer)) {
                startExternalImport(e.dataTransfer, node.path);
                return;
              }
              try {
                var srcPaths = JSON.parse(e.dataTransfer.getData('text/plain'));
                if (onMove && srcPaths && srcPaths.length > 0) onMove(srcPaths, node.path);
              } catch (err) {}
            },
            onDragEnd: function() { setDragOverFolder(null); setExternalDragOver(null); },
```

- [ ] **Step 4: Add the external highlight class**

In `renderRow`, replace the `isDragOver` line (currently `app/assets/javascripts/mbeditor/components/FileTree.js:441`) with:

```js
    var isDragOver = isFolder && dragOverFolder === node.path;
    var isDragOverExternal = isFolder && externalDragOver === node.path;
```

Then extend the `classNames` chain just below it. The chain currently ends with
`(isDragOver ? ' drag-over' : '');` — replace that final line with:

```js
      (isDragOver ? ' drag-over' : '') +
      (isDragOverExternal ? ' drag-over-external' : '');
```

- [ ] **Step 5: Make the root container a drop zone**

Replace the container element in the component's return (currently `app/assets/javascripts/mbeditor/components/FileTree.js:569-577`) with:

```js
  return React.createElement(
    'div',
    {
      className: 'file-tree file-tree-root' + (externalDragOver === '' ? ' drag-over-external-root' : ''),
      ref: containerRef,
      tabIndex: 0,
      style: { outline: 'none', padding: 0 },
      // Empty space below the last row imports into the workspace root.
      // Folder rows stop propagation, so only genuine misses reach here; the
      // isRowTarget guard covers file rows, which accept nothing.
      onDragOver: function(e) {
        if (!FileImport.hasExternalFiles(e.dataTransfer) || isRowTarget(e)) return;
        e.preventDefault();
        e.dataTransfer.dropEffect = 'copy';
        if (externalDragOver !== '') setExternalDragOver('');
      },
      onDragLeave: function(e) {
        if (e.currentTarget.contains(e.relatedTarget)) return;
        setExternalDragOver(null);
      },
      onDrop: function(e) {
        if (!FileImport.hasExternalFiles(e.dataTransfer)) return;
        setExternalDragOver(null);
        if (isRowTarget(e)) return;
        e.preventDefault();
        startExternalImport(e.dataTransfer, '');
      }
    },
    React.createElement(
      'div',
      { style: { height: totalHeight, position: 'relative' } },
      visibleRows
    )
  );
```

- [ ] **Step 6: Add the styles**

In `app/assets/stylesheets/mbeditor/editor.css`, add immediately after the existing `.tree-item.drag-over` rule (`app/assets/stylesheets/mbeditor/editor.css:249`):

```css
/* External file drop (import) — green, to read as "add" rather than "move" */
.tree-item.drag-over-external { background: rgba(120, 200, 140, 0.22); box-shadow: inset 0 0 0 1px rgba(120, 200, 140, 0.75); }
.file-tree-root.drag-over-external-root { box-shadow: inset 0 0 0 2px rgba(120, 200, 140, 0.6); }
```

- [ ] **Step 7: Commit**

```bash
git add app/assets/javascripts/mbeditor/components/FileTree.js app/assets/stylesheets/mbeditor/editor.css && git commit -m "feat: accept external file drops in the file tree"
```

---

### Task 9: The import conflict modal

**Files:**
- Create: `app/assets/javascripts/mbeditor/components/ImportConflictModal.js`
- Modify: `app/assets/javascripts/mbeditor/application.js`
- Modify: `app/assets/stylesheets/mbeditor/editor.css`

- [ ] **Step 1: Write the component**

Create `app/assets/javascripts/mbeditor/components/ImportConflictModal.js`:

```js
'use strict';

// Shown when an external import lands on paths that already exist. Offers
// batch-level resolutions only — per-file toggles were left out deliberately
// so the three-way choice stays legible. Escape and click-outside both mean
// skip, which is the non-destructive option.
//
// Errors from the same pass render here too, so a drop that both conflicts
// and fails needs one dialog rather than two.
var ImportConflictModal = function ImportConflictModal(_ref) {
  var conflicts = _ref.conflicts || [];
  var errors = _ref.errors || [];
  var onResolve = _ref.onResolve;

  React.useEffect(function () {
    var onKey = function (e) {
      if (e.key !== 'Escape') return;
      e.preventDefault();
      e.stopPropagation();
      onResolve('skip');
    };
    document.addEventListener('keydown', onKey, true);
    return function () { document.removeEventListener('keydown', onKey, true); };
  }, [onResolve]);

  var button = function (label, mode, className) {
    return React.createElement(
      'button',
      { className: className, onClick: function () { onResolve(mode); } },
      label
    );
  };

  return React.createElement(
    'div',
    {
      className: 'schema-modal-overlay',
      onClick: function () { onResolve('skip'); }
    },
    React.createElement(
      'div',
      {
        className: 'schema-modal import-conflict-modal',
        role: 'dialog',
        'aria-modal': 'true',
        onClick: function (e) { e.stopPropagation(); }
      },
      React.createElement(
        'div', { className: 'schema-modal-header' },
        React.createElement(
          'div', { className: 'schema-modal-title' },
          conflicts.length + ' file' + (conflicts.length === 1 ? '' : 's') + ' already exist' +
            (conflicts.length === 1 ? 's' : '')
        )
      ),
      React.createElement(
        'div', { className: 'schema-modal-body' },
        React.createElement(
          'ul', { className: 'import-conflict-list' },
          conflicts.map(function (c) {
            return React.createElement('li', { key: c.path, title: c.path }, c.path);
          })
        ),
        errors.length > 0 && React.createElement(
          'div', { className: 'import-conflict-errors' },
          React.createElement('div', { className: 'import-conflict-errors-title' },
            errors.length + ' file' + (errors.length === 1 ? '' : 's') + ' could not be imported'),
          React.createElement(
            'ul', { className: 'import-conflict-list' },
            errors.map(function (e) {
              return React.createElement('li', { key: e.path, title: e.path },
                e.path + ' — ' + e.error);
            })
          )
        )
      ),
      React.createElement(
        'div', { className: 'import-conflict-actions' },
        button('Skip', 'skip', 'import-conflict-btn'),
        button('Keep both', 'rename', 'import-conflict-btn'),
        button('Overwrite all', 'overwrite', 'import-conflict-btn import-conflict-btn-danger')
      )
    )
  );
};

// Expose globally for sprockets require
window.ImportConflictModal = ImportConflictModal;
```

- [ ] **Step 2: Register it with Sprockets**

In `app/assets/javascripts/mbeditor/application.js`, add after the `components/GitPanel` line (it must come before `components/MbeditorApp`):

```js
//= require mbeditor/components/ImportConflictModal
```

- [ ] **Step 3: Add the styles**

In `app/assets/stylesheets/mbeditor/editor.css`, add after the existing schema-modal rules (search for `.schema-modal-body`, add below that block):

```css
/* Import conflict modal — reuses the schema-modal shell */
.import-conflict-modal { min-width: 380px; }
.import-conflict-list {
  list-style: none;
  margin: 0;
  padding: 0;
  max-height: 240px;
  overflow-y: auto;
  font-family: var(--ide-mono-font, monospace);
  font-size: 12px;
}
.import-conflict-list li {
  padding: 3px 0;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.import-conflict-errors {
  margin-top: 12px;
  padding-top: 12px;
  border-top: 1px solid var(--ide-border, #3c3c3c);
  color: var(--ide-error, #f48771);
}
.import-conflict-errors-title { font-size: 12px; margin-bottom: 4px; }
.import-conflict-actions {
  display: flex;
  justify-content: flex-end;
  gap: 8px;
  padding: 12px 16px;
  border-top: 1px solid var(--ide-border, #3c3c3c);
  flex-shrink: 0;
}
.import-conflict-btn {
  background: var(--ide-input-bg, #3c3c3c);
  color: var(--ide-fg, #d4d4d4);
  border: 1px solid var(--ide-border, #3c3c3c);
  border-radius: 3px;
  padding: 5px 12px;
  font-size: 12px;
  cursor: pointer;
}
.import-conflict-btn:hover { background: var(--ide-hover-bg, #4a4a4a); }
.import-conflict-btn-danger { border-color: var(--ide-error, #f48771); color: var(--ide-error, #f48771); }
```

Before committing, confirm the CSS variables used here (`--ide-mono-font`, `--ide-input-bg`, `--ide-hover-bg`, `--ide-error`) exist in `app/assets/stylesheets/mbeditor/themes.css`:

```bash
grep -c -- "--ide-error\|--ide-input-bg\|--ide-hover-bg\|--ide-mono-font" app/assets/stylesheets/mbeditor/themes.css
```

Expected: a non-zero count. Any variable that is missing still works via the fallback after the comma, but prefer swapping in a variable that does exist.

- [ ] **Step 4: Commit**

```bash
git add app/assets/javascripts/mbeditor/components/ImportConflictModal.js app/assets/javascripts/mbeditor/application.js app/assets/stylesheets/mbeditor/editor.css && git commit -m "feat: import conflict modal"
```

---

### Task 10: Wire the two-pass import into MbeditorApp

**Files:**
- Modify: `app/assets/javascripts/mbeditor/components/MbeditorApp.js`

- [ ] **Step 1: Add modal state**

Add next to the existing `schemaModal` state block (`app/assets/javascripts/mbeditor/components/MbeditorApp.js:354-357`):

```js
  var _useStateImportConflict = useState(null);
  var _useStateImportConflict2 = _slicedToArray(_useStateImportConflict, 2);
  var importConflict = _useStateImportConflict2[0];
  var setImportConflict = _useStateImportConflict2[1];
```

- [ ] **Step 2: Add the handlers**

Add immediately after `handleMoveNodes` (which ends at `app/assets/javascripts/mbeditor/components/MbeditorApp.js:2830`):

```js
  var finishImport = function finishImport(result) {
    var imported = (result.imported || []).length;
    var skipped  = (result.conflicts || []).length;
    var failed   = (result.errors || []).length;

    var parts = [imported + ' file' + (imported === 1 ? '' : 's') + ' imported'];
    if (skipped > 0) parts.push(skipped + ' skipped');
    if (failed > 0) parts.push(failed + ' failed');

    var level = failed === 0 ? 'success' : (imported === 0 ? 'error' : 'warning');
    EditorStore.setStatus(parts.join(', ') + '.', level);

    if (imported > 0) {
      refreshProjectTree().then(function() { GitService.fetchStatus(); });
    }
  };

  // Files dragged in from outside the browser. Pass one reports conflicts
  // without touching them; if there are any, the modal collects a resolution
  // and pass two re-sends just those entries.
  var handleImportFiles = function handleImportFiles(entries, targetFolderPath, meta) {
    if (meta && meta.truncated) {
      EditorStore.setStatus('That drop holds more than ' + FileImport.MAX_ENTRIES +
        ' files — only the first ' + FileImport.MAX_ENTRIES + ' will be imported.', 'warning');
    } else if (meta && meta.foldersSkipped) {
      EditorStore.setStatus('This browser cannot read dropped folders — only loose files were imported.', 'warning');
    } else {
      EditorStore.setStatus('Importing ' + entries.length + ' file' +
        (entries.length === 1 ? '' : 's') + '...', 'info');
    }

    return FileService.importFiles(FileImport.buildFormData(entries, targetFolderPath, 'ask'))
      .then(function(result) {
        if (result.conflicts && result.conflicts.length > 0) {
          setImportConflict({ result: result, entries: entries, targetFolderPath: targetFolderPath });
        } else {
          finishImport(result);
        }
      })['catch'](function(err) {
        var message = err && err.response && err.response.data && err.response.data.error || err.message;
        EditorStore.setStatus('Import failed: ' + message, 'error');
      });
  };

  var resolveImportConflict = function resolveImportConflict(mode) {
    var pending = importConflict;
    setImportConflict(null);
    if (!pending) return;

    if (mode === 'skip') { finishImport(pending.result); return; }

    var conflicted = {};
    pending.result.conflicts.forEach(function(c) { conflicted[c.path] = true; });
    var retry = pending.entries.filter(function(e) {
      return conflicted[FileImport.joinPath(pending.targetFolderPath, e.relativePath)];
    });
    if (retry.length === 0) { finishImport(pending.result); return; }

    FileService.importFiles(FileImport.buildFormData(retry, pending.targetFolderPath, mode))
      .then(function(second) {
        finishImport({
          imported: (pending.result.imported || []).concat(second.imported || []),
          conflicts: [],
          errors: (pending.result.errors || []).concat(second.errors || [])
        });
      })['catch'](function(err) {
        var message = err && err.response && err.response.data && err.response.data.error || err.message;
        EditorStore.setStatus('Import failed: ' + message, 'error');
      });
  };
```

- [ ] **Step 3: Pass the handler to FileTree**

In the `React.createElement(FileTree, {...})` call, add after the `onMove: handleMoveNodes,` line (`app/assets/javascripts/mbeditor/components/MbeditorApp.js:3750`):

```js
              onImportFiles: handleImportFiles,
```

Note: `FileTreeMemo`'s comparator deliberately ignores function props, so `FileTree` may hold a closure from an earlier render. `handleImportFiles` only reaches for `FileService`, `FileImport`, `EditorStore`, and `setImportConflict` — all stable across renders — so the staleness is harmless, exactly as it already is for `onMove`.

- [ ] **Step 4: Render the modal**

Add just before the schema modal block (search for `/* ── Schema modal ──`):

```js
    /* ── Import conflict modal ─────────────────────────────────────────── */
    importConflict && React.createElement(ImportConflictModal, {
      conflicts: importConflict.result.conflicts,
      errors: importConflict.result.errors,
      onResolve: resolveImportConflict
    }),
```

- [ ] **Step 5: Verify the assets compile**

```bash
cd test/dummy && bin/rails runner 'a = Rails.application.assets["mbeditor/application.js"].to_s; puts(a.include?("handleImportFiles") && a.include?("ImportConflictModal") ? "OK" : "MISSING")'
```

Expected: `OK`.

- [ ] **Step 6: Commit**

```bash
git add app/assets/javascripts/mbeditor/components/MbeditorApp.js && git commit -m "feat: wire two-pass external file import into the editor"
```

---

### Task 11: Manual verification and docs

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Run the full suite**

```bash
bundle exec rake test
```

Expected: 0 failures, 0 errors.

- [ ] **Step 2: Boot the dummy app**

```bash
cd test/dummy && rails server
```

Open `http://localhost:3000/mbeditor`.

- [ ] **Step 3: Walk the manual checklist**

Record the actual result of each. Every one must pass before the feature is called done.

1. Drag one text file onto a folder row → the row highlights green, the file appears inside that folder, status reads `1 file imported.`
2. Drag one PNG onto a folder row → the file appears; open it in the editor and confirm the image renders (not mojibake).
3. Drag three files at once → all three appear, status reads `3 files imported.`
4. Drag a folder containing a nested subfolder → the directory structure is recreated under the target.
5. Drag a file onto the empty space below the last tree row → it lands at the workspace root.
6. Drag a file onto a *file* row → nothing is imported, no highlight appears.
7. Re-drag a file that already exists → the modal appears listing it. Press **Skip** → nothing changes on disk.
8. Repeat, press **Keep both** → a `name 2.ext` sibling appears alongside the original.
9. Repeat, press **Overwrite all** → the original's content is replaced.
10. Repeat, press Escape → same as Skip, nothing changes.
11. Drag a file larger than 5 MB → it does not import and the status/modal reports the size limit.
12. Drag an *internal* tree node onto a folder (the pre-existing move) → still moves, and the highlight is the original blue, not green.
13. Open a second browser tab on the editor, import in the first → the second tab's tree picks up the new file.

- [ ] **Step 4: Add the changelog entry**

In `CHANGELOG.md`, add an `## [Unreleased]` section directly below the intro paragraph and above `## [0.8.1] - 2026-07-22`:

```markdown
## [Unreleased]

### Added
- **Drag files and folders from your desktop straight into the explorer.**
  Drop onto a folder row to import there, or onto the empty space below the
  tree to import into the workspace root. Folders are imported recursively.
  Any file type works — binary content round-trips byte for byte. When a
  target path already exists, a dialog offers Overwrite all, Keep both (which
  writes `name 2.ext` beside the original), or Skip. Imports are capped at 100
  files and 50 MB per drop, and 5 MB per file, and every target path goes
  through the same sandbox checks as every other file operation.
```

- [ ] **Step 5: Document the new service**

In `CLAUDE.md`, add to the "Key services" bullet list, after the `FileOperationService` line:

```markdown
- `FileImportService` — writes files dropped in from outside the browser; owns the ask/overwrite/rename conflict protocol
```

- [ ] **Step 6: Commit**

```bash
git add CHANGELOG.md CLAUDE.md && git commit -m "docs: changelog and service notes for drag-and-drop import"
```

---

## Done When

- `bundle exec rake test` is green.
- Every item on the Task 11 manual checklist passes.
- Dragging a file, several files, or a folder into the explorer imports it, and a colliding path prompts before anything is overwritten.
