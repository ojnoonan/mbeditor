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
    MAX_OPEN_FILE_SIZE_BYTES = 5 * 1024 * 1024
    RG_AVAILABLE = system("which rg > /dev/null 2>&1")

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
        rubocopAvailable: rubocop_available?,
        rubocopConfigPath: rubocop_config_path,
        hamlLintAvailable: haml_lint_available?,
        gitAvailable: git_available?,
        blameAvailable: git_blame_available?,
        redmineEnabled: Mbeditor.configuration.redmine_enabled == true,
        testAvailable: test_available?,
        actionCableEnabled: action_cable_enabled?
      }
    end

    # GET /mbeditor/files — recursive file tree
    def files
      root = workspace_root.to_s
      cached = cached_file_tree(root)
      return render json: cached if cached

      tree = build_tree(root)
      store_file_tree(root, tree)
      render json: tree
    end

    # GET /mbeditor/state — load workspace state
    def state
      path = workspace_root.join("tmp", "mbeditor_workspace.json")
      if File.exist?(path)
        render json: JSON.parse(File.read(path))
      else
        render json: {}
      end
    rescue Errno::ENOENT
      render json: {}
    rescue JSON::ParserError
      render json: {}
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    STATE_MAX_BYTES = 1 * 1024 * 1024

    # POST /mbeditor/state — save workspace state
    def save_state
      raw = params[:state]
      raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
      payload = raw.to_json
      return render json: { error: "State payload too large" }, status: :content_too_large if payload.bytesize > STATE_MAX_BYTES

      path = workspace_root.join("tmp", "mbeditor_workspace.json")
      FileUtils.mkdir_p(workspace_root.join("tmp"))
      File.open(path, File::RDWR | File::CREAT) do |f|
        f.flock(File::LOCK_EX)
        f.truncate(0)
        f.rewind
        f.write(payload)
      end
      render json: { ok: true }
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    SAFE_BRANCH_NAME = /\A[a-zA-Z0-9._\-\/]+\z/

    # GET /mbeditor/branch_state?branch=... — load per-branch pane state
    def branch_state
      branch = sanitize_branch_name(params[:branch])
      return render json: {}, status: :bad_request unless branch

      path = workspace_root.join("tmp", "mbeditor_branch_states.json")
      if File.exist?(path)
        all = JSON.parse(File.read(path))
        render json: (all[branch] || {})
      else
        render json: {}
      end
    rescue StandardError
      render json: {}
    end
    def save_branch_state
      branch = sanitize_branch_name(params[:branch])
      return render json: { error: "Invalid branch name" }, status: :bad_request unless branch

      payload = params[:state].to_unsafe_h
      return render json: { error: "State payload too large" }, status: :content_too_large if payload.to_json.bytesize > STATE_MAX_BYTES

      path = workspace_root.join("tmp", "mbeditor_branch_states.json")
      FileUtils.mkdir_p(workspace_root.join("tmp"))
      File.open(path, File::RDWR | File::CREAT) do |f|
        f.flock(File::LOCK_EX)
        existing = f.size > 0 ? JSON.parse(f.read) : {}
        existing[branch] = payload
        f.truncate(0)
        f.rewind
        f.write(existing.to_json)
      end
      render json: { ok: true }
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    # POST /mbeditor/prune_branch_states — remove states for deleted branches
    def prune_branch_states
      state_path = workspace_root.join("tmp", "mbeditor_branch_states.json")
      return render json: { pruned: [] } unless File.exist?(state_path)

      root = workspace_root.to_s
      out, _err, status = Open3.capture3("git", "-C", root, "branch", "--format=%(refname:short)")
      return render json: { pruned: [] } unless status.success?

      local_branches = out.split("\n").map(&:strip).reject(&:empty?)
      pruned = []
      File.open(state_path, File::RDWR) do |f|
        f.flock(File::LOCK_EX)
        all = JSON.parse(f.read) rescue {}
        pruned = all.keys - local_branches
        if pruned.any?
          pruned.each { |b| all.delete(b) }
          f.truncate(0)
          f.rewind
          f.write(all.to_json)
        end
      end
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
      return render_file_too_large(size) if size > MAX_OPEN_FILE_SIZE_BYTES

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
      return render_file_too_large(size) if size > MAX_OPEN_FILE_SIZE_BYTES

      send_file path, disposition: "inline"
    end

    # POST /mbeditor/file — save file
    def save
      path = resolve_path(params[:path])
      return render json: { error: "Forbidden" }, status: :forbidden unless path
      return render json: { error: "Cannot write to this path" }, status: :forbidden if path_blocked_for_operations?(path)

      content = params[:code].to_s
      return render_file_too_large(content.bytesize) if content.bytesize > MAX_OPEN_FILE_SIZE_BYTES

      File.write(path, content)
      broadcast_files_changed
      render json: { ok: true, path: relative_path(path) }
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    # POST /mbeditor/create_file — create file and parent directories if needed
    def create_file
      path = resolve_path(params[:path])
      return render json: { error: "Forbidden" }, status: :forbidden unless path
      return render json: { error: "Cannot create file in this path" }, status: :forbidden if path_blocked_for_operations?(path)
      return render json: { error: "File already exists" }, status: :unprocessable_content if File.exist?(path)

      content = params[:code].to_s
      return render_file_too_large(content.bytesize) if content.bytesize > MAX_OPEN_FILE_SIZE_BYTES

      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
      broadcast_files_changed

      render json: { ok: true, type: "file", path: relative_path(path), name: File.basename(path) }
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    # POST /mbeditor/create_dir — create directory recursively
    def create_dir
      path = resolve_path(params[:path])
      return render json: { error: "Forbidden" }, status: :forbidden unless path
      return render json: { error: "Cannot create directory in this path" }, status: :forbidden if path_blocked_for_operations?(path)
      return render json: { error: "Path already exists" }, status: :unprocessable_content if File.exist?(path)

      FileUtils.mkdir_p(path)
      broadcast_files_changed
      render json: { ok: true, type: "folder", path: relative_path(path), name: File.basename(path) }
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    # PATCH /mbeditor/rename — rename file or directory
    def rename
      old_path = resolve_path(params[:path])
      new_path = resolve_path(params[:new_path])
      return render json: { error: "Forbidden" }, status: :forbidden unless old_path && new_path
      return render json: { error: "Path not found" }, status: :not_found unless File.exist?(old_path)
      return render json: { error: "Target path already exists" }, status: :unprocessable_content if File.exist?(new_path)
      return render json: { error: "Cannot rename this path" }, status: :forbidden if path_blocked_for_operations?(old_path) || path_blocked_for_operations?(new_path)

      FileUtils.mkdir_p(File.dirname(new_path))
      FileUtils.mv(old_path, new_path)
      broadcast_files_changed

      render json: {
        ok: true,
        oldPath: relative_path(old_path),
        path: relative_path(new_path),
        name: File.basename(new_path)
      }
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    # DELETE /mbeditor/delete — remove file or directory
    def destroy_path
      path = resolve_path(params[:path])
      return render json: { error: "Forbidden" }, status: :forbidden unless path
      # Idempotent: if already gone the desired state is already achieved.
      return render json: { ok: true } unless File.exist?(path)
      return render json: { error: "Cannot delete this path" }, status: :forbidden if path_blocked_for_operations?(path)

      if File.directory?(path)
        FileUtils.rm_rf(path)
        broadcast_files_changed
        render json: { ok: true, type: "folder", path: relative_path(path) }
      else
        File.delete(path)
        broadcast_files_changed
        render json: { ok: true, type: "file", path: relative_path(path) }
      end
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
                  workspace = RubyDefinitionService.call(
                    workspace_root,
                    symbol,
                    excluded_dirnames: excluded_dirnames,
                    excluded_paths:    excluded_paths,
                    included_dirs:     ruby_def_include_dirs
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

    # GET /mbeditor/module_members?name=ArticlesHelper
    # Returns methods defined in the workspace file that defines the named module/class.
    def module_members
      name = params[:name].to_s.strip
      return render json: { error: "Invalid name" }, status: :bad_request \
        unless name.match?(/\A[A-Z][a-zA-Z0-9_]*\z/)

      file = RubyDefinitionService.module_defined_in(
        workspace_root, name,
        excluded_dirnames: excluded_dirnames,
        excluded_paths:    excluded_paths,
        included_dirs:     ruby_def_include_dirs
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

      # Ensure workspace is scanned so include_calls are populated in the cache.
      # Fast no-op on subsequent calls (mtime checks only).
      RubyDefinitionService.scan(workspace_root,
                                 excluded_dirnames: excluded_dirnames,
                                 excluded_paths:    excluded_paths,
                                 included_dirs:     ruby_def_include_dirs)

      module_names = RubyDefinitionService.includes_in_file(path)
      includes = module_names.filter_map do |mod_name|
        mod_file = RubyDefinitionService.module_defined_in(
          workspace_root, mod_name,
          excluded_dirnames: excluded_dirnames,
          excluded_paths:    excluded_paths,
          included_dirs:     ruby_def_include_dirs
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

      unused = UnusedMethodsService.call(
        workspace_root, path,
        excluded_dirnames: excluded_dirnames,
        excluded_paths:    excluded_paths
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
      count_thread = offset == 0 ? Thread.new { count_search_results(query, use_regex: use_regex, match_case: match_case, whole_word: whole_word) } : nil

      results   = stream_search_results(query, needed, use_regex: use_regex, match_case: match_case, whole_word: whole_word)
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

    MAX_REPLACE_FILES = 500

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

      # Collect all unique file paths that have at least one match.
      # Use a large limit to get all matching files; stream_search_results handles deduplication by file internally.
      raw_results = stream_search_results(query, 10_000, use_regex: use_regex, match_case: match_case, whole_word: whole_word)
      file_paths = raw_results.map { |r| r[:file] }.uniq

      # Fix 3: Cap the number of files to process
      if file_paths.length > MAX_REPLACE_FILES
        return render json: { error: "Too many files matched (#{file_paths.length}). Narrow your search." }, status: :unprocessable_entity
      end

      replaced_count = 0
      files_affected = []
      errors = []

      # Build the Ruby Regexp to use for gsub
      begin
        pattern = if use_regex
          flags = match_case ? 0 : Regexp::IGNORECASE
          Regexp.new(whole_word ? "\\b(?:#{query})\\b" : query, flags)
        else
          flags = match_case ? 0 : Regexp::IGNORECASE
          Regexp.new(whole_word ? "\\b#{Regexp.escape(query)}\\b" : Regexp.escape(query), flags)
        end
      rescue RegexpError => e
        return render json: { error: "Invalid regex: #{e.message}" }, status: :bad_request
      end

      file_paths.each do |rel_path|
        full_path = resolve_path(rel_path)
        unless full_path
          errors << { file: rel_path, error: "Forbidden" }
          next
        end

        # Fix 2: Check path_blocked_for_operations?
        if path_blocked_for_operations?(full_path)
          errors << { file: rel_path, error: "Forbidden" }
          next
        end

        unless File.file?(full_path)
          errors << { file: rel_path, error: "File not found" }
          next
        end
        if File.size(full_path) > MAX_OPEN_FILE_SIZE_BYTES
          errors << { file: rel_path, error: "File too large" }
          next
        end

        # Fix 1: Wrap per-file gsub/scan in a timeout to prevent ReDoS
        begin
          Timeout::timeout(5) do
            content = File.binread(full_path).force_encoding("UTF-8")
            replacements_in_file = content.scan(pattern).length
            new_content = content.gsub(pattern, replacement)

            # Fix 4: Use new_content != content instead of delta logic
            if new_content != content
              File.binwrite(full_path, new_content.encode("UTF-8", invalid: :replace, undef: :replace))
              files_affected << rel_path
              replaced_count += replacements_in_file
            end
          end
        rescue Timeout::Error
          errors << { file: rel_path, error: "Timed out processing file" }
          next
        rescue StandardError => e
          errors << { file: rel_path, error: e.message }
          next
        end
      end

      # Fix 5: Surface partial failure
      render json: {
        replaced_count: replaced_count,
        files_affected: files_affected,
        errors: errors,
        partial: errors.any? && files_affected.any?
      }
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    # GET /mbeditor/git_status
    def git_status
      output, _err, status = Open3.capture3("git", "-C", workspace_root.to_s, "status", "--porcelain")
      branch = GitService.current_branch(workspace_root.to_s) || ""
      files = parse_porcelain_status(output)
      render json: { ok: status.success?, files: files, branch: branch }
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    # GET /mbeditor/git_info
    def git_info
      repo = workspace_root.to_s
      cached = cached_git_info(repo)
      return render json: cached if cached

      branch = GitService.current_branch(repo)
      unless branch
        return render json: { ok: false, error: "Unable to determine current branch" }, status: :unprocessable_content
      end

      # Wave 1: all independent git reads run in parallel
      status_t   = Thread.new { Open3.capture3("git", "-C", repo, "status", "--porcelain") }
      numstat_t  = Thread.new { Open3.capture3("git", "-C", repo, "diff", "--numstat", "HEAD") }
      upstream_t = Thread.new { Open3.capture3("git", "-C", repo, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}") }
      base_t     = Thread.new { GitService.find_branch_base(repo, branch) }

      working_output, _err, working_status = status_t.value
      working_tree = working_status.success? ? parse_porcelain_status(working_output) : []

      numstat_out = numstat_t.value.first
      numstat_map = GitService.parse_numstat(numstat_out)
      working_tree = working_tree.map { |f| f.merge(numstat_map.fetch(f[:path], {})) }

      upstream_output, _err, upstream_status = upstream_t.value
      upstream_branch = upstream_status.success? ? upstream_output.strip : nil
      upstream_branch = nil unless upstream_branch&.match?(%r{\A[\w./-]+\z})

      # Determine the branch's fork point relative to a base branch (develop/main/master).
      # This ensures History and Changes only show work unique to this branch.
      base_sha, base_ref = base_t.value

      ahead_count    = 0
      behind_count   = 0
      unpushed_files = []
      unpushed_commits = []
      diff_base = base_sha || upstream_branch

      # Wave 2: conditional parallel reads that depend on Wave 1 results
      wave2 = {}
      wave2[:counts]    = Thread.new { Open3.capture3("git", "-C", repo, "rev-list", "--left-right", "--count", "HEAD...#{upstream_branch}") } if upstream_branch.present?
      wave2[:unp_log]   = Thread.new { Open3.capture3("git", "-C", repo, "log", "#{upstream_branch}..HEAD", "--pretty=format:%H%x1f%s%x1f%an%x1f%aI%x1e") } if upstream_branch.present?
      wave2[:diff_name] = Thread.new { Open3.capture3("git", "-C", repo, "diff", "--name-status", "#{diff_base}..HEAD") } if diff_base.present?
      wave2[:diff_num]  = Thread.new { Open3.capture3("git", "-C", repo, "diff", "--numstat", "#{diff_base}..HEAD") } if diff_base.present?
      wave2[:branch_log] = Thread.new do
        if base_sha
          Open3.capture3("git", "-C", repo, "log", "--first-parent", "#{base_sha}..HEAD",
                         "--pretty=format:%H%x1f%s%x1f%an%x1f%aI%x1e")
        else
          Open3.capture3("git", "-C", repo, "log", "--first-parent", branch, "-n", "100",
                         "--pretty=format:%H%x1f%s%x1f%an%x1f%aI%x1e")
        end
      end

      wave2.each_value(&:join)

      if (ct = wave2[:counts])
        counts_output, _err, counts_status = ct.value
        if counts_status.success?
          ahead_str, behind_str = counts_output.strip.split("\t", 2)
          ahead_count  = ahead_str.to_i
          behind_count = behind_str.to_i
        end
      end

      if (ul = wave2[:unp_log])
        unpushed_log_output, _err, unpushed_log_status = ul.value
        unpushed_commits = GitService.parse_git_log(unpushed_log_output) if unpushed_log_status.success?
      end

      if (dn = wave2[:diff_name]) && (dnum = wave2[:diff_num])
        diff_name_out, _err, diff_name_status = dn.value
        if diff_name_status.success?
          unpushed_files  = parse_name_status(diff_name_out)
          unp_numstat_out = dnum.value.first
          unp_numstat_map = GitService.parse_numstat(unp_numstat_out)
          unpushed_files  = unpushed_files.map { |f| f.merge(unp_numstat_map.fetch(f[:path], {})) }
        end
      end

      branch_log_output, _err, branch_log_status = wave2[:branch_log].value
      branch_commits = branch_log_status.success? ? GitService.parse_git_log(branch_log_output) : []

      redmine_ticket_id = nil
      if Mbeditor.configuration.redmine_enabled
        if Mbeditor.configuration.redmine_ticket_source == :branch
          m = branch.match(/\A(\d+)/)
          redmine_ticket_id = m[1] if m
        else
          branch_commits.each do |commit|
            m = commit["title"]&.match(/#(\d+)/)
            if m
              redmine_ticket_id = m[1]
              break
            end
          end
        end
      end

      payload = {
        ok: true,
        branch: branch,
        upstreamBranch: upstream_branch,
        ahead: ahead_count,
        behind: behind_count,
        workingTree: working_tree,
        unpushedFiles: unpushed_files,
        unpushedCommits: unpushed_commits,
        branchCommits: branch_commits,
        branchBaseRef: base_ref,
        redmineTicketId: redmine_ticket_id
      }
      store_git_info(repo, payload)
      render json: payload
    rescue StandardError => e
      render json: { ok: false, error: e.message }, status: :unprocessable_content
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
      _mount = request.script_name.to_s.gsub(%r{(^/+|/+$)}, "")
      base = _mount.empty? ? "" : "/#{_mount}"
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

      filename = File.basename(path)
      code = params[:code] || File.read(path)

      if filename.end_with?('.haml')
        unless haml_lint_available?
          return render json: { error: "haml-lint not available", markers: [] }, status: :unprocessable_content
        end

        markers = run_haml_lint(code)
        return render json: { markers: markers }
      end

      cmd = rubocop_command + ["--no-server", "--stdin", filename, "--format", "json", "--no-color", "--force-exclusion"]
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

        cmd = rubocop_command + ["--no-server", "-A", "--no-color", tmpfile]
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

        cmd = rubocop_command + ["--no-server", "-A", "--no-color", tmpfile]
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
      invalidate_file_tree_cache(root)
      invalidate_git_info_cache(root)

      return unless defined?(ActionCable.server)

      ActionCable.server.broadcast("mbeditor_editor", { type: "files_changed" })
    rescue StandardError
      # Never let a broadcast failure affect the HTTP response
    end

    def sanitize_branch_name(branch)
      return nil if branch.blank?
      str = branch.to_s.strip
      return nil if str.include?('..')
      str.match?(SAFE_BRANCH_NAME) ? str : nil
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

      excluded_path?(rel, File.basename(full_path))
    end

    # Stream search results using popen so we can stop reading early once we
    # have collected `limit` matches (avoids buffering the entire rg/grep output
    # in memory when searching large codebases for common tokens).
    def stream_search_results(query, limit, use_regex: false, match_case: false, whole_word: false)
      results = []

      if RG_AVAILABLE
        args = ["rg", "--json", "--no-ignore"]
        args << "-F" unless use_regex
        args << "--ignore-case" unless match_case
        args << "--word-regexp" if whole_word
        excluded_paths.each { |p| args << "--glob=!#{p}" }
        args += ["--", query, workspace_root.to_s]

        IO.popen(args, err: File::NULL) do |io|
          io.each_line do |raw|
            break if results.length >= limit

            begin
              data = JSON.parse(raw)
            rescue JSON::ParserError => e
              Rails.logger.warn("[mbeditor] search: malformed rg JSON line: #{e.message}")
              next
            end
            next unless data["type"] == "match"

            md = data["data"]
            results << {
              file: relative_path(md.dig("path", "text").to_s),
              line: md.dig("line_number"),
              text: md.dig("lines", "text").to_s.strip
            }
          end
        end
      else
        base_flags = use_regex ? "-E" : "-F"
        args = ["grep", "-rn", base_flags]
        args << "-i" unless match_case
        args << "-w" if whole_word
        excluded_dirnames.select { |d| d.match?(/\A[\w.\/-]+\z/) }.each { |d| args << "--exclude-dir=#{d}" }
        args += [query, workspace_root.to_s]

        IO.popen(args, err: File::NULL) do |io|
          io.each_line do |raw|
            break if results.length >= limit

            raw.chomp!
            next unless raw =~ /\A(.+?):(\d+):(.*)\z/

            file_path = Regexp.last_match(1)
            next unless file_path.start_with?(workspace_root.to_s)

            rel = relative_path(file_path)
            next if excluded_path?(rel, File.basename(file_path))

            results << {
              file: rel,
              line: Regexp.last_match(2).to_i,
              text: Regexp.last_match(3).strip
            }
          end
        end
      end

      results
    end

    # Count total matching lines across the workspace using rg --count (or grep -c).
    # Fast: rg just counts without extracting context. Runs in a background thread.
    def count_search_results(query, use_regex: false, match_case: false, whole_word: false)
      total = 0
      if RG_AVAILABLE
        args = ["rg", "--count", "--no-ignore"]
        args << "-F" unless use_regex
        args << "--ignore-case" unless match_case
        args << "--word-regexp" if whole_word
        excluded_paths.each { |p| args << "--glob=!#{p}" }
        args += ["--", query, workspace_root.to_s]
        IO.popen(args, err: File::NULL) do |io|
          io.each_line { |line| total += line.strip.split(":").last.to_i rescue 0 }
        end
      else
        base_flags = use_regex ? "-E" : "-F"
        args = ["grep", "-rc", base_flags]
        args << "-i" unless match_case
        args << "-w" if whole_word
        excluded_dirnames.each { |d| args << "--exclude-dir=#{d}" }
        args += [query, workspace_root.to_s]
        IO.popen(args, err: File::NULL) do |io|
          io.each_line { |line| total += line.strip.split(":").last.to_i rescue 0 }
        end
      end
      total
    rescue StandardError
      0
    end

    def build_tree(dir, max_depth: 10, depth: 0)
      return [] if depth >= max_depth

      entries = Dir.entries(dir).sort.reject { |entry| entry == "." || entry == ".." }
      entries.filter_map do |name|
        full = File.join(dir, name)
        rel = relative_path(full)

        if File.directory?(full)
          node = { name: name, type: "folder", path: rel, children: build_tree(full, depth: depth + 1) }
          node[:excluded] = true if excluded_path?(rel, name)
          node
        else
          size = File.size(full) rescue nil
          node = { name: name, type: "file", path: rel, size: size }
          node[:excluded] = true if excluded_path?(rel, name)
          node
        end
      end
    rescue Errno::EACCES
      []
    end

    def excluded_paths
      Array(Mbeditor.configuration.excluded_paths).map(&:to_s).reject(&:blank?)
    end

    def excluded_dirnames
      excluded_paths.filter { |path| !path.include?("/") }
    end

    def ruby_def_include_dirs
      Array(Mbeditor.configuration.ruby_def_include_dirs).map(&:to_s).reject(&:blank?)
    end

    def excluded_path?(relative_path, name)
      excluded_paths.any? do |pattern|
        if pattern.include?("/")
          relative_path == pattern || relative_path.start_with?("#{pattern}/")
        else
          name == pattern || relative_path.split("/").include?(pattern)
        end
      end
    end

    def run_with_timeout(env, cmd, stdin_data:)
      timeout_seconds = Mbeditor.configuration.lint_timeout&.to_i
      output = +""; timed_out = false

      Open3.popen3(env, *cmd, pgroup: true) do |stdin, stdout, _stderr, wait_thr|
        stdin.write(stdin_data)
        stdin.close

        timer = if timeout_seconds && timeout_seconds > 0
          Thread.new do
            sleep timeout_seconds
            timed_out = true
            Process.kill('-KILL', wait_thr.pid)
          rescue Errno::ESRCH
            nil
          end
        end

        output = stdout.read
        wait_thr.value
        timer&.kill
      end

      raise "RuboCop timed out after #{timeout_seconds} seconds" if timed_out

      output
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

    def rubocop_command
      command = Mbeditor.configuration.rubocop_command.to_s.strip
      command = "rubocop" if command.empty?
      tokens = Shellwords.split(command)

      local_bin = workspace_root.join("bin", "rubocop")
      return [local_bin.to_s] if tokens == ["rubocop"] && local_bin.exist?

      tokens
    rescue ArgumentError
      ["rubocop"]
    end

    def rubocop_config_path
      candidate = workspace_root.join(".rubocop.yml")
      candidate.exist? ? ".rubocop.yml" : nil
    end

    PROBE_MUTEX     = Mutex.new
    GIT_INFO_MUTEX  = Mutex.new
    FILE_TREE_MUTEX = Mutex.new
    private_constant :PROBE_MUTEX, :GIT_INFO_MUTEX, :FILE_TREE_MUTEX

    def rubocop_available?
      key = Mbeditor.configuration.rubocop_command.to_s
      probe_cached(:@rubocop_available_cache, key) do
        _out, _err, status = Open3.capture3(*rubocop_command, "--version")
        status.success?
      end
    end

    def haml_lint_available?
      cmd = haml_lint_command
      key = cmd.join(" ")
      probe_cached(:@haml_lint_available_cache, key) do
        _out, _err, status = Open3.capture3(*cmd, "--version")
        status.success?
      end
    end

    def git_available?
      key = workspace_root.to_s
      probe_cached(:@git_available_cache, key) do
        _out, _err, status = Open3.capture3("git", "-C", key, "rev-parse", "--is-inside-work-tree")
        status.success?
      end
    end

    def cached_git_info(repo, ttl: 5)
      GIT_INFO_MUTEX.synchronize do
        cache = self.class.instance_variable_get(:@git_info_cache) || {}
        entry = cache[repo]
        return entry[:data] if entry && (Process.clock_gettime(Process::CLOCK_MONOTONIC) - entry[:ts]) < ttl
      end
      nil
    end

    def store_git_info(repo, data)
      GIT_INFO_MUTEX.synchronize do
        cache = self.class.instance_variable_get(:@git_info_cache) || {}
        cache[repo] = { ts: Process.clock_gettime(Process::CLOCK_MONOTONIC), data: data }
        self.class.instance_variable_set(:@git_info_cache, cache)
      end
    end

    def invalidate_git_info_cache(repo)
      GIT_INFO_MUTEX.synchronize do
        cache = self.class.instance_variable_get(:@git_info_cache) || {}
        cache.delete(repo)
        self.class.instance_variable_set(:@git_info_cache, cache)
      end
    end

    def cached_file_tree(root, ttl: 15)
      FILE_TREE_MUTEX.synchronize do
        cache = self.class.instance_variable_get(:@file_tree_cache) || {}
        entry = cache[root]
        return entry[:data] if entry && (Process.clock_gettime(Process::CLOCK_MONOTONIC) - entry[:ts]) < ttl
      end
      nil
    end

    def store_file_tree(root, data)
      FILE_TREE_MUTEX.synchronize do
        cache = self.class.instance_variable_get(:@file_tree_cache) || {}
        cache[root] = { ts: Process.clock_gettime(Process::CLOCK_MONOTONIC), data: data }
        self.class.instance_variable_set(:@file_tree_cache, cache)
      end
    end

    def invalidate_file_tree_cache(root)
      FILE_TREE_MUTEX.synchronize do
        cache = self.class.instance_variable_get(:@file_tree_cache) || {}
        cache.delete(root)
        self.class.instance_variable_set(:@file_tree_cache, cache)
      end
    end

    def probe_cached(ivar, key, &block)
      PROBE_MUTEX.synchronize do
        cache = self.class.instance_variable_get(ivar) ||
                self.class.instance_variable_set(ivar, {})
        unless cache.key?(key)
          cache[key] = begin
            block.call
          rescue StandardError
            false
          end
        end
        cache[key]
      end
    end

    alias git_blame_available? git_available?

    def test_available?
      root = workspace_root.to_s
      File.directory?(File.join(root, "test")) || File.directory?(File.join(root, "spec"))
    end

    def haml_lint_command
      workspace_bin = workspace_root.join("bin", "haml-lint")
      return [workspace_bin.to_s] if workspace_bin.exist?

      begin
        [Gem.bin_path("haml_lint", "haml-lint")]
      rescue Gem::Exception, Gem::GemNotFoundException
        ["haml-lint"]
      end
    end

    def run_haml_lint(code)
      markers = []
      Tempfile.create(["mbeditor_haml", ".haml"]) do |f|
        f.write(code)
        f.flush
        output, _err, _status = Open3.capture3(*haml_lint_command, "--reporter", "json", "--no-color", f.path)
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

    def parse_porcelain_status(output)
      output.lines.filter_map do |line|
        next if line.length < 4

        path = line[3..].to_s.strip
        next if path.blank?

        { status: line[0..1].strip, path: path }
      end
    end

    def parse_name_status(output)
      output.lines.filter_map do |line|
        parts = line.strip.split("\t")
        next if parts.empty?

        status = parts[0].to_s.strip
        path = parts.last.to_s.strip
        next if path.blank?

        { status: status, path: path }
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
        error: "File is too large to open (#{human_size(size)}). Limit is #{human_size(MAX_OPEN_FILE_SIZE_BYTES)}."
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
