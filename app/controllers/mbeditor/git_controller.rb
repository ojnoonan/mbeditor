# frozen_string_literal: true

module Mbeditor
  # Thin controller for all Git-related endpoints added in the Git & Code Review
  # system.  All heavy logic lives in service objects under app/services/mbeditor/.
  #
  # Endpoints
  # ---------
  # GET  /mbeditor/git/diff          ?file=<path>[&base=<sha>&head=<sha>]
  # GET  /mbeditor/git/blame         ?file=<path>
  # GET  /mbeditor/git/file_history  ?file=<path>
  # GET  /mbeditor/git/commit_graph
  # GET  /mbeditor/redmine/issue/:id
  class GitController < ApplicationController
    skip_before_action :verify_authenticity_token
    before_action :ensure_allowed_environment!

    # GET /mbeditor/git/diff?file=<path>[&base=<sha>&head=<sha>]
    def diff
      file = require_file_param
      return unless file

      base = params[:base].presence
      head = params[:head].presence
      # 'WORKING' is a frontend sentinel meaning current on-disk working tree
      head = nil if head == 'WORKING'
      # Allow full/short SHA hashes plus common git ref formats: branch names,
      # HEAD, remote tracking refs, parent notation (sha^, sha~N) and tags.
      valid_ref = /\A[a-zA-Z0-9._\-\/\^~@]+\z/
      if [base, head].any? { |s| s && (s.length > 200 || !s.match?(valid_ref)) }
        return render json: { error: 'Invalid ref' }, status: :bad_request
      end

      result = GitDiffService.new(
        repo_path: workspace_root,
        file_path: file,
        base_sha: base,
        head_sha: head
      ).call

      render json: result
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # GET /mbeditor/git/blame?file=<path>
    def blame
      file = require_file_param
      return unless file

      lines = GitBlameService.new(repo_path: workspace_root, file_path: file).call
      render json: { lines: lines }
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # GET /mbeditor/git/file_history?file=<path>
    def file_history
      file = require_file_param
      return unless file

      commits = GitFileHistoryService.new(repo_path: workspace_root, file_path: file).call
      render json: { commits: commits }
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # GET /mbeditor/git/commit_graph
    def commit_graph
      commits = GitCommitGraphService.new(repo_path: workspace_root).call
      render json: { commits: commits }
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # GET /mbeditor/git/commit_detail?sha=<hash>
    def commit_detail
      sha = params[:sha].to_s.strip
      return render json: { error: "sha required" }, status: :bad_request if sha.blank?
      return render json: { error: "Invalid sha" }, status: :bad_request unless sha.match?(/\A[0-9a-fA-F]{1,40}\z/)

      files_output, _err, files_status = Open3.capture3(
        "git", "-C", workspace_root.to_s,
        "diff-tree", "--no-commit-id", "-r", "--name-status", sha
      )
      numstat_output, _err, numstat_status = Open3.capture3(
        "git", "-C", workspace_root.to_s,
        "diff-tree", "--no-commit-id", "-r", "--numstat", sha
      )

      numstat_map = {}
      if numstat_status.success?
        numstat_output.lines.each do |line|
          parts = line.strip.split("\t", 3)
          next if parts.length < 3 || parts[0] == "-"

          numstat_map[parts[2].strip] = { "added" => parts[0].to_i, "removed" => parts[1].to_i }
        end
      end

      files = []
      if files_status.success?
        files = files_output.lines.map do |line|
          parts = line.strip.split("\t", 2)
          next if parts.length < 2
          file = { "status" => parts[0].strip, "path" => parts[1].strip }
          file.merge(numstat_map.fetch(file["path"], {}))
        end.compact
      end

      log_output, _err, log_status = Open3.capture3(
        "git", "-C", workspace_root.to_s,
        "log", "-1", "--pretty=format:%s%x1f%an%x1f%aI", sha
      )
      meta = {}
      if log_status.success?
        fields = log_output.strip.split("\x1f", 3)
        meta = { "title" => fields[0].to_s, "author" => fields[1].to_s, "date" => fields[2].to_s }
      end

      render json: { sha: sha, title: meta["title"] || "", author: meta["author"] || "", date: meta["date"] || "", files: files }
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # GET /mbeditor/git/combined_diff?scope=local|branch
    # Returns the raw unified diff text for all files in the given scope.
    # scope=local  → git diff HEAD  (working tree vs HEAD)
    # scope=branch → git diff <upstream>..HEAD  (branch vs upstream)
    def combined_diff
      scope = params[:scope] == 'branch' ? :branch : :local

      if scope == :local
        out, _err, status = Open3.capture3("git", "-C", workspace_root.to_s, "diff", "HEAD")
        out = status.success? ? out : ""
      else
        upstream_out, _err, upstream_status = Open3.capture3(
          "git", "-C", workspace_root.to_s,
          "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"
        )
        upstream = upstream_status.success? ? upstream_out.strip : nil
        upstream = nil unless upstream&.match?(%r{\A[\w./-]+\z})
        if upstream.present?
          out, _err, status = Open3.capture3("git", "-C", workspace_root.to_s, "diff", "#{upstream}..HEAD")
          out = status.success? ? out : ""
        else
          out = ""
        end
      end

      render plain: out, content_type: "text/plain"
    rescue StandardError
      render plain: "", content_type: "text/plain"
    end

    # GET /mbeditor/redmine/issue/:id
    def redmine_issue
      unless Mbeditor.configuration.redmine_enabled
        return render json: { error: 'Redmine integration is disabled.' }, status: :service_unavailable
      end

      return render json: { error: 'Invalid issue id' }, status: :bad_request unless params[:id].to_s.match?(/\A\d+\z/)

      result = RedmineService.new(issue_id: params[:id]).call
      render json: result
    rescue RedmineDisabledError => e
      render json: { error: e.message }, status: :service_unavailable
    rescue RedmineConfigError => e
      render json: { error: e.message }, status: :unprocessable_entity
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    private

    # Require & validate a `file` query param, responding 400/403 on bad input.
    # Returns the relative path string on success, or nil if already responded.
    def require_file_param
      raw = params[:file].to_s.strip

      if raw.blank?
        render json: { error: "file parameter is required" }, status: :bad_request
        return nil
      end

      full = resolve_path(raw)
      unless full
        render json: { error: "Forbidden" }, status: :forbidden
        return nil
      end

      relative_path(full)
    end
  end
end
