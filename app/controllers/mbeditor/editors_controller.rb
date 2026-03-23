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

    ALLOWED_EXTENSIONS = %w[
      rb js jsx ts tsx css scss sass html erb haml slim
      json yaml yml md txt gemspec gemfile rakefile
      gitignore env sh bash zsh conf config toml
    ].freeze

    IMAGE_EXTENSIONS = %w[png jpg jpeg gif svg ico webp bmp avif].freeze
    MAX_OPEN_FILE_SIZE_BYTES = 5 * 1024 * 1024
    RG_AVAILABLE = system("which rg > /dev/null 2>&1")
    RUBOCOP_TIMEOUT_SECONDS = 15

    # GET /mbeditor — renders the IDE shell
    def index
      render layout: "mbeditor/application"
    end

    # GET /mbeditor/ping — heartbeat for the frontend connectivity check
    def ping
      render json: { ok: true }
    end

    # GET /mbeditor/workspace — metadata about current workspace root
    def workspace
      render json: {
        rootName: workspace_root.basename.to_s,
        rootPath: workspace_root.to_s,
        rubocopAvailable: rubocop_available?,
        hamlLintAvailable: haml_lint_available?,
        gitAvailable: git_available?,
        blameAvailable: git_blame_available?
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
    rescue StandardError
      render json: {}
    end

    # POST /mbeditor/state — save workspace state
    def save_state
      path = workspace_root.join("tmp", "mbeditor_workspace.json")
      File.write(path, params[:state].to_json)
      render json: { ok: true }
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_entity
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
      render json: { error: e.message }, status: :unprocessable_entity
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

      File.write(path, params[:code])
      render json: { ok: true, path: relative_path(path) }
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # POST /mbeditor/create_file — create file and parent directories if needed
    def create_file
      path = resolve_path(params[:path])
      return render json: { error: "Forbidden" }, status: :forbidden unless path
      return render json: { error: "Cannot create file in this path" }, status: :forbidden if path_blocked_for_operations?(path)
      return render json: { error: "File already exists" }, status: :unprocessable_entity if File.exist?(path)

      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, params[:code].to_s)

      render json: { ok: true, type: "file", path: relative_path(path), name: File.basename(path) }
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # POST /mbeditor/create_dir — create directory recursively
    def create_dir
      path = resolve_path(params[:path])
      return render json: { error: "Forbidden" }, status: :forbidden unless path
      return render json: { error: "Cannot create directory in this path" }, status: :forbidden if path_blocked_for_operations?(path)
      return render json: { error: "Path already exists" }, status: :unprocessable_entity if File.exist?(path)

      FileUtils.mkdir_p(path)
      render json: { ok: true, type: "folder", path: relative_path(path), name: File.basename(path) }
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # PATCH /mbeditor/rename — rename file or directory
    def rename
      old_path = resolve_path(params[:path])
      new_path = resolve_path(params[:new_path])
      return render json: { error: "Forbidden" }, status: :forbidden unless old_path && new_path
      return render json: { error: "Path not found" }, status: :not_found unless File.exist?(old_path)
      return render json: { error: "Target path already exists" }, status: :unprocessable_entity if File.exist?(new_path)
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
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # Backward compatibility for stale route/action caches.
    def rename_path
      rename
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
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # Backward compatibility for stale route/action caches.
    def delete_path
      destroy_path
    end

    # GET /mbeditor/search?q=...
    def search
      query = params[:q].to_s.strip
      return render json: [] if query.blank?

      results = []
      cmd = if RG_AVAILABLE
              ["rg", "--json", "--max-count", "30", "--", query, workspace_root.to_s]
            else
              ["grep", "-rn", "-F", "-m", "30", query, workspace_root.to_s]
            end

      unless RG_AVAILABLE
        excluded_dirnames.each do |dir_name|
          cmd.insert(2, "--exclude-dir=#{dir_name}")
        end
      end

      if RG_AVAILABLE
        output, = Open3.capture2(*cmd)
        output.lines.each do |line|
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
        output, = Open3.capture2(*cmd)
        output.lines.first(50).each do |line|
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

      render json: results
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # GET /mbeditor/git_status
    def git_status
      output, status = Open3.capture2("git", "-C", workspace_root.to_s, "status", "--porcelain")
      branch_output, = Open3.capture2("git", "-C", workspace_root.to_s, "branch", "--show-current")
      files = output.lines.map do |line|
        { status: line[0..1].strip, path: line[3..].strip }
      end
      render json: { ok: status.success?, files: files, branch: branch_output.strip }
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # GET /mbeditor/git_info
    def git_info
      repo = workspace_root.to_s
      branch_output, branch_status = Open3.capture2("git", "-C", repo, "branch", "--show-current")
      unless branch_status.success?
        return render json: { ok: false, error: "Unable to determine current branch" }, status: :unprocessable_entity
      end

      branch = branch_output.strip
      working_output, working_status = Open3.capture2("git", "-C", repo, "status", "--porcelain")
      working_tree = working_status.success? ? parse_porcelain_status(working_output) : []

      # Annotate each working-tree file with added/removed line counts
      numstat_out, = Open3.capture2("git", "-C", repo, "diff", "--numstat", "HEAD")
      numstat_map  = parse_numstat(numstat_out)
      working_tree = working_tree.map { |f| f.merge(numstat_map.fetch(f[:path], {})) }

      upstream_output, upstream_status = Open3.capture2("git", "-C", repo, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
      upstream_branch = upstream_status.success? ? upstream_output.strip : nil

      ahead_count = 0
      behind_count = 0
      unpushed_files = []
      unpushed_commits = []

      if upstream_branch.present?
        counts_output, counts_status = Open3.capture2("git", "-C", repo, "rev-list", "--left-right", "--count", "HEAD...#{upstream_branch}")
        if counts_status.success?
          ahead_str, behind_str = counts_output.strip.split("\t", 2)
          ahead_count = ahead_str.to_i
          behind_count = behind_str.to_i
        end

        unpushed_output, unpushed_status = Open3.capture2("git", "-C", repo, "diff", "--name-status", "#{upstream_branch}..HEAD")
        if unpushed_status.success?
          unpushed_files   = parse_name_status(unpushed_output)
          unp_numstat_out, = Open3.capture2("git", "-C", repo, "diff", "--numstat", "#{upstream_branch}..HEAD")
          unp_numstat_map  = parse_numstat(unp_numstat_out)
          unpushed_files   = unpushed_files.map { |f| f.merge(unp_numstat_map.fetch(f[:path], {})) }
        end

        unpushed_log_output, unpushed_log_status = Open3.capture2("git", "-C", repo, "log", "#{upstream_branch}..HEAD", "--pretty=format:%H%x1f%s%x1f%an%x1f%aI%x1e")
        unpushed_commits = parse_git_log(unpushed_log_output) if unpushed_log_status.success?
      end

      branch_log_output, branch_log_status = Open3.capture2("git", "-C", repo, "log", branch, "-n", "100", "--pretty=format:%H%x1f%s%x1f%an%x1f%aI%x1e")
      branch_commits = branch_log_status.success? ? parse_git_log(branch_log_output) : []

      render json: {
        ok: true,
        branch: branch,
        upstreamBranch: upstream_branch,
        ahead: ahead_count,
        behind: behind_count,
        workingTree: working_tree,
        unpushedFiles: unpushed_files,
        unpushedCommits: unpushed_commits,
        branchCommits: branch_commits
      }
    rescue StandardError => e
      render json: { ok: false, error: e.message }, status: :unprocessable_entity
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
          return render json: { error: "haml-lint not available", markers: [] }, status: :unprocessable_entity
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
          message: "[#{offense['cop_name']}] #{offense['message']}",
          startLine: offense.dig("location", "start_line") || offense.dig("location", "line"),
          startCol: (offense.dig("location", "start_column") || offense.dig("location", "column") || 1) - 1,
          endLine: offense.dig("location", "last_line") || offense.dig("location", "line"),
          endCol: offense.dig("location", "last_column") || offense.dig("location", "column") || 1
        }
      end

      render json: { markers: markers, summary: result["summary"] }
    rescue StandardError => e
      render json: { error: e.message, markers: [] }, status: :unprocessable_entity
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
      render json: { error: e.message }, status: :unprocessable_entity
    end

    private

    def verify_mbeditor_client
      return if request.headers['X-Mbeditor-Client'] == '1'

      render plain: 'Forbidden', status: :forbidden
    end

    def workspace_root
      @workspace_root ||= begin
        configured_root = Mbeditor.configuration.workspace_root
        if configured_root.present?
          Pathname.new(configured_root.to_s)
        else
          # Default to the git root of Rails.root so that paths returned by git
          # commands (which are always relative to the git root) align with the
          # file-tree paths used by the file service.
          rails_root = Rails.root.to_s
          out, status = Open3.capture2("git", "-C", rails_root, "rev-parse", "--show-toplevel")
          Pathname.new(status.success? && out.strip.present? ? out.strip : rails_root)
        end
      rescue StandardError
        Rails.root
      end
    end

    # Expand path and confirm it's inside workspace_root
    def resolve_path(raw)
      return nil if raw.blank?

      root = workspace_root.to_s
      full = File.expand_path(raw.to_s, root)
      full.start_with?(root + "/") || full == root ? full : nil
    end

    def relative_path(full)
      root = workspace_root.to_s
      return "" if full == root

      full.delete_prefix(root + "/")
    end

    def path_blocked_for_operations?(full_path)
      rel = relative_path(full_path)
      return true if rel.blank?

      excluded_path?(rel, File.basename(full_path))
    end

    def build_tree(dir, max_depth: 10, depth: 0)
      return [] if depth >= max_depth

      entries = Dir.entries(dir).sort.reject { |entry| entry.start_with?(".") || entry == "." || entry == ".." }
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

      Open3.popen3(env, *cmd) do |stdin, stdout, _stderr, wait_thr|
        stdin.write(stdin_data)
        stdin.close

        timer = Thread.new do
          sleep RUBOCOP_TIMEOUT_SECONDS
          timed_out = true
          Process.kill('KILL', wait_thr.pid)
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
      _out, _err, status = Open3.capture3(*rubocop_command, "--version")
      status.success?
    rescue StandardError
      false
    end

    def haml_lint_available?
      _out, _err, status = Open3.capture3(*haml_lint_command, "--version")
      status.success?
    rescue StandardError
      false
    end

    def git_available?
      _out, status = Open3.capture2("git", "-C", workspace_root.to_s, "rev-parse", "--is-inside-work-tree")
      status.success?
    rescue StandardError
      false
    end

    alias git_blame_available? git_available?

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
      }, status: :payload_too_large
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
