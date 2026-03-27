# frozen_string_literal: true

require "fileutils"
require "open3"
require "shellwords"
require "tempfile"
require "tmpdir"

module Mbeditor
  class EditorsController < ApplicationController
    skip_before_action :verify_authenticity_token
    before_action :ensure_allowed_environment!
    before_action :verify_mbeditor_client, unless: -> { request.get? || request.head? }

    IMAGE_EXTENSIONS = %w[png jpg jpeg gif svg ico webp bmp avif].freeze
    MAX_OPEN_FILE_SIZE_BYTES = 5 * 1024 * 1024
    RG_AVAILABLE = system("which rg > /dev/null 2>&1")
    RUBOCOP_TIMEOUT_SECONDS = 15

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
        hamlLintAvailable: haml_lint_available?,
        gitAvailable: git_available?,
        blameAvailable: git_blame_available?,
        redmineEnabled: Mbeditor.configuration.redmine_enabled == true,
        testAvailable: test_available?
      }
    end

    # GET /mbeditor/files — recursive file tree
    def files
      tree = build_tree(workspace_root.to_s)
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
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    # POST /mbeditor/state — save workspace state
    def save_state
      path = workspace_root.join("tmp", "mbeditor_workspace.json")
      File.write(path, params[:state].to_json)
      render json: { ok: true }
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    # GET /mbeditor/file?path=...
    def show
      path = resolve_path(params[:path])
      return render json: { error: "Forbidden" }, status: :forbidden unless path

      return render json: { error: "Not found" }, status: :not_found unless File.file?(path)

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

      content = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace)
      render json: { path: relative_path(path), content: content }
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
      return render json: { error: "Path not found" }, status: :not_found unless File.exist?(path)
      return render json: { error: "Cannot delete this path" }, status: :forbidden if path_blocked_for_operations?(path)

      if File.directory?(path)
        FileUtils.rm_rf(path)
        render json: { ok: true, type: "folder", path: relative_path(path) }
      else
        File.delete(path)
        render json: { ok: true, type: "file", path: relative_path(path) }
      end
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    # GET /mbeditor/search?q=...
    def search
      query = params[:q].to_s.strip
      return render json: [] if query.blank?
      return render json: { error: "Query too long" }, status: :bad_request if query.length > 500

      results = []
      cmd = if RG_AVAILABLE
              args = ["rg", "--json", "--max-count", "30"]
              excluded_paths.each { |p| args << "--glob=!#{p}" }
              args + ["--", query, workspace_root.to_s]
            else
              args = ["grep", "-rn", "-F", "-m", "30"]
              excluded_paths.each do |path|
                args << "--exclude-dir=#{path.include?('/') ? File.basename(path) : path}"
              end
              args + [query, workspace_root.to_s]
            end

      if RG_AVAILABLE
        output, = Open3.capture3(*cmd)
        output.lines.each do |line|
          break if results.length > 30

          data = JSON.parse(line) rescue next
          next unless data["type"] == "match"

          match_data = data["data"]
          results << {
            file: relative_path(match_data.dig("path", "text").to_s),
            line: match_data.dig("line_number"),
            text: match_data.dig("lines", "text").to_s.strip
          }
        end
      else
        output, = Open3.capture3(*cmd)
        output.lines.each do |line|
          break if results.length > 30

          line.chomp!
          next unless line =~ /\A(.+?):(\d+):(.*)\z/

          file_path = Regexp.last_match(1)
          next unless file_path.start_with?(workspace_root.to_s)

          results << {
            file: relative_path(file_path),
            line: Regexp.last_match(2).to_i,
            text: Regexp.last_match(3).strip
          }
        end
      end

      capped = results.length > 30
      render json: { results: results.first(30), capped: capped }
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    # GET /mbeditor/git_status
    def git_status
      output, _err, status = Open3.capture3("git", "-C", workspace_root.to_s, "status", "--porcelain")
      branch = GitService.current_branch(workspace_root.to_s) || ""
      files = output.lines.map do |line|
        { status: line[0..1].strip, path: line[3..].strip }
      end
      render json: { ok: status.success?, files: files, branch: branch }
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    # GET /mbeditor/git_info
    def git_info
      repo = workspace_root.to_s
      branch = GitService.current_branch(repo)
      unless branch
        return render json: { ok: false, error: "Unable to determine current branch" }, status: :unprocessable_content
      end
      working_output, _err, working_status = Open3.capture3("git", "-C", repo, "status", "--porcelain")
      working_tree = working_status.success? ? parse_porcelain_status(working_output) : []

      # Annotate each working-tree file with added/removed line counts
      numstat_out, = Open3.capture3("git", "-C", repo, "diff", "--numstat", "HEAD")
      numstat_map  = parse_numstat(numstat_out)
      working_tree = working_tree.map { |f| f.merge(numstat_map.fetch(f[:path], {})) }

      upstream_output, _err, upstream_status = Open3.capture3("git", "-C", repo, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
      upstream_branch = upstream_status.success? ? upstream_output.strip : nil
      upstream_branch = nil unless upstream_branch&.match?(%r{\A[\w./-]+\z})

      ahead_count = 0
      behind_count = 0
      unpushed_files = []
      unpushed_commits = []

      if upstream_branch.present?
        counts_output, _err, counts_status = Open3.capture3("git", "-C", repo, "rev-list", "--left-right", "--count", "HEAD...#{upstream_branch}")
        if counts_status.success?
          ahead_str, behind_str = counts_output.strip.split("\t", 2)
          ahead_count = ahead_str.to_i
          behind_count = behind_str.to_i
        end

        unpushed_output, _err, unpushed_status = Open3.capture3("git", "-C", repo, "diff", "--name-status", "#{upstream_branch}..HEAD")
        if unpushed_status.success?
          unpushed_files   = parse_name_status(unpushed_output)
          unp_numstat_out, = Open3.capture3("git", "-C", repo, "diff", "--numstat", "#{upstream_branch}..HEAD")
          unp_numstat_map  = parse_numstat(unp_numstat_out)
          unpushed_files   = unpushed_files.map { |f| f.merge(unp_numstat_map.fetch(f[:path], {})) }
        end

        unpushed_log_output, _err, unpushed_log_status = Open3.capture3("git", "-C", repo, "log", "#{upstream_branch}..HEAD", "--pretty=format:%H%x1f%s%x1f%an%x1f%aI%x1e")
        unpushed_commits = parse_git_log(unpushed_log_output) if unpushed_log_status.success?
      end

      branch_log_output, _err, branch_log_status = Open3.capture3("git", "-C", repo, "log", "--first-parent", branch, "-n", "100", "--pretty=format:%H%x1f%s%x1f%an%x1f%aI%x1e")
      branch_commits = branch_log_status.success? ? parse_git_log(branch_log_output) : []

      redmine_ticket_id = nil
      if Mbeditor.configuration.redmine_enabled
        if Mbeditor.configuration.redmine_ticket_source == :branch
          m = branch.match(/\A(\d+)/)
          redmine_ticket_id = m[1] if m
        else
          branch_commits.each do |commit|
            m = commit[:title]&.match(/#(\d+)/)
            if m
              redmine_ticket_id = m[1]
              break
            end
          end
        end
      end

      render json: {
        ok: true,
        branch: branch,
        upstreamBranch: upstream_branch,
        ahead: ahead_count,
        behind: behind_count,
        workingTree: working_tree,
        unpushedFiles: unpushed_files,
        unpushedCommits: unpushed_commits,
        branchCommits: branch_commits,
        redmineTicketId: redmine_ticket_id
      }
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

      cmd = rubocop_command + ["--no-server", "--cache", "false", "--stdin", filename, "--format", "json", "--no-color", "--force-exclusion"]
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

      Tempfile.create(["mbeditor_fix", ext]) do |tmp|
        tmp.write(code)
        tmp.flush

        cmd = rubocop_command + ["--no-server", "--cache", "false", "-A", "--no-color", tmp.path]
        env = { 'RUBOCOP_CACHE_ROOT' => File.join(Dir.tmpdir, 'rubocop') }
        _out, _err, status = Open3.capture3(env, *cmd)

        # exit 0 = no offenses, exit 1 = offenses corrected, exit 2 = error
        unless status.success? || status.exitstatus == 1
          return render json: { fix: nil }
        end

        corrected = File.read(tmp.path, encoding: "UTF-8", invalid: :replace, undef: :replace)
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

    # POST /mbeditor/format — rubocop -A then return corrected content
    def format_file
      path = resolve_path(params[:path])
      return render json: { error: "Forbidden" }, status: :forbidden unless path

      cmd = rubocop_command + ["--no-server", "--cache", "false", "-A", "--no-color", path]
      env = { 'RUBOCOP_CACHE_ROOT' => File.join(Dir.tmpdir, 'rubocop') }
      _out, _err, status = Open3.capture3(env, *cmd)

      content = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace)
      render json: { ok: status.success? || status.exitstatus == 1, content: content }
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    private

    def verify_mbeditor_client
      return if request.headers['X-Mbeditor-Client'] == '1'

      render plain: 'Forbidden', status: :forbidden
    end

    def path_blocked_for_operations?(full_path)
      rel = relative_path(full_path)
      return true if rel.blank?

      excluded_path?(rel, File.basename(full_path))
    end

    def build_tree(dir, max_depth: 10, depth: 0)
      return [] if depth >= max_depth

      entries = Dir.entries(dir).sort.reject { |entry| entry == "." || entry == ".." }
      entries.filter_map do |name|
        full = File.join(dir, name)
        rel = relative_path(full)

        next if excluded_path?(rel, name)

        if File.directory?(full)
          { name: name, type: "folder", path: rel, children: build_tree(full, depth: depth + 1) }
        else
          { name: name, type: "file", path: rel }
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
      output = +""
      timed_out = false

      Open3.popen3(env, *cmd, pgroup: true) do |stdin, stdout, _stderr, wait_thr|
        stdin.write(stdin_data)
        stdin.close

        timer = Thread.new do
          sleep RUBOCOP_TIMEOUT_SECONDS
          timed_out = true
          Process.kill('-KILL', wait_thr.pid)
        rescue Errno::ESRCH
          nil
        end

        output = stdout.read
        wait_thr.value
        timer.kill
      end

      raise "RuboCop timed out after #{RUBOCOP_TIMEOUT_SECONDS} seconds" if timed_out

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

    def rubocop_available?
      # Key on the configured rubocop command so the cache is invalidated if the
      # command changes (e.g., between test cases or after reconfiguration).
      key   = Mbeditor.configuration.rubocop_command.to_s
      cache = self.class.instance_variable_get(:@rubocop_available_cache) ||
              self.class.instance_variable_set(:@rubocop_available_cache, {})
      return cache[key] if cache.key?(key)
      cache[key] = begin
        _out, _err, status = Open3.capture3(*rubocop_command, "--version")
        status.success?
      rescue StandardError
        false
      end
    end

    def haml_lint_available?
      # Key on the resolved command array so workspace-local bin/haml-lint is
      # respected without re-running the probe on every request.
      cmd   = haml_lint_command
      key   = cmd.join(" ")
      cache = self.class.instance_variable_get(:@haml_lint_available_cache) ||
              self.class.instance_variable_set(:@haml_lint_available_cache, {})
      return cache[key] if cache.key?(key)
      cache[key] = begin
        _out, _err, status = Open3.capture3(*cmd, "--version")
        status.success?
      rescue StandardError
        false
      end
    end

    def git_available?
      # Key on workspace path so different directories get their own probe result.
      key   = workspace_root.to_s
      cache = self.class.instance_variable_get(:@git_available_cache) ||
              self.class.instance_variable_set(:@git_available_cache, {})
      return cache[key] if cache.key?(key)
      cache[key] = begin
        _out, _err, status = Open3.capture3("git", "-C", key, "rev-parse", "--is-inside-work-tree")
        status.success?
      rescue StandardError
        false
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
            message: "[#{offense['linter_name']}] #{offense['text']}",
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
      output.lines.map do |line|
        { status: line[0..1].strip, path: line[3..].to_s.strip }
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

    def parse_numstat(output)
      (output || "").lines.each_with_object({}) do |line, map|
        parts = line.strip.split("\t", 3)
        next if parts.length < 3 || parts[0] == "-"

        map[parts[2].strip] = { added: parts[0].to_i, removed: parts[1].to_i }
      end
    end

    def parse_git_log(output)
      output.split("\x1e").filter_map do |entry|
        fields = entry.strip.split("\x1f", 4)
        next unless fields.length == 4

        {
          hash: fields[0],
          title: fields[1],
          author: fields[2],
          date: fields[3]
        }
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
