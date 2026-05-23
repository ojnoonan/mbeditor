# frozen_string_literal: true

require "fileutils"
require "open3"
require "shellwords"
require "tempfile"
require "timeout"
require "tmpdir"

module Mbeditor
  class EditorsController < ApplicationController
    skip_before_action :verify_authenticity_token
    before_action :ensure_allowed_environment!
    before_action :verify_mbeditor_client, unless: -> { request.get? || request.head? }

    IMAGE_EXTENSIONS = %w[png jpg jpeg gif svg ico webp bmp avif].freeze

    # GET /mbeditor — renders the IDE shell
    def index
      render layout: "mbeditor/application"
    end

    # GET /mbeditor/ping — heartbeat for the frontend connectivity check
    # Silence the log line so development consoles are not spammed.
    def ping
      Rails.logger.silence { render json: { ok: true } }
    end

    # GET /mbeditor/workspace — metadata about current workspace root
    def workspace
      render json: {
        rootName: workspace_root.basename.to_s,
        rootPath: workspace_root.to_s,
        rubocopAvailable: AvailabilityProbe.rubocop(workspace_root),
        rubocopConfigPath: rubocop_config_path,
        hamlLintAvailable: AvailabilityProbe.haml_lint(workspace_root),
        gitAvailable: AvailabilityProbe.git(workspace_root),
        blameAvailable: AvailabilityProbe.git(workspace_root),
        redmineEnabled: Mbeditor.configuration.redmine_enabled == true,
        testAvailable: test_available?,
        actionCableEnabled: action_cable_enabled?
      }
    end

    # GET /mbeditor/files — recursive file tree
    def files
      render json: FileTreeService.build(workspace_root)
    end

    # GET /mbeditor/state — load workspace state
    def state
      render json: editor_state_service.read_state
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    STATE_MAX_BYTES = EditorStateService::STATE_MAX_BYTES

    # POST /mbeditor/state — save workspace state
    def save_state
      raw = params[:state]
      raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
      editor_state_service.write_state(raw)
      render json: { ok: true }
    rescue EditorStateService::PayloadTooLargeError
      render json: { error: "State payload too large" }, status: :content_too_large
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    # GET /mbeditor/branch_state?branch=... — load per-branch pane state
    def branch_state
      branch = sanitize_branch_name(params[:branch])
      return render json: {}, status: :bad_request unless branch

      render json: editor_state_service.read_branch_state(branch)
    rescue StandardError
      render json: {}
    end
    def save_branch_state
      branch = sanitize_branch_name(params[:branch])
      return render json: { error: "Invalid branch name" }, status: :bad_request unless branch

      payload = params[:state].to_unsafe_h
      editor_state_service.write_branch_state(branch, payload)
      render json: { ok: true }
    rescue EditorStateService::PayloadTooLargeError
      render json: { error: "State payload too large" }, status: :content_too_large
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    # POST /mbeditor/prune_branch_states — remove states for deleted branches
    def prune_branch_states
      root = workspace_root.to_s
      out, _err, status = Open3.capture3("git", "-C", root, "branch", "--format=%(refname:short)")
      return render json: { pruned: [] } unless status.success?

      local_branches = out.split("\n").map(&:strip).reject(&:empty?)
      pruned = editor_state_service.prune_branch_states(active_branches: local_branches)
      render json: { pruned: pruned }
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    # GET /mbeditor/file?path=...
    def show
      path = resolve_path(params[:path])
      return render json: { error: "Forbidden" }, status: :forbidden unless path

      unless File.file?(path)
        return render json: missing_file_payload(params[:path]) if allow_missing_file?

        return render json: { error: "Not found" }, status: :not_found
      end

      start_line = params[:start_line] ? params[:start_line].to_i : nil
      line_count  = params.key?(:line_count) ? params[:line_count].to_i : 500
      line_count  = [line_count, 5000].min

      if start_line
        total_bytes = File.size(path)
        chunk = []
        total_lines = 0
        File.foreach(path, encoding: "UTF-8", invalid: :replace, undef: :replace) do |line|
          chunk << line if total_lines >= start_line && chunk.length < line_count
          total_lines += 1
        end
        return render json: {
          path:        relative_path(path),
          content:     chunk.join,
          truncated:   total_lines > start_line + chunk.length,
          start_line:  start_line,
          line_count:  chunk.length,
          total_lines: total_lines,
          total_bytes: total_bytes
        }
      end

      size = File.size(path)
      return render_file_too_large(size) if size > FileOperationService::MAX_FILE_SIZE_BYTES

      if image_path?(path)
        return render json: {
          path: relative_path(path),
          image: true,
          size: size,
          content: ""
        }
      end

      stat = File.stat(path)
      etag = "#{stat.mtime.to_i}-#{stat.size}"

      if stale?(etag: etag, public: false)
        content = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace)
        render json: { path: relative_path(path), content: content }
      end
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    # GET /mbeditor/raw?path=... — send raw file directly (for images)
    def raw
      path = resolve_path(params[:path])
      return render json: { error: "Forbidden" }, status: :forbidden unless path
      return render json: { error: "Not found" }, status: :not_found unless File.file?(path)

      size = File.size(path)
      return render_file_too_large(size) if size > FileOperationService::MAX_FILE_SIZE_BYTES

      send_file path, disposition: "inline"
    end

    # POST /mbeditor/file — save file
    def save
      path = resolve_path(params[:path])
      return render json: { error: "Forbidden" }, status: :forbidden unless path
      return render json: { error: "Cannot write to this path" }, status: :forbidden if path_blocked_for_operations?(path)

      result = FileOperationService.new(workspace_root).save(path, params[:code].to_s)
      broadcast_files_changed
      render json: result
    rescue FileOperationService::FileTooLargeError
      render_file_too_large(params[:code].to_s.bytesize)
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    # POST /mbeditor/create_file — create file and parent directories if needed
    def create_file
      path = resolve_path(params[:path])
      return render json: { error: "Forbidden" }, status: :forbidden unless path
      return render json: { error: "Cannot create file in this path" }, status: :forbidden if path_blocked_for_operations?(path)

      result = FileOperationService.new(workspace_root).create_file(path, params[:code].to_s)
      broadcast_files_changed
      render json: result
    rescue FileOperationService::FileExistsError
      render json: { error: "File already exists" }, status: :unprocessable_content
    rescue FileOperationService::FileTooLargeError
      render_file_too_large(params[:code].to_s.bytesize)
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    # POST /mbeditor/create_dir — create directory recursively
    def create_dir
      path = resolve_path(params[:path])
      return render json: { error: "Forbidden" }, status: :forbidden unless path
      return render json: { error: "Cannot create directory in this path" }, status: :forbidden if path_blocked_for_operations?(path)

      result = FileOperationService.new(workspace_root).create_dir(path)
      broadcast_files_changed
      render json: result
    rescue FileOperationService::FileExistsError
      render json: { error: "Path already exists" }, status: :unprocessable_content
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    # PATCH /mbeditor/rename — rename file or directory
    def rename
      old_path = resolve_path(params[:path])
      new_path = resolve_path(params[:new_path])
      return render json: { error: "Forbidden" }, status: :forbidden unless old_path && new_path
      return render json: { error: "Cannot rename this path" }, status: :forbidden if path_blocked_for_operations?(old_path) || path_blocked_for_operations?(new_path)

      result = FileOperationService.new(workspace_root).rename(old_path, new_path)
      broadcast_files_changed
      render json: result
    rescue FileOperationService::PathNotFoundError
      render json: { error: "Path not found" }, status: :not_found
    rescue FileOperationService::TargetExistsError
      render json: { error: "Target path already exists" }, status: :unprocessable_content
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    # DELETE /mbeditor/delete — remove file or directory
    def destroy_path
      path = resolve_path(params[:path])
      return render json: { error: "Forbidden" }, status: :forbidden unless path
      return render json: { error: "Cannot delete this path" }, status: :forbidden if File.exist?(path) && path_blocked_for_operations?(path)

      result = FileOperationService.new(workspace_root).destroy_path(path)
      broadcast_files_changed if result.key?(:type)
      render json: result
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    # GET /mbeditor/definition?symbol=...&language=...
    # Looks up method definitions in workspace source files (Ripper) and in the
    # Ruby/gem documentation via +ri+. Workspace results appear first.
    def definition
      symbol = params[:symbol].to_s.strip
      language = params[:language].to_s.strip

      return render json: { results: [] } if symbol.blank?
      return render json: { error: "Invalid symbol" }, status: :bad_request unless symbol.match?(/\A[a-zA-Z_]\w{0,59}[!?]?\z/)

      results = case language
                when "ruby"
                  excl_patterns = Array(Mbeditor.configuration.excluded_paths).map(&:to_s).reject(&:blank?)
                  workspace = RubyDefinitionService.call(
                    workspace_root,
                    symbol,
                    excluded_paths: excl_patterns,
                    included_dirs:  ruby_def_include_dirs
                  )
                  ri = RiDefinitionService.call(symbol)
                  workspace + ri
                else
                  []
                end

      render json: { results: results }
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    # GET /mbeditor/js_definition?symbol=ReactWindow
    # Searches workspace JS/JSX/TS/TSX files for global definitions of the named symbol.
    def js_definition
      symbol = params[:symbol].to_s.strip
      return render json: { results: [] } if symbol.blank?
      return render json: { error: "Invalid symbol" }, status: :bad_request \
        unless symbol.match?(/\A[a-zA-Z_$][a-zA-Z0-9_$]{0,59}\z/)

      results = JsDefinitionService.new(symbol, workspace_root).call
      render json: { results: results }
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    # GET /mbeditor/js_members?symbol=ReactWindow
    # Searches workspace JS/JSX/TS/TSX files for properties/methods of the named global.
    def js_members
      symbol = params[:symbol].to_s.strip
      return render json: { members: [] } if symbol.blank?
      return render json: { error: "Invalid symbol" }, status: :bad_request \
        unless symbol.match?(/\A[a-zA-Z_$][a-zA-Z0-9_$]{0,59}\z/)

      members = JsMembersService.new(symbol, workspace_root).call
      render json: { symbol: symbol, members: members }
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    # GET /mbeditor/module_members?name=ArticlesHelper
    # Returns methods defined in the workspace file that defines the named module/class.
    def module_members
      name = params[:name].to_s.strip
      return render json: { error: "Invalid name" }, status: :bad_request \
        unless name.match?(/\A[A-Z][a-zA-Z0-9_]*\z/)

      excl_patterns = Array(Mbeditor.configuration.excluded_paths).map(&:to_s).reject(&:blank?)
      file = RubyDefinitionService.module_defined_in(
        workspace_root, name,
        excluded_paths: excl_patterns,
        included_dirs:  ruby_def_include_dirs
      )
      return render json: { name: name, methods: [] } unless file

      defs    = RubyDefinitionService.defs_in_file(file)
      methods = defs.flat_map do |method_name, entries|
        entries.map { |e| { name: method_name, line: e[:line], signature: e[:signature], file: relative_path(file) } }
      end
      render json: { name: name, file: relative_path(file), methods: methods }
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    # GET /mbeditor/file_includes?path=app/models/article.rb
    # Returns included/extended/prepended module names and their methods.
    def file_includes
      path = resolve_path(params[:path])
      return render json: { error: "Forbidden" }, status: :forbidden unless path

      excl_patterns = Array(Mbeditor.configuration.excluded_paths).map(&:to_s).reject(&:blank?)
      module_names = RubyDefinitionService.includes_in_file(path)
      includes = module_names.filter_map do |mod_name|
        mod_file = RubyDefinitionService.module_defined_in(
          workspace_root, mod_name,
          excluded_paths: excl_patterns,
          included_dirs:  ruby_def_include_dirs
        )
        next unless mod_file

        defs    = RubyDefinitionService.defs_in_file(mod_file)
        methods = defs.flat_map do |method_name, entries|
          entries.map { |e| { name: method_name, line: e[:line], signature: e[:signature] } }
        end
        { name: mod_name, file: relative_path(mod_file), methods: methods }
      end
      render json: { includes: includes }
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    # GET /mbeditor/unused_methods?path=app/models/article.rb
    # Returns method names defined in the file that have no call-sites in the workspace.
    def unused_methods
      path = resolve_path(params[:path])
      return render json: { error: "Forbidden" }, status: :forbidden unless path

      excl_patterns = Array(Mbeditor.configuration.excluded_paths).map(&:to_s).reject(&:blank?)
      unused = UnusedMethodsService.call(
        workspace_root, path,
        excluded_paths: excl_patterns
      )
      render json: { unused: unused }
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    # GET /mbeditor/search?q=...&offset=0&limit=50&regex=false&match_case=false&whole_word=false
    def search
      query      = params[:q].to_s.strip
      offset     = [params[:offset].to_i, 0].max
      limit      = [[params[:limit].to_i > 0 ? params[:limit].to_i : 50, 200].min, 1].max
      use_regex  = params[:regex] == 'true'
      match_case = params[:match_case] == 'true'
      whole_word = params[:whole_word] == 'true'
      needed     = offset + limit + 1   # collect one extra to detect has_more

      return render json: [] if query.blank?
      return render json: { error: "Query too long" }, status: :bad_request if query.length > 500

      # On first page, count total matches in parallel with fetching results.
      count_thread = offset == 0 ? Thread.new { SearchReplaceService.count(workspace_root, query, use_regex: use_regex, match_case: match_case, whole_word: whole_word, excluded_paths: Mbeditor.configuration.excluded_paths) } : nil

      results   = SearchReplaceService.search(workspace_root, query, limit: needed, use_regex: use_regex, match_case: match_case, whole_word: whole_word, excluded_paths: Mbeditor.configuration.excluded_paths)
      has_more  = results.length > offset + limit
      response  = { results: results[offset, limit] || [], has_more: has_more }
      if count_thread
        # Give the count thread up to 100 ms; omit total_count when it hasn't finished yet
        # so the first page is never blocked by the counting subprocess.
        count_thread.join(0.1)
        response[:total_count] = count_thread.value unless count_thread.alive?
      end

      render json: response
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    # POST /mbeditor/replace_in_files
    # Replaces a string/pattern across all matching files in the workspace.
    # Returns { replaced_count:, files_affected:[], errors:[], partial: }
    def replace_in_files
      query       = params[:query].to_s.strip
      replacement = params[:replacement].to_s
      use_regex   = params[:regex] == 'true'
      match_case  = params[:match_case] == 'true'
      whole_word  = params[:whole_word] == 'true'

      return render json: { error: "Query is required" }, status: :bad_request if query.blank?
      return render json: { error: "Query too long" }, status: :bad_request if query.length > 500

      result = SearchReplaceService.replace(
        workspace_root, query, replacement,
        use_regex: use_regex, match_case: match_case, whole_word: whole_word,
        excluded_paths: Mbeditor.configuration.excluded_paths
      )

      if result.key?(:error)
        render json: { error: result[:error] }, status: :unprocessable_entity
      else
        render json: result
      end
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    # GET /mbeditor/git_status
    def git_status
      output, _err, status = Open3.capture3("git", "-C", workspace_root.to_s, "status", "--porcelain")
      branch = GitService.current_branch(workspace_root.to_s) || ""
      files = GitService.parse_porcelain_status(output)
      render json: { ok: status.success?, files: files, branch: branch }
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    # GET /mbeditor/git_info
    def git_info
      render json: GitInfoService.call(workspace_root.to_s)
    end

    # GET /mbeditor/monaco-editor/*asset_path — serve packaged Monaco files
    def monaco_asset
      # path_info is the path within the engine, e.g. "/monaco-editor/vs/loader.js"
      relative = request.path_info.delete_prefix("/")
      path = resolve_monaco_asset_path(relative)
      return head :not_found unless path

      send_file path, disposition: "inline", type: Mime::Type.lookup_by_extension(File.extname(path).delete_prefix(".")) || "application/octet-stream"
    end

    # GET /mbeditor/monaco_worker.js — serve packaged Monaco worker entrypoint
    def monaco_worker
      path = monaco_worker_file.to_s
      return render plain: "Not found", status: :not_found unless File.file?(path)

      send_file path, disposition: "inline", type: "application/javascript"
    end

    # GET /mbeditor/manifest.webmanifest — PWA manifest
    def pwa_manifest
      raw  = root_path.chomp("/")
      base = raw.start_with?("/") || raw.empty? ? raw : "/#{raw}"
      manifest = {
        name: "Mbeditor — #{Rails.root.basename}",
        short_name: "Mbeditor",
        description: "Mini Browser Editor",
        start_url: "#{base}/",
        scope: "#{base}/",
        display: "standalone",
        background_color: "#1e1e2e",
        theme_color: "#1e1e2e",
        icons: [
          { src: "#{base}/mbeditor-icon.svg", sizes: "any", type: "image/svg+xml", purpose: "any maskable" }
        ]
      }
      render plain: JSON.generate(manifest), content_type: "application/manifest+json"
    end

    # GET /mbeditor/sw.js — minimal PWA service worker
    def pwa_sw
      path = Mbeditor::Engine.root.join("public", "sw.js").to_s
      return render plain: "Not found", status: :not_found unless File.file?(path)

      send_file path, disposition: "inline", type: "application/javascript"
    end

    # GET /mbeditor/mbeditor-icon.svg — PWA icon
    def pwa_icon
      path = Mbeditor::Engine.root.join("public", "mbeditor-icon.svg").to_s
      return render plain: "Not found", status: :not_found unless File.file?(path)

      send_file path, disposition: "inline", type: "image/svg+xml"
    end

    # GET /mbeditor/ts_worker.js — serve TypeScript/JavaScript Monaco worker
    def ts_worker
      path = [
        Mbeditor::Engine.root.join("public", "ts_worker.js"),
        Rails.root.join("public", "ts_worker.js")
      ].find { |p| p.file? }.to_s
      return render plain: "Not found", status: :not_found unless File.file?(path)

      send_file path, disposition: "inline", type: "application/javascript"
    end

    # POST /mbeditor/lint — run rubocop --stdin (or haml-lint for .haml files)
    def lint
      path = resolve_path(params[:path])
      return render json: { error: "Forbidden" }, status: :forbidden unless path

      filename = path.to_s
      code = params[:code] || File.read(path)

      if File.basename(filename).end_with?('.haml')
        unless AvailabilityProbe.haml_lint(workspace_root)
          return render json: { error: "haml-lint not available", markers: [] }, status: :unprocessable_content
        end

        markers = run_haml_lint(code)
        return render json: { markers: markers }
      end

      cmd = AvailabilityProbe.rubocop_command(workspace_root) + ["--no-server", "--stdin", filename, "--format", "json", "--no-color"]
      env = { 'RUBOCOP_CACHE_ROOT' => File.join(Dir.tmpdir, 'rubocop') }
      output = run_with_timeout(env, cmd, stdin_data: code)

      idx = output.index("{")
      result = idx ? JSON.parse(output[idx..]) : {}
      result = {} unless result.is_a?(Hash)
      offenses = result.dig("files", 0, "offenses") || []

      markers = offenses.map do |offense|
        {
          severity: cop_severity(offense["severity"]),
          copName: offense["cop_name"],
          correctable: offense["correctable"] == true,
          message: "[#{offense['cop_name']}] #{offense['message']}",
          startLine: offense.dig("location", "start_line") || offense.dig("location", "line"),
          startCol: offense.dig("location", "start_column") || offense.dig("location", "column") || 1,
          endLine: offense.dig("location", "last_line") || offense.dig("location", "line"),
          endCol: offense.dig("location", "last_column") || offense.dig("location", "column") || 1
        }
      end

      render json: { markers: markers, summary: result["summary"] }
    rescue StandardError => e
      render json: { error: e.message, markers: [] }, status: :unprocessable_content
    end

    # POST /mbeditor/quick_fix — autocorrect the buffer with rubocop -A and return the diff as a text edit
    #
    # Runs a full `rubocop -A` pass on the in-memory buffer content (not the file
    # on disk). Using a full pass (rather than --only <cop>) means coupled cops
    # like Layout/EmptyLineAfterMagicComment are also applied in the same round,
    # so the result is always a clean, lint-passing state. The minimal line diff
    # returned to Monaco keeps the edit tight.
    #
    # Params:
    #   path     - workspace-relative file path (used to derive the filename for rubocop)
    #   code     - current file content as a string
    #   cop_name - the cop the user clicked on (used only for the action label; not passed to rubocop)
    #
    # Returns:
    #   { fix: { startLine, startCol, endLine, endCol, replacement } }
    #   or { fix: null } when rubocop produced no change
    def quick_fix
      path = resolve_path(params[:path])
      return render json: { error: "Forbidden" }, status: :forbidden unless path

      cop_name = params[:cop_name].to_s.strip
      return render json: { error: "cop_name required" }, status: :unprocessable_content if cop_name.empty?
      return render json: { error: "Invalid cop name" }, status: :unprocessable_content unless cop_name.match?(/\A[\w\/]+\z/)

      code = params[:code].to_s
      ext  = File.extname(File.basename(path))

      # Use a workspace-local tempfile so RuboCop's config discovery walks up
      # from the source file's directory and finds the host app's .rubocop.yml.
      Tempfile.create([".mbeditor_fix_", ext], File.dirname(path)) do |f|
        f.write(code)
        f.flush
        tmpfile = f.path

        cmd = AvailabilityProbe.rubocop_command(workspace_root) + ["--no-server", "-A", "--no-color", tmpfile]
        env = { 'RUBOCOP_CACHE_ROOT' => File.join(Dir.tmpdir, 'rubocop') }
        _out, _err, status = Open3.capture3(env, *cmd)

        # exit 0 = no offenses, exit 1 = offenses corrected, exit 2 = error
        unless status.success? || status.exitstatus == 1
          return render json: { fix: nil }
        end

        corrected = File.read(tmpfile, encoding: "UTF-8", invalid: :replace, undef: :replace)
        fix = compute_text_edit(code, corrected)
        render json: { fix: fix }
      end
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    # POST /mbeditor/test — run tests for the given file
    def run_test
      path = resolve_path(params[:path])
      return render json: { error: "Forbidden" }, status: :forbidden unless path

      relative = relative_path(path)
      test_file = TestRunnerService.resolve_test_file(workspace_root.to_s, relative)
      return render json: { error: "No matching test file found for #{relative}" }, status: :not_found unless test_file

      full_test = File.join(workspace_root.to_s, test_file)
      return render json: { error: "Test file does not exist: #{test_file}" }, status: :not_found unless File.file?(full_test)

      config = Mbeditor.configuration
      result = TestRunnerService.run(
        workspace_root.to_s,
        test_file,
        framework: config.test_framework&.to_sym,
        command: config.test_command,
        timeout: config.test_timeout || 60
      )

      render json: result.merge(testFile: test_file)
    rescue StandardError => e
      render json: { error: e.message, ok: false }, status: :unprocessable_content
    end

    # GET /mbeditor/client_config — returns client-side configuration values
    def client_config
      render json: {
        related_files_custom_paths: Array(Mbeditor.configuration.related_files_custom_paths)
      }
    end

    # GET /mbeditor/related_files?path=...
    def related_files
      path = resolve_path(params[:path])
      return render json: {}, status: :bad_request unless path
      rel = relative_path(path)
      custom = Array(Mbeditor.configuration.related_files_custom_paths)
      result = RailsRelatedFilesService.find(workspace_root.to_s, rel, custom_paths: custom)
      render json: result
    end

    # GET /mbeditor/changelog — serves the gem's CHANGELOG.md for the in-editor changelog tab.
    def changelog
      path = Mbeditor::Engine.root.join("CHANGELOG.md")
      content = path.exist? ? path.read(encoding: "utf-8") : ""
      render json: { content: content, version: Mbeditor::VERSION }
    end

    # GET /mbeditor/model_schema?model=User
    # Returns the db/schema.rb table definition for the named model as JSON.
    # 404 when the schema file is missing or the table is not found.
    def model_schema
      model_name = params[:model].to_s.strip
      return render json: { error: "model required" }, status: :bad_request if model_name.blank?

      schema = SchemaService.new(model_name, workspace_root.to_s).call
      if schema
        render json: schema
      else
        render json: { error: "No schema found for '#{model_name}'" }, status: :not_found
      end
    end

    # POST /mbeditor/format — rubocop -A on buffer content; returns corrected content WITHOUT saving to disk
    #
    # Accepts the current buffer content as `code` and formats it using a
    # workspace-local tempfile so that RuboCop's config discovery walks up from
    # the source file's own directory (finds the host app's .rubocop.yml).
    # Does NOT write the result back to the original file — the frontend marks
    # the tab dirty and lets the user decide when to save.
    def format_file
      path = resolve_path(params[:path])
      return render json: { error: "Forbidden" }, status: :forbidden unless path

      code = params[:code].to_s
      return render json: { error: "code required" }, status: :unprocessable_content if code.empty?

      ext = File.extname(File.basename(path))
      Tempfile.create([".mbeditor_fmt_", ext], File.dirname(path)) do |f|
        f.write(code)
        f.flush
        tmpfile = f.path

        cmd = AvailabilityProbe.rubocop_command(workspace_root) + ["--no-server", "-A", "--no-color", tmpfile]
        env = { 'RUBOCOP_CACHE_ROOT' => File.join(Dir.tmpdir, 'rubocop') }
        _out, _err, status = Open3.capture3(env, *cmd)
        unless status.success? || status.exitstatus == 1
          return render json: { ok: false, content: code }
        end

        corrected = File.read(tmpfile, encoding: "UTF-8", invalid: :replace, undef: :replace)
        render json: { ok: true, content: corrected }
      end
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    private

    def broadcast_files_changed
      root = workspace_root.to_s
      FileTreeService.invalidate(root)
      Thread.new do
        GitInfoService.invalidate(root)
      rescue => e
        Rails.logger.warn("[mbeditor] GitInfoService.invalidate failed: #{e}")
      end

      return unless defined?(ActionCable.server)

      ActionCable.server.broadcast("mbeditor_editor", { type: "files_changed" })
    rescue StandardError
      # Never let a broadcast failure affect the HTTP response
    end

    def editor_state_service
      @editor_state_service ||= EditorStateService.new(workspace_root)
    end

    def sanitize_branch_name(branch)
      return nil if branch.blank?
      str = branch.to_s.strip
      return nil if str.include?('..')
      str.match?(EditorStateService::SAFE_BRANCH_NAME) ? str : nil
    end

    def action_cable_enabled?
      return false unless defined?(ActionCable::Channel::Base)

      mount_path = begin
        ActionCable.server.config.mount_path
      rescue StandardError
        nil
      end
      mount_path = '/cable' if mount_path.blank?

      Rails.application.routes.routes.any? do |route|
        route.path.spec.to_s.start_with?(mount_path)
      end
    rescue StandardError
      false
    end

    def allow_missing_file?
      %w[1 true yes on].include?(params[:allow_missing].to_s.downcase)
    end

    def missing_file_payload(raw_path)
      {
        path: raw_path.to_s.sub(%r{\A/+}, ""),
        content: "",
        missing: true
      }
    end

    def verify_mbeditor_client
      return if request.headers['X-Mbeditor-Client'] == '1'

      render plain: 'Forbidden', status: :forbidden
    end

    def path_blocked_for_operations?(full_path)
      rel = relative_path(full_path)
      return true if rel.blank?

      ExclusionMatcher.new(Mbeditor.configuration.excluded_paths).excluded?(rel)
    end

    def ruby_def_include_dirs
      Array(Mbeditor.configuration.ruby_def_include_dirs).map(&:to_s).reject(&:blank?)
    end

    def run_with_timeout(env, cmd, stdin_data:)
      timeout_seconds = Mbeditor.configuration.lint_timeout&.to_i
      timeout = timeout_seconds && timeout_seconds > 0 ? timeout_seconds : nil
      result = ProcessRunner.call(cmd, timeout: timeout, env: env, stdin_data: stdin_data)
      result[:stdout]
    end

    def cop_severity(severity)
      case severity
      when "error", "fatal" then "error"
      when "warning" then "warning"
      else "info"
      end
    end

    # Given the original source string and the autocorrected source string, find
    # the smallest single edit that transforms original into corrected.  Returns a
    # hash suitable for Monaco's SingleEditOperation, or nil when there is no diff.
    #
    # The strategy is line-level: find the first and last line that differ, then
    # slice out that region from both versions and return it as one replacement.
    def compute_text_edit(original, corrected)
      return nil if original == corrected

      orig_lines = original.split("\n", -1)
      corr_lines = corrected.split("\n", -1)

      max_len = [orig_lines.length, corr_lines.length].max

      first_diff = (0...max_len).find { |i| orig_lines[i] != corr_lines[i] }
      return nil if first_diff.nil?

      # Walk from the end to find the last differing line (mirror-image of above)
      last_diff_orig = orig_lines.length - 1
      last_diff_corr = corr_lines.length - 1
      # Use strict > so we never walk past first_diff (which would make last_diff_orig negative
      # and cause Ruby's negative-index wraparound to silently return the wrong element).
      while last_diff_orig > first_diff && last_diff_corr > first_diff &&
            orig_lines[last_diff_orig] == corr_lines[last_diff_corr]
        last_diff_orig -= 1
        last_diff_corr -= 1
      end

      # Monaco ranges are 1-based; endColumn one past the last char covers the full line content.
      start_line = first_diff + 1
      end_line   = last_diff_orig + 1
      end_col    = (orig_lines[last_diff_orig] || "").length + 1  # 1-based: one past last char

      replacement = corr_lines[first_diff..last_diff_corr].join("\n")

      {
        startLine: start_line,
        startCol:  1,
        endLine:   end_line,
        endCol:    end_col,
        replacement: replacement
      }
    end

    def rubocop_config_path
      candidate = workspace_root.join(".rubocop.yml")
      candidate.exist? ? ".rubocop.yml" : nil
    end

    def test_available?
      root = workspace_root.to_s
      File.directory?(File.join(root, "test")) || File.directory?(File.join(root, "spec"))
    end

    def run_haml_lint(code)
      markers = []
      Tempfile.create(["mbeditor_haml", ".haml"]) do |f|
        f.write(code)
        f.flush
        output, _err, _status = Open3.capture3(*AvailabilityProbe.haml_lint_command(workspace_root), "--reporter", "json", "--no-color", f.path)
        idx = output.index("{")
        result = idx ? JSON.parse(output[idx..]) : {}
        result = {} unless result.is_a?(Hash)
        offenses = result.dig("files", 0, "offenses") || []
        markers = offenses.map do |offense|
          {
            severity: haml_lint_severity(offense["severity"]),
            message: "[#{offense['linter_name']}] #{offense['message']}",
            startLine: offense.dig("location", "line"),
            startCol: (offense.dig("location", "column") || 1) - 1,
            endLine: offense.dig("location", "line"),
            endCol: offense.dig("location", "column") || 1
          }
        end
      end
      markers
    end

    def haml_lint_severity(severity)
      case severity
      when "error" then "error"
      when "warning" then "warning"
      else "info"
      end
    end

    def monaco_worker_file
      engine_path = Mbeditor::Engine.root.join("public", "monaco_worker.js")
      return engine_path if engine_path.file?

      Rails.root.join("public", "monaco_worker.js")
    end

    def resolve_monaco_asset_path(asset_path)
      return nil if asset_path.blank?

      [
        Mbeditor::Engine.root.join("public"),
        Rails.root.join("public")
      ].each do |public_root|
        base = public_root.to_s
        full = File.expand_path(asset_path.to_s, base)
        next unless full.start_with?(base + '/')
        return full if File.file?(full)
      end

      nil
    end

    def image_path?(path)
      extension = File.extname(path).delete_prefix(".").downcase
      IMAGE_EXTENSIONS.include?(extension)
    end

    def render_file_too_large(size)
      render json: {
        error: "File is too large to open (#{human_size(size)}). Limit is #{human_size(FileOperationService::MAX_FILE_SIZE_BYTES)}."
      }, status: :content_too_large
    end

    def human_size(bytes)
      units = %w[B KB MB GB TB]
      value = bytes.to_f
      unit_index = 0

      while value >= 1024.0 && unit_index < units.length - 1
        value /= 1024.0
        unit_index += 1
      end

      precision = unit_index.zero? ? 0 : 1
      format("%.#{precision}f %s", value, units[unit_index])
    end
  end
end
