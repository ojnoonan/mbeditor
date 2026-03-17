# frozen_string_literal: true

module Mbeditor
  class EditorsController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :ensure_allowed_environment!

  IGNORED_DIRS = %w[.git log tmp node_modules].freeze
  ALLOWED_EXTENSIONS = %w[
    rb js jsx ts tsx css scss sass html erb haml slim
    json yaml yml md txt gemspec gemfile rakefile
    gitignore env sh bash zsh conf config toml
  ].freeze

  # GET /mbeditor — renders the IDE shell
  def index
    render layout: "mbeditor/application"
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
  rescue
    render json: {}
  end

  # POST /mbeditor/state — save workspace state
  def save_state
    path = workspace_root.join("tmp", "mbeditor_workspace.json")
    File.write(path, params[:state].to_json)
    render json: { ok: true }
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # GET /mbeditor/file?path=...
  def show
    path = resolve_path(params[:path])
    return render json: { error: "Forbidden" }, status: :forbidden unless path

    unless File.file?(path)
      return render json: { error: "Not found" }, status: :not_found
    end

    content = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace)
    render json: { path: relative_path(path), content: content }
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # GET /mbeditor/raw?path=... — send raw file directly (for images)
  def raw
    path = resolve_path(params[:path])
    return render json: { error: "Forbidden" }, status: :forbidden unless path
    return render json: { error: "Not found" }, status: :not_found unless File.file?(path)

    send_file path, disposition: "inline"
  end

  # POST /mbeditor/file — save file
  def save
    path = resolve_path(params[:path])
    return render json: { error: "Forbidden" }, status: :forbidden unless path

    File.write(path, params[:code])
    render json: { ok: true, path: relative_path(path) }
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # GET /mbeditor/search?q=...
  def search
    query = params[:q].to_s.strip
    return render json: [] if query.blank?

    results = []
    rg_available = system("which rg > /dev/null 2>&1")
    cmd = if rg_available
            ["rg", "--json", "--max-count", "30", "--", query, workspace_root.to_s]
          else
            ["grep", "-rn", "--exclude-dir=.git", "--exclude-dir=tmp", "--exclude-dir=log", "--exclude-dir=node_modules", "-m", "30", query, workspace_root.to_s]
          end

    if rg_available
      output, = Open3.capture2(*cmd)
      output.lines.each do |line|
        data = JSON.parse(line) rescue next
        next unless data["type"] == "match"
        m = data["data"]
        results << {
          file: relative_path(m.dig("path", "text").to_s),
          line: m.dig("line_number"),
          text: m.dig("lines", "text").to_s.strip
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
  rescue => e
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
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # GET /mbeditor/git_info
  def git_info
    repo = workspace_root.to_s
    branch_output, branch_status = Open3.capture2("git", "-C", repo, "branch", "--show-current")
    return render json: { ok: false, error: "Unable to determine current branch" }, status: :unprocessable_entity unless branch_status.success?

    branch = branch_output.strip
    working_output, working_status = Open3.capture2("git", "-C", repo, "status", "--porcelain")
    working_tree = working_status.success? ? parse_porcelain_status(working_output) : []

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
        unpushed_files = parse_name_status(unpushed_output)
      end

      unpushed_log_output, unpushed_log_status = Open3.capture2("git", "-C", repo, "log", "#{upstream_branch}..HEAD", "--pretty=format:%H%x1f%s%x1f%an%x1f%aI%x1e")
      if unpushed_log_status.success?
        unpushed_commits = parse_git_log(unpushed_log_output)
      end
    end

    branch_log_output, branch_log_status = Open3.capture2("git", "-C", repo, "log", branch, "--pretty=format:%H%x1f%s%x1f%an%x1f%aI%x1e")
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
  rescue => e
    render json: { ok: false, error: e.message }, status: :unprocessable_entity
  end

  # POST /mbeditor/reload — touch tmp/restart.txt
  def reload
    FileUtils.touch(workspace_root.join("tmp", "restart.txt"))
    render json: { ok: true, message: "Rails reload triggered" }
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # POST /mbeditor/lint — run rubocop --stdin
  def lint
    path = resolve_path(params[:path])
    return render json: { error: "Forbidden" }, status: :forbidden unless path

    filename = File.basename(path)
    code = params[:code] || File.read(path)

    rubocop_bin = find_rubocop
    cmd = [rubocop_bin, "--no-server", "--cache", "false", "--stdin", filename, "--format", "json",
           "--no-color", "--force-exclusion"]

    env = { "RUBOCOP_CACHE_ROOT" => "/tmp/rubocop" }
    output, _err, _status = Open3.capture3(env, *cmd, stdin_data: code)
    
    # robust json extraction from first `{` to end in stdout
    json_str = output[output.index('{')..-1] rescue nil
    result = json_str ? JSON.parse(json_str) : {}
    offenses = result.dig("files", 0, "offenses") || []

    markers = offenses.map do |o|
      {
        severity:  cop_severity(o["severity"]),
        message:   "[#{o['cop_name']}] #{o['message']}",
        startLine: o.dig("location", "start_line") || o.dig("location", "line"),
        startCol:  (o.dig("location", "start_column") || o.dig("location", "column") || 1) - 1,
        endLine:   o.dig("location", "last_line") || o.dig("location", "line"),
        endCol:    o.dig("location", "last_column") || o.dig("location", "column") || 1
      }
    end

    render json: { markers: markers, summary: result["summary"] }
  rescue => e
    render json: { error: e.message, markers: [] }, status: :unprocessable_entity
  end

  # POST /mbeditor/format — rubocop -A then return corrected content
  def format_file
    path = resolve_path(params[:path])
    return render json: { error: "Forbidden" }, status: :forbidden unless path

    rubocop_bin = find_rubocop
    env = { "RUBOCOP_CACHE_ROOT" => "/tmp/rubocop" }
    _out, _err, status = Open3.capture3(env, rubocop_bin, "--no-server", "--cache", "false", "-A", "--no-color", path)

    content = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace)
    render json: { ok: status.success? || status.exitstatus == 1, content: content }
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def ensure_allowed_environment!
    allowed = Array(Mbeditor.configuration.allowed_environments).map(&:to_sym)
    render plain: "Not found", status: :not_found unless allowed.include?(Rails.env.to_sym)
  end

  def workspace_root
    configured_root = Mbeditor.configuration.workspace_root
    configured_root.present? ? Pathname.new(configured_root.to_s) : Rails.root
  end

  # Expand path and confirm it's inside workspace_root
  def resolve_path(raw)
    return nil if raw.blank?
    root = workspace_root.to_s
    full = File.expand_path(raw.to_s, root)
    full.start_with?(root + "/") || full == root ? full : nil
  end

  def relative_path(full)
    full.delete_prefix(workspace_root.to_s + "/")
  end

  def build_tree(dir, max_depth: 10, depth: 0)
    return [] if depth >= max_depth

    entries = Dir.entries(dir).sort.reject { |e| e.start_with?(".") || e == "." || e == ".." }

    entries.filter_map do |name|
      full = File.join(dir, name)
      rel  = relative_path(full)

      # Skip ignored directories
      next if File.directory?(full) && IGNORED_DIRS.include?(name)
      # Skip vendor/bundle specifically
      next if rel.start_with?("vendor/bundle")

      if File.directory?(full)
        { name: name, type: "folder", path: rel, children: build_tree(full, depth: depth + 1) }
      else
        { name: name, type: "file", path: rel }
      end
    end
  rescue Errno::EACCES
    []
  end

  def cop_severity(severity)
    case severity
    when "error", "fatal" then "error"
    when "warning"        then "warning"
    else                       "info"
    end
  end

  def find_rubocop
    # Prefer bundle exec rubocop within the project
    bin = workspace_root.join("bin", "rubocop")
    return bin.to_s if bin.exist?
    "rubocop"
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
end
end
