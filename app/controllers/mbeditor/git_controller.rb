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
      # @ is excluded to block reflog syntax like @{-1} or HEAD@{2}.
      valid_ref = /\A[a-zA-Z0-9._\-\/\^~]+\z/
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
      render json: { error: e.message }, status: :unprocessable_content
    end

    # GET /mbeditor/git/blame?file=<path>
    def blame
      file = require_file_param
      return unless file

      lines = GitBlameService.new(repo_path: workspace_root, file_path: file).call
      render json: { lines: lines }
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    # GET /mbeditor/git/file_history?file=<path>
    def file_history
      file = require_file_param
      return unless file

      commits = GitFileHistoryService.new(repo_path: workspace_root, file_path: file).call
      render json: { commits: commits }
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    # GET /mbeditor/git/commit_graph
    def commit_graph
      commits = GitCommitGraphService.new(repo_path: workspace_root).call
      render json: { commits: commits }
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    # GET /mbeditor/git/commit_detail?sha=<hash>
    def commit_detail
      sha = params[:sha].to_s.strip
      return render json: { error: "sha required" }, status: :bad_request if sha.blank?
      return render json: { error: "Invalid sha" }, status: :bad_request unless sha.match?(/\A[0-9a-fA-F]{1,40}\z/)

      render json: GitCommitDetailService.new(repo_path: workspace_root, sha: sha).call
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    # GET /mbeditor/git/combined_diff?scope=local|branch
    # Returns the raw unified diff text for all files in the given scope.
    # scope=local  → git diff HEAD  (working tree vs HEAD)
    # scope=branch → git diff <branch-base>..HEAD (same baseline as git_info)
    def combined_diff
      scope = params[:scope] == 'branch' ? :branch : :local
      out = GitCombinedDiffService.new(repo_path: workspace_root, scope: scope).call
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
      render json: { error: e.message }, status: :unprocessable_content
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_content
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
