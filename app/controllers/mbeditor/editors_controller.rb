# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"
require "shellwords"
require "tempfile"
require "timeout"
require "tmpdir"
require "uri"

module Mbeditor
  class EditorsController < ApplicationController
    skip_before_action :verify_authenticity_token
    before_action :verify_mbeditor_client, unless: -> { request.get? || request.head? }

    IMAGE_EXTENSIONS = %w[png jpg jpeg gif svg ico webp bmp avif].freeze
    helper_method :mbeditor_base_path

    RUBY_DEFS_WARM_MUTEX = Mutex.new
    TOTAL_LINES_CACHE_MAX = 50
    TOTAL_LINES_MUTEX = Mutex.new
    GIT_STATUS_TTL = 3
    GIT_STATUS_MUTEX = Mutex.new
    # Kept below Rack's multipart_part_limit (128 file parts in Rack 3.2), which
    # is enforced during param parsing — outside the action, where this
    # controller's rescue cannot turn it into a clean 422. A batch larger than
    # the Rack limit raises MultipartPartLimitError and surfaces as a 500, so
    # this guard is only reachable if it trips first.
    IMPORT_MAX_FILES = 100
    IMPORT_MAX_TOTAL_BYTES = 50 * 1024 * 1024

    class << self
      # Small (path, mtime) => total-line-count cache so windowed reads of big
      # files don't re-read the whole file just to report total_lines.
      def cached_total_lines(path, mtime)
        TOTAL_LINES_MUTEX.synchronize do
          entry = (@total_lines_cache ||= {})[path]
          entry && entry[:mtime] == mtime ? entry[:total] : nil
        end
      end

      def store_total_lines(path, mtime, total)
        TOTAL_LINES_MUTEX.synchronize do
          cache = (@total_lines_cache ||= {})
          cache.delete(path)
          cache[path] = { mtime: mtime, total: total }
          cache.delete(cache.keys.first) while cache.length > TOTAL_LINES_CACHE_MAX
        end
      end

      # git_status is polled every 5s by every open tab and costs two git
      # subprocesses. A 3s TTL collapses the duplicates while staying inside one
      # poll interval; any mutation drops it outright (broadcast_files_changed).
      def cached_git_status(root)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        GIT_STATUS_MUTEX.synchronize do
          entry = (@git_status_cache ||= {})[root]
          return entry[:value] if entry && (now - entry[:ts]) < GIT_STATUS_TTL
        end

        value = yield
        GIT_STATUS_MUTEX.synchronize do
          (@git_status_cache ||= {})[root] = { ts: now, value: value }
        end
        value
      end

      def invalidate_git_status(root)
        GIT_STATUS_MUTEX.synchronize { (@git_status_cache ||= {}).delete(root) }
        nil
      end
    end

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
      warm_ruby_definition_cache
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
        # The client derives its request timeout from this. Two independently
        # hard-coded numbers is how you get the browser aborting a run the
        # server is still happily executing, reported as a generic network
        # error instead of the server's own message.
        testTimeout: (Mbeditor.configuration.test_timeout || 180).to_i,
        actionCableEnabled: action_cable_enabled?,
        jsSyntaxCheckAvailable: JsSyntaxCheckService.available?,
        rubyLspAvailable: AvailabilityProbe.ruby_lsp(workspace_root),
        # "rg" | "git" | "grep". The tiers differ by 10-30x, and the usual
        # reason for a slow search is ripgrep being installed but absent from
        # the server process's PATH — which is invisible without this.
        searchBackend: SearchReplaceService.backend(workspace_root)
      }
    end

    # GET /mbeditor/files — recursive file tree
    # refresh=1 means "my view of the workspace is stale, drop your caches" —
    # the client sends it after an external `git checkout`, which rewrites the
    # tree without going through any mutation endpoint, so nothing here knows
    # to invalidate. Without it the 15s tree TTL kept serving the old branch's
    # file list, and the search cache the old branch's hits.
    def files
      if params[:refresh].present?
        FileTreeService.invalidate(workspace_root.to_s)
        SearchReplaceService.invalidate_cache(workspace_root.to_s)
      end
      tree = FileTreeService.cached_json(workspace_root)
      render json: tree[:body] if stale?(etag: tree[:digest], public: false)
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
      out, status = GitService.run_git(root, "branch", "--format=%(refname:short)")
      return render json: { pruned: [] } unless status.success?

      local_branches = out.split("\n").map(&:strip).reject(&:empty?)
      pruned = editor_state_service.prune_branch_states(active_branches: local_branches)
      file_history_service.prune(active_branches: local_branches)

      render json: { pruned: pruned }
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    # GET /mbeditor/file_history?branch=X&path=Y
    def file_history
      branch = sanitize_branch_name(params[:branch])
      return render json: {}, status: :bad_request unless branch

      path = resolve_path(params[:path])
      return render json: {}, status: :forbidden unless path

      rel = relative_path(path)
      render json: file_history_service.read(branch, rel) || {}
    rescue StandardError
      render json: {}
    end

    # POST /mbeditor/file_history
    def save_file_history
      branch = sanitize_branch_name(params[:branch])
      return render json: { error: 'Invalid branch name' }, status: :bad_request unless branch

      path = resolve_path(params[:path])
      return render json: { error: 'Forbidden' }, status: :forbidden unless path

      rel     = relative_path(path)
      new_ops = params[:ops]
      return render json: { error: 'ops must be an array' }, status: :bad_request unless new_ops.is_a?(Array)
      return head :no_content if new_ops.empty?

      new_ops_clean = new_ops.map { |op| Array(op).first(5) }

      file_history_service.append(branch, rel, ops: new_ops_clean, base: params[:base], base_given: params.key?(:base))
      head :no_content
    rescue FileHistoryService::BaseRequiredError
      render json: { error: 'base required for initial history' }, status: :bad_request
    rescue FileHistoryService::BaseTooLargeError
      render json: { error: 'base too large' }, status: :content_too_large
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
        stat = File.stat(path)
        total_bytes = stat.size
        cached_total = self.class.cached_total_lines(path, stat.mtime.to_f)
        chunk = []
        total_lines = 0
        File.foreach(path, encoding: "UTF-8", invalid: :replace, undef: :replace) do |line|
          chunk << line if total_lines >= start_line && chunk.length < line_count
          total_lines += 1
          # Once the requested window is filled and the total is already known
          # from a prior read of this (path, mtime), skip the rest of the file.
          if cached_total && chunk.length >= line_count
            total_lines = cached_total
            break
          end
        end
        self.class.store_total_lines(path, stat.mtime.to_f, total_lines) unless cached_total
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
    #
    # ?download=1 flips the disposition to attachment, which is the whole of
    # the explorer's "Download" action: the browser's own save dialog does the
    # rest, so there is no separate endpoint and no client-side blob.
    def raw
      path = resolve_path(params[:path])
      return render json: { error: "Forbidden" }, status: :forbidden unless path
      return render json: { error: "Not found" }, status: :not_found unless File.file?(path)

      stat = File.stat(path)
      return render_file_too_large(stat.size) if stat.size > FileOperationService::MAX_FILE_SIZE_BYTES
      return unless stale?(last_modified: stat.mtime, public: false)

      send_file path, disposition: params[:download].present? ? "attachment" : "inline"
    end

    # POST /mbeditor/file — save file
    def save
      path = resolve_path(params[:path])
      return render json: { error: "Forbidden" }, status: :forbidden unless path
      return render json: { error: "Cannot write to this path" }, status: :forbidden if path_blocked_for_operations?(path)

      result = FileOperationService.new(workspace_root).save(path, params[:code].to_s)
      broadcast_files_changed([path], structural: false)
      broadcast_file_saved(path)
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
      broadcast_files_changed([path])
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

    # PATCH /mbeditor/rename — rename file or directory
    def rename
      old_path = resolve_path(params[:path])
      new_path = resolve_path(params[:new_path])
      return render json: { error: "Forbidden" }, status: :forbidden unless old_path && new_path
      return render json: { error: "Cannot rename this path" }, status: :forbidden if path_blocked_for_operations?(old_path) || path_blocked_for_operations?(new_path)

      result = FileOperationService.new(workspace_root).rename(old_path, new_path)
      broadcast_files_changed([old_path, new_path])
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
      broadcast_files_changed([path]) if result.key?(:type)
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

      parent = params[:parent].to_s.strip
      if parent.present?
        return render json: { error: "Invalid parent" }, status: :bad_request \
          unless parent.match?(/\A[a-zA-Z_$][a-zA-Z0-9_$]{0,59}\z/)
      else
        parent = nil
      end

      results = JsDefinitionService.new(symbol, workspace_root, parent: parent).call
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

    # GET /mbeditor/js_globals
    # All top-level JS declarations across the workspace (the Sprockets global
    # scope), plus config.js_global_identifiers. The editor declares these as
    # ambient globals so cross-file component references don't produce
    # "Cannot find name" diagnostics.
    def js_globals
      render json: JsGlobalsService.call(workspace_root)
    rescue StandardError => e
      render json: { ok: false, error: e.message }, status: :unprocessable_content
    end

    # GET /mbeditor/js_program
    # The workspace's own JS source, for Monaco's TypeScript program. With
    # ?path= it returns just that one file, which is how the editor refreshes
    # after a change without re-sending the whole tree.
    def js_program
      if params[:path].present?
        entry = JsProgramService.file(workspace_root, params[:path])
        return render json: { ok: true, file: entry }
      end

      render json: JsProgramService.call(workspace_root)
    rescue StandardError => e
      render json: { ok: false, error: e.message }, status: :unprocessable_content
    end

    # The whitelist is the trust boundary: only these reach the language server.
    # Symbol values are handled locally instead of being forwarded; they need no
    # path, no document and no running process.
    #
    # The first four have bespoke translators producing 1-based, editor-shaped
    # payloads, kept for their existing consumers. Everything added since is in
    # RUBY_LSP_RAW below: raw LSP JSON, 0-based, through one URI sanitizer. Eight
    # more hand-written translators would be ~200 lines restating shapes Monaco
    # already understands.
    RUBY_LSP_METHODS = {
      "definition"       => "textDocument/definition",
      "hover"            => "textDocument/hover",
      "completion"       => "textDocument/completion",
      "diagnostics"      => "textDocument/diagnostic",
      "references"       => "textDocument/references",
      "document_highlight" => "textDocument/documentHighlight",
      "document_symbol"  => "textDocument/documentSymbol",
      "folding_range"    => "textDocument/foldingRange",
      "formatting"       => "textDocument/formatting",
      "signature_help"   => "textDocument/signatureHelp",
      "selection_range"  => "textDocument/selectionRange",
      "prepare_rename"   => "textDocument/prepareRename",
      "health"           => :health,
      "restart"          => :restart
    }.freeze

    # Passed through as raw LSP JSON rather than translated. Ranges stay 0-based
    # on the wire and are converted by one helper at the Monaco provider.
    RUBY_LSP_RAW = %w[
      references document_highlight document_symbol folding_range
      formatting signature_help selection_range prepare_rename
    ].freeze

    # Whole-document requests, which carry no cursor position.
    RUBY_LSP_POSITIONLESS = %w[
      textDocument/diagnostic textDocument/documentSymbol textDocument/foldingRange
      textDocument/formatting
    ].freeze

    # Extra params per method, merged into the request alongside the position.
    # Values may be a hash or a callable taking the params hash.
    RUBY_LSP_EXTRA_PARAMS = {
      "textDocument/references" => { context: { includeDeclaration: true } },
      # selectionRange takes a list of positions, not the single `position` the
      # positional branch supplies, so it builds its own from the same params.
      "textDocument/selectionRange" => lambda { |p|
        { positions: [{ line: [p[:line].to_i - 1, 0].max,
                        character: [p[:character].to_i - 1, 0].max }] }
      },
      "textDocument/formatting" => lambda { |p|
        { options: { tabSize: (p[:tab_size].presence || 2).to_i,
                     insertSpaces: p[:insert_spaces].to_s != "false" } }
      }
    }.freeze

    # RuboCop's first run inside a freshly booted ruby-lsp is far slower than a
    # hover/definition lookup, so the requests that go through RuboCop —
    # diagnostics and formatting — get their own budget.
    RUBY_LSP_DIAGNOSTICS_TIMEOUT = 10

    RUBY_LSP_RUBOCOP_METHODS = %w[textDocument/diagnostic textDocument/formatting].freeze

    # POST /mbeditor/ruby_lsp — bridge to the host's ruby-lsp process.
    # Body: { path:, content:, line: (1-based), character: (1-based), lsp_method: }
    # Translates LSP responses into the shapes the frontend providers already
    # consume; { fallback: true } tells the frontend to use the legacy path.
    def ruby_lsp
      lsp_method = RUBY_LSP_METHODS[params[:lsp_method].to_s]
      return render json: { error: "Invalid lsp_method" }, status: :bad_request unless lsp_method

      # Before resolve_path: health and restart carry no document.
      return render json: ruby_lsp_health(restart: lsp_method == :restart) if lsp_method.is_a?(Symbol)

      path = resolve_path(params[:path])
      return render json: { error: "Invalid path" }, status: :bad_request unless path

      content = params[:content].to_s
      if content.bytesize > FileOperationService::MAX_FILE_SIZE_BYTES
        return render json: { error: "Content too large" }, status: :content_too_large
      end

      unless AvailabilityProbe.ruby_lsp(workspace_root)
        return render json: { error: "ruby-lsp unavailable",
                              reason: ruby_lsp_unavailable_reason,
                              rubyLspAvailable: false }, status: :unprocessable_content
      end

      positionless = RUBY_LSP_POSITIONLESS.include?(lsp_method)
      extra = if positionless
        {}
      else
        # Monaco positions are 1-based; LSP positions are 0-based.
        { position: { line: [params[:line].to_i - 1, 0].max,
                      character: [params[:character].to_i - 1, 0].max } }
      end
      per_method = RUBY_LSP_EXTRA_PARAMS[lsp_method]
      per_method = per_method.call(params) if per_method.respond_to?(:call)
      extra = extra.merge(per_method || {})
      # Only the two RuboCop-backed requests pay its boot cost; documentSymbol,
      # foldingRange and the rest are a single Prism parse and want the normal
      # budget.
      timeout = RUBY_LSP_RUBOCOP_METHODS.include?(lsp_method) ? RUBY_LSP_DIAGNOSTICS_TIMEOUT : nil

      client = RubyLspClient.for(workspace_root.to_s)
      result = client.request_with_document(lsp_method, path, content, extra, timeout: timeout)
      # The URI is what the diagnostics translator checks embedded code-action
      # edits against, so it must be the same string the client sent.
      render json: translate_ruby_lsp_result(params[:lsp_method].to_s, result, "file://#{path}")
    rescue RubyLspClient::TimeoutError, RubyLspClient::NotReadyError
      # lspState lets the frontend tell "this one request was slow" from "the
      # server is dead", and stop asking in the latter case.
      render json: { fallback: true, lspState: RubyLspClient.for(workspace_root.to_s).state }
    rescue StandardError => e
      render json: { error: e.message, fallback: true }
    end

    # ruby-lsp renames constants only (Rename#perform locates
    # ConstantReadNode | ConstantPathNode | ConstantPathTargetNode and nothing
    # else), so anything that isn't a constant path is rejected before we ask.
    RUBY_CONSTANT_PATH = /\A[A-Z][A-Za-z0-9_]*(::[A-Z][A-Za-z0-9_]*)*\z/

    # Rename#collect_text_edits globs **/*.rb and Prism-parses every hit, which
    # is seconds on a large app rather than the usual milliseconds.
    RUBY_LSP_RENAME_TIMEOUT = 30

    # POST /mbeditor/ruby_rename — rename a Ruby constant across the workspace.
    #
    # Body: { path:, content:, line:, character:, new_name:, open_paths: [] }
    #
    # The workspace edit is split by whether the file is open in the editor:
    #
    #   - open files    -> edits returned for Monaco to apply, so the change is
    #                      undoable, marks the tab dirty, and respects the
    #                      buffer the user is actually looking at
    #   - closed files  -> written here, then announced over the cable
    #
    # That split is what makes unsaved work safe: anything dirty is by
    # definition open, and open files are never written by the server.
    def ruby_rename
      path = resolve_path(params[:path])
      return render json: { error: "Invalid path" }, status: :bad_request unless path

      new_name = params[:new_name].to_s.strip
      unless new_name.match?(RUBY_CONSTANT_PATH)
        return render json: { error: "Only Ruby constants can be renamed, and #{new_name.inspect} is not one." },
                      status: :unprocessable_content
      end

      content = params[:content].to_s
      if content.bytesize > FileOperationService::MAX_FILE_SIZE_BYTES
        return render json: { error: "Content too large" }, status: :content_too_large
      end

      unless AvailabilityProbe.ruby_lsp(workspace_root)
        return render json: { error: "ruby-lsp unavailable", reason: ruby_lsp_unavailable_reason,
                              rubyLspAvailable: false }, status: :unprocessable_content
      end

      result = RubyLspClient.for(workspace_root.to_s).request_with_document(
        "textDocument/rename", path, content,
        { position: { line: [params[:line].to_i - 1, 0].max,
                      character: [params[:character].to_i - 1, 0].max },
          newName: new_name },
        timeout: RUBY_LSP_RENAME_TIMEOUT
      )

      render json: apply_rename_changes(result, Array(params[:open_paths]).map(&:to_s))
    rescue RubyLspClient::TimeoutError, RubyLspClient::NotReadyError
      render json: { error: "ruby-lsp did not answer in time", fallback: true,
                     lspState: RubyLspClient.for(workspace_root.to_s).state },
             status: :unprocessable_content
    rescue StandardError => e
      # ruby-lsp raises InvalidNameError ("already in use by X") for a clash;
      # its message is the most useful thing we can show.
      render json: { error: e.message }, status: :unprocessable_content
    end

    # GET /mbeditor/model_graph — ActiveRecord models and their associations.
    #
    # Cached until a model or migration file changes; `refresh=1` forces a
    # rebuild. Generating it eager-loads the host app, which is why this is
    # only requested when the Models tab is opened.
    def model_graph
      ModelGraphService.invalidate(workspace_root) if params[:refresh].present?
      render json: ModelGraphService.call(workspace_root)
    rescue StandardError => e
      render json: { ok: false, error: e.message, models: [], edges: [] },
             status: :unprocessable_content
    end

    # GET /mbeditor/exceptions — recorded host-app exceptions, newest first.
    #
    # The cable push is the live path; this seeds the panel on load and covers
    # hosts where ActionCable isn't available.
    def exceptions
      render json: { exceptions: ExceptionLog.entries,
                     enabled: Mbeditor.configuration.exception_capture != false }
    end

    # DELETE /mbeditor/exceptions — clear the recorded exceptions.
    def clear_exceptions
      ExceptionLog.clear!
      render json: { ok: true }
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

      # Optional single-file scope, used by the live result refresh after a save.
      if params[:path].present?
        full = resolve_path(params[:path])
        return render json: { error: "Invalid path" }, status: :forbidden unless full

        results = SearchReplaceService.search(workspace_root, query, limit: needed,
                                              use_regex: use_regex, match_case: match_case, whole_word: whole_word,
                                              excluded_paths: Mbeditor.configuration.excluded_paths, paths: [full])
        return render json: { results: results, has_more: false }
      end

      # One subprocess per query: the full (capped) result set is collected and
      # briefly cached, so pagination and the total count come from memory.
      page = SearchReplaceService.search_page(workspace_root, query, offset: offset, limit: limit,
                                              use_regex: use_regex, match_case: match_case, whole_word: whole_word,
                                              excluded_paths: Mbeditor.configuration.excluded_paths)
      response = { results: page[:results], has_more: page[:has_more], partial: page[:partial] }
      response[:total_count] = page[:total_count] if page[:total_count]

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
        render json: { error: result[:error] }, status: :unprocessable_content
      else
        render json: result
      end
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    # GET /mbeditor/git_status
    def git_status
      root = workspace_root.to_s
      payload = self.class.cached_git_status(root) do
        output, status = GitService.run_git(root, "status", "--porcelain")
        { ok: status.success?,
          files: GitService.parse_porcelain_status(output),
          branch: GitService.current_branch(root) || "" }
      end
      render json: payload
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    # GET /mbeditor/git_info
    def git_info
      render json: GitInfoService.call(workspace_root.to_s)
    end

    # GET /mbeditor/monaco-editor/*asset_path — serve packaged Monaco files
    def monaco_asset
      # path_info is the path within the engine, e.g. "/monaco-editor/monaco.js"
      relative = request.path_info.delete_prefix("/")
      path = resolve_monaco_asset_path(relative)
      return head :not_found unless path

      # ~14 MB of bundle, re-sent on every page load without this.
      return unless stale?(last_modified: File.mtime(path), public: false)

      send_file path, disposition: "inline", type: Mime::Type.lookup_by_extension(File.extname(path).delete_prefix(".")) || "application/octet-stream"
    end

    # GET /mbeditor/manifest.webmanifest — PWA manifest
    def pwa_manifest
      base = mbeditor_base_path
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
      return unless stale?(last_modified: File.mtime(path), public: false)

      send_file path, disposition: "inline", type: "application/javascript"
    end

    # GET /mbeditor/mbeditor-icon.svg — PWA icon
    def pwa_icon
      path = Mbeditor::Engine.root.join("public", "mbeditor-icon.svg").to_s
      return render plain: "Not found", status: :not_found unless File.file?(path)
      return unless stale?(last_modified: File.mtime(path), public: false)

      send_file path, disposition: "inline", type: "image/svg+xml"
    end

    # POST /mbeditor/lint — run rubocop --stdin (or haml-lint for .haml files)
    def lint
      path = resolve_path(params[:path])
      return render json: { error: "Forbidden" }, status: :forbidden unless path

      filename = path.to_s
      code = params[:code] || File.read(path)

      if params[:language] == "javascript"
        unless JsSyntaxCheckService.available?
          return render json: { error: "JS syntax check not available", markers: [] }, status: :unprocessable_content
        end

        err = JsSyntaxCheckService.check(code)
        markers = if err
          line = err["line"] || 1
          col  = (err["column"] || 0) + 1
          [{
            severity: "error",
            copName: "Babel",
            correctable: false,
            message: "[babel] #{err['message']}",
            startLine: line, startCol: col, endLine: line, endCol: col + 1
          }]
        else
          # Only when the file parses: the scope lint would re-hit the same
          # parse error and report nothing useful on top of the marker above.
          JsSyntaxCheckService.scope_lint(workspace_root, code).map do |w|
            line = w["line"] || 1
            col  = (w["column"] || 0) + 1
            {
              severity: "warning",
              copName: "BabelScope",
              correctable: false,
              message: "[babel] #{w['message']}",
              startLine: line, startCol: col,
              endLine: line, endCol: col + [w["name"].to_s.length, 1].max
            }
          end
        end
        return render json: { markers: markers }
      end

      if File.basename(filename).end_with?('.haml')
        unless AvailabilityProbe.haml_lint(workspace_root)
          return render json: { error: "haml-lint not available", markers: [] }, status: :unprocessable_content
        end

        return render json: { markers: LintService.haml_diagnostics(workspace_root, code) }
      end

      result = LintService.rubocop_diagnostics(workspace_root, path, code)
      render json: { markers: result[:markers], summary: result[:summary] }
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
      result = LintService.autocorrect(workspace_root, path, code)
      fix = result[:ok] ? compute_text_edit(code, result[:content]) : nil
      render json: { fix: fix }
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    # POST /mbeditor/rubocop — whole-workspace `rubocop` run
    #
    # mode=autocorrect adds `-a` (safe corrections only) and writes to disk, so
    # the response doubles as the post-correction offense list.
    def rubocop_run
      unless AvailabilityProbe.rubocop(workspace_root)
        return render json: { ok: false, error: "RuboCop is not available", files: [] }, status: :unprocessable_content
      end

      mode = params[:mode].to_s == "autocorrect" ? :autocorrect : :check
      result = RubocopRunService.run(workspace_root, mode: mode)
      # `-a` writes to disk behind every open tab's back. No path list: a
      # whole-project run can touch anything, and the omitted-paths form makes
      # the client re-check every open tab, which is exactly what's wanted.
      broadcast_files_changed(nil, structural: false) if mode == :autocorrect && result[:ok]
      render json: result
    rescue StandardError => e
      render json: { ok: false, error: e.message, files: [] }, status: :unprocessable_content
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

      raw_line = params[:line].to_s
      unless raw_line.empty? || raw_line.match?(/\A\d+\z/)
        return render json: { error: "Invalid line" }, status: :bad_request
      end

      # A line filter only makes sense when the user is in the test file
      # itself — running from a source file resolves to a whole test file.
      line = raw_line.empty? ? nil : raw_line.to_i
      line = nil unless line&.positive? && test_file == relative

      config = Mbeditor.configuration
      result = TestRunnerService.run(
        workspace_root.to_s,
        test_file,
        framework: config.test_framework&.to_sym,
        command: config.test_command,
        timeout: (config.test_timeout || 180).to_i,
        line: line
      )

      render json: result.merge(testFile: test_file, filteredLine: line)
    rescue StandardError => e
      render json: { error: e.message, ok: false }, status: :unprocessable_content
    end

    # GET /mbeditor/client_config — returns client-side configuration values
    def client_config
      render json: {
        related_files_custom_paths: Array(Mbeditor.configuration.related_files_custom_paths),
        user_name: resolved_user_name
      }
    end

    # GET /mbeditor/routes?path=app/controllers/users_controller.rb
    #
    # Which routes reach each action in a controller, for the inline hints the
    # editor draws beside every `def`. Returns {} for anything that is not a
    # controller rather than erroring — the client asks for every Ruby file it
    # opens and should not have to know the convention.
    def routes
      key = RouteService.controller_key(params[:path].to_s)
      return render json: { controller: nil, actions: {} } unless key

      render json: { controller: key, actions: RouteService.for_controller(key) }
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
      # SchemaService interpolates the underscored name into app/models/<x>.rb,
      # and Inflector.underscore leaves "../" intact. Same guard as
      # module_members, widened to the "::" a namespaced model needs. Spaces
      # are allowed because SchemaService strips them ("Order Item" → OrderItem).
      unless model_name.delete(" ").match?(RUBY_CONSTANT_PATH)
        return render json: { error: "Invalid model name" }, status: :bad_request
      end

      schema = SchemaService.new(model_name, workspace_root.to_s).call
      if schema
        render json: schema
      else
        hint = " (Check if the model has a custom table_name or if db/schema.rb exists)"
        render json: { error: "No schema found for '#{model_name}'#{hint}" }, status: :not_found
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

      result = LintService.autocorrect(workspace_root, path, code)
      render json: { ok: result[:ok], content: result[:content] }
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    private

    # Resolve the optional user_name_callback in controller context (like
    # authenticate_with) so the host app can supply a collaboration display name.
    # nil — including any failure or a blank result — falls through to the
    # client-generated name.
    # Display name for the collaboration caret. An explicit user_name_callback
    # wins; otherwise fall back to current_user, when the host's auth library put
    # it within reach of an ActionController::Base subclass (Devise, Sorcery and
    # friends do; a current_user hand-written on the host's own
    # ApplicationController does not — see default_user_name).
    def resolved_user_name
      cb = Mbeditor.configuration.user_name_callback
      name = cb ? instance_exec(&cb) : default_user_name
      name = name.to_s.strip
      name.empty? ? nil : name
    rescue StandardError => e
      # Was a bare `nil`, which made a broken callback indistinguishable from an
      # unconfigured one: you got the generated name and no clue why. The usual
      # cause is a NameError on current_user, and silently swallowing it sent
      # people looking in the wrong place.
      Rails.logger.warn("[mbeditor] user name lookup failed: #{e.class}: #{e.message}")
      nil
    end

    # Read the display name straight off current_user, trying each configured
    # attribute in turn. This is what makes an authenticated editor show real
    # names with no extra wiring; user_name_methods exists so an app whose column
    # isn't in the default list can name it instead of writing a callback.
    def default_user_name
      return nil unless respond_to?(:current_user, true)

      user = current_user
      return nil unless user

      Array(Mbeditor.configuration.user_name_methods).each do |m|
        next unless user.respond_to?(m)

        value = user.public_send(m).to_s.strip
        return value unless value.empty?
      end
      nil
    end

    # Normalized base prefix mbeditor renders URLs against. Sourced from
    # MountPath (not the engine `root_path` helper) so it still resolves when a
    # broken host config/routes.rb has wiped Mbeditor::Engine.routes — the exact
    # state resilient routing exists to survive.
    def mbeditor_base_path
      raw = Mbeditor::MountPath.resolve.chomp("/")
      raw.start_with?("/") || raw.empty? ? raw : "/#{raw}"
    end

    # structural: false means "these files' contents changed, the tree did not"
    # — a save or a replace-in-files. The client uses it to skip re-walking the
    # whole workspace and rebuilding its quick-open index on every save, which
    # is work no content change can invalidate. Defaults to true so a new call
    # site that says nothing keeps the conservative behaviour.
    def broadcast_files_changed(changed_paths = nil, structural: true)
      root = workspace_root.to_s
      FileTreeService.invalidate(root)
      SearchReplaceService.invalidate_cache(root)
      if js_related_paths?(changed_paths)
        JsGlobalsService.invalidate(root)
        JsProgramService.invalidate(root)
      end
      # Cheap, and it means editing config/routes.rb refreshes the inline route
      # hints on the next look rather than after the TTL.
      RouteService.invalidate
      # Both are mutex-guarded Hash#deletes; a thread per save cost more than
      # the work it deferred.
      GitInfoService.invalidate(root)
      self.class.invalidate_git_status(root)

      return unless defined?(ActionCable.server)

      payload = { type: "files_changed", structural: structural }
      rel = Array(changed_paths).compact.map { |p| relative_path(p.to_s) }.reject(&:empty?)
      payload[:paths] = rel if rel.any?
      ActionCable.server.broadcast("mbeditor_editor", payload)
    rescue StandardError
      # Never let a broadcast failure affect the HTTP response
    end

    # Everything either JS cache indexes: JsProgramService::SOURCE_EXT plus the
    # .erb-templated variants CodeSearchService::JS_GLOBS feeds JsGlobalsService.
    JS_SOURCE_NAME = /\.(js|jsx|mjs|cjs|ts|tsx)(\.erb)?\z/i

    # Rebuilding the JS program costs ~93ms/MB, so saving a .rb file must not
    # throw it away. A path with no extension at all — a directory, a rename
    # target — stays conservative, as does an omitted path list.
    def js_related_paths?(changed_paths)
      paths = Array(changed_paths).compact.map(&:to_s).reject(&:empty?)
      return true if paths.empty?

      paths.any? { |p| File.extname(p).empty? || p.match?(JS_SOURCE_NAME) }
    end

    # Tells every peer that this file's shared buffer was just saved to disk so
    # they can reset that tab's clean baseline and clear its dirty indicator.
    # Rides the same global stream as broadcast_files_changed and is equally
    # resilient: a relay failure must never affect the HTTP response.
    def broadcast_file_saved(path)
      return unless defined?(ActionCable.server)

      ActionCable.server.broadcast("mbeditor_editor", { type: "file_saved", path: relative_path(path) })
    rescue StandardError
      # Never let a broadcast failure affect the HTTP response
    end

    def editor_state_service
      @editor_state_service ||= EditorStateService.new(workspace_root)
    end

    def file_history_service
      @file_history_service ||= FileHistoryService.new(workspace_root)
    end

    def sanitize_branch_name(branch)
      return nil if branch.blank?
      str = branch.to_s.strip
      return nil if str.include?('..')
      str.match?(EditorStateService::SAFE_BRANCH_NAME) ? str : nil
    end

    # Warm the Ruby definition cache once per process, in the background, so
    # the first go-to-definition request doesn't pay for a full workspace
    # Ripper scan on the request thread. Triggered from /workspace (only the
    # editor UI calls it) rather than engine boot so rake tasks and consoles
    # never scan.
    def warm_ruby_definition_cache
      root = workspace_root.to_s
      RUBY_DEFS_WARM_MUTEX.synchronize do
        return if self.class.instance_variable_get(:@ruby_defs_warm_started)

        self.class.instance_variable_set(:@ruby_defs_warm_started, true)
      end
      Thread.new do
        RubyDefinitionService.new(root, nil,
                                  excluded_paths: Mbeditor.configuration.excluded_paths,
                                  included_dirs: Mbeditor.configuration.ruby_def_include_dirs).scan_workspace
      rescue StandardError => e
        Rails.logger.warn("[mbeditor] ruby definition cache warm failed: #{e}")
      end
    end

    def action_cable_enabled?
      # Iterating the host's whole route table is linear in app size and this
      # runs on every /workspace call — memoize with a short TTL (dev route
      # reloads shortly after boot are the only staleness window, and the
      # frontend degrades to polling if the answer was stale-positive).
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      cached = self.class.instance_variable_get(:@action_cable_enabled_cache)
      return cached[:value] if cached && (now - cached[:ts]) < 60

      value = compute_action_cable_enabled
      self.class.instance_variable_set(:@action_cable_enabled_cache, { value: value, ts: now })
      value
    end

    def compute_action_cable_enabled
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
      unless request.headers['X-Mbeditor-Client'] == '1' && same_origin_request?
        render plain: 'Forbidden', status: :forbidden
      end
    end

    # CSRF defense-in-depth: validate Origin/Referer against the request host.
    # We only reject on a *mismatch* — a request that carries neither header is
    # allowed (browsers force-set Origin on cross-origin state-changing requests,
    # so a forged cross-origin request can never reach the "absent" branch).
    def same_origin_request?
      if (origin = request.origin).present?
        origin == request.base_url
      elsif (referer = request.referer).present?
        # Compare scheme/host/port components rather than URI#origin: the latter
        # is unavailable on the `uri` gem bundled with Ruby 3.0 (added in 0.11.0)
        # and would raise NoMethodError there, surfacing as a 500.
        ref = URI.parse(referer)
        ref.scheme == request.scheme && ref.host == request.host && ref.port == request.port
      else
        true
      end
    rescue URI::InvalidURIError
      false
    end

    def path_blocked_for_operations?(full_path)
      rel = relative_path(full_path)
      return true if rel.blank?

      ExclusionMatcher.new(Mbeditor.configuration.excluded_paths, root: workspace_root).excluded?(rel)
    end

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

    def ruby_def_include_dirs
      Array(Mbeditor.configuration.ruby_def_include_dirs).map(&:to_s).reject(&:blank?)
    end

    def apply_rename_changes(result, open_paths)
      changes = result.is_a?(Hash) ? (result["changes"] || {}) : {}
      open = open_paths.to_set
      written = []
      rejected = []
      edits_for_open = {}

      changes.each do |uri, raw_edits|
        rel = RubyLspResultTranslator.workspace_relative_uri(uri.to_s, workspace_root)
        # Outside the workspace, or a path we refuse to write: record it so a
        # partial rename is visibly partial rather than silently so.
        target = rel && resolve_path(rel)
        if rel.nil? || target.nil? || path_blocked_for_operations?(target)
          rejected << (rel || uri.to_s)
          next
        end

        edits = Array(raw_edits).filter_map { |e| LspDiagnosticsTranslator.sanitize_edit(e) }
        next if edits.empty?

        if open.include?(rel)
          edits_for_open[rel] = edits
        else
          # ponytail: no transaction. A failure part-way leaves some files
          # renamed and some not; `written` says which. Upgrade path is
          # write-to-temp then rename-all if that ever bites.
          FileOperationService.new(workspace_root).save(target, apply_edits(File.read(target), edits))
          written << rel
        end
      end

      broadcast_files_changed(written.map { |rel| File.join(workspace_root, rel) }, structural: false) if written.any?
      { ok: true, written: written, rejected: rejected, edits: edits_for_open }
    end

    # Applies 1-based text edits to a source string. Sorted descending so an
    # earlier edit never invalidates a later one's offsets.
    def apply_edits(source, edits)
      lines = source.split("\n", -1)
      edits.sort_by { |e| [-e[:startLine], -e[:startCol]] }.each do |edit|
        next unless edit[:startLine] == edit[:endLine] # ruby-lsp's renames are single-line

        line = lines[edit[:startLine] - 1]
        next if line.nil?

        lines[edit[:startLine] - 1] =
          line[0, edit[:startCol] - 1].to_s + edit[:text].to_s + line[(edit[:endCol] - 1)..].to_s
      end
      lines.join("\n")
    end

    def ruby_lsp_unavailable_reason
      return "Disabled by configuration (config.mbeditor.ruby_lsp = false)" if Mbeditor.configuration.ruby_lsp == false

      "ruby-lsp is not installed in this workspace"
    end

    # Status for the editor's ruby-lsp indicator, and the recovery path behind
    # clicking it. Never returns the resolved command — that would leak absolute
    # host paths to the browser.
    def ruby_lsp_health(restart: false)
      if restart
        # ponytail: reset! clears every probe, not just ruby-lsp. Harmless (they
        # all re-probe on next use) and the alternative is a per-key API nothing
        # else wants.
        AvailabilityProbe.reset!
        RubyLspClient.for(workspace_root.to_s).reset!
      end

      available = AvailabilityProbe.ruby_lsp(workspace_root)
      health = available ? RubyLspClient.for(workspace_root.to_s).health : {}

      payload = {
        available: available,
        disabled: Mbeditor.configuration.ruby_lsp == false,
        state: health[:state] || :stopped,
        restarts: health[:restarts] || 0,
        error: health[:error]
      }
      payload[:reason] = ruby_lsp_unavailable_reason unless available
      payload
    rescue StandardError => e
      { available: false, disabled: false, state: :failed, restarts: 0, error: e.message }
    end

    # Dispatches to RubyLspResultTranslator (definition/hover/completion/raw —
    # sanitizes every file:// URI, see that module for the trust-boundary
    # rationale) or to LspDiagnosticsTranslator for diagnostics, which has its
    # own interface (no workspace_root) and is shared with the plain-rubocop
    # /lint path.
    def translate_ruby_lsp_result(kind, result, uri = nil)
      case kind
      when "definition"  then RubyLspResultTranslator.definition(result, workspace_root: workspace_root)
      when "hover"       then RubyLspResultTranslator.hover(result, workspace_root: workspace_root)
      when "completion"  then RubyLspResultTranslator.completion(result)
      when "diagnostics" then LspDiagnosticsTranslator.call(result, uri)
      when *RUBY_LSP_RAW then RubyLspResultTranslator.raw(result, workspace_root: workspace_root)
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
