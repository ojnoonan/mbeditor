# frozen_string_literal: true

module Mbeditor
  # Checks and applies a unified diff pasted from a chat reply, with
  # `git apply` (it works outside a repository too).
  #
  # The patch goes in on stdin rather than a Tempfile: nothing to clean up, and
  # ProcessRunner already drains and bounds the pipes.
  class PatchApplyService
    MAX_PATCH_BYTES = 5 * 1024 * 1024
    TIMEOUT = 30
    OUTPUT_CAP = 1024 * 1024

    # Message is shown to the user verbatim; for a failed apply it is git's
    # stderr, which names the failing hunk.
    class Error < StandardError; end

    def initialize(workspace_root)
      @root = workspace_root.to_s
    end

    # Returns { ok:, files: [{path, added, removed, status}], output:, patch: }
    # where patch is the normalised text that was checked or applied.
    def call(raw_patch, check: true)
      patch = normalize(raw_patch)
      prefix = git_prefix

      # A workspace below the repository root: git reads `diff --git` paths as
      # repo-root-relative, the AI wrote them workspace-relative.
      args = %w[git apply --recount --whitespace=nowarn]
      args << "--directory=#{prefix}" unless prefix.empty?

      files = list_files(patch, args, prefix)
      run!(args + ["--check"], patch)
      result = check ? nil : run!(args, patch)
      { ok: true, files: files, output: result ? result[:stderr].strip : "", patch: patch }
    end

    private

    # Chat replies arrive as a fenced block with prose around it. Take from the
    # first diff line to the closing fence; a bare ``` can never be a hunk line
    # (those start with space, + or -).
    def normalize(raw)
      raise Error, "Patch is too large (limit #{MAX_PATCH_BYTES / 1024 / 1024} MB)." if raw.to_s.bytesize > MAX_PATCH_BYTES

      text = raw.to_s
      # A paste that is CRLF throughout gets normalised. A mixed one is a
      # patch for a CRLF file (LF structure, CRLF content) and must stay as is.
      text = text.gsub("\r\n", "\n") unless text.match?(/(?<!\r)\n/)
      lines = text.lines
      start = lines.index { |l| l.start_with?("diff --git ", "--- ") }
      raise Error, "No diff found. Paste a unified diff (diff --git / --- / +++ lines)." unless start

      body = lines.drop(start)
      fence = body.index { |l| l.start_with?("```") }
      body = body.first(fence) if fence
      text = body.join
      text.end_with?("\n") ? text : "#{text}\n"
    end

    # A non-repo directory gives "" (git apply works there), as does the repo root.
    def git_prefix
      r = run(%w[git rev-parse --show-prefix])
      r[:exit_status].success? ? r[:stdout].strip : ""
    rescue Errno::ENOENT
      raise Error, "git is not installed; it is needed to apply patches."
    end

    def list_files(patch, args, prefix)
      r = run!(args + %w[--numstat --summary -z], patch)
      tokens = r[:stdout].split("\0", -1)
      summary = tokens.pop.to_s
      created = summary.scan(/^ create mode \d+ (.+)$/).flatten.map { |p| strip(p, prefix) }
      deleted = summary.scan(/^ delete mode \d+ (.+)$/).flatten.map { |p| strip(p, prefix) }
      # A pure rename's numstat entry carries only the new name.
      renames = patch.scan(/^rename from (.+)\nrename to (.+)$/).to_h { |from, to| [to, from] }

      files = []
      until tokens.empty?
        m = tokens.shift.match(/\A(\d+|-)\t(\d+|-)\t(.*)\z/m) or next
        from = nil
        path = m[3]
        # -z numstat: a rename is an empty path followed by old then new.
        from, path = tokens.shift(2).map { |p| strip(p, prefix) } if path.empty?
        path = strip(path, prefix)
        from ||= renames[path]
        status = if from then :renamed
                 elsif created.include?(path) then :created
                 elsif deleted.include?(path) then :deleted
                 else :modified
                 end
        files << { path: path, added: m[1].to_i, removed: m[2].to_i, status: status }.tap { |f| f[:from] = from if from }
      end
      reject_unsafe!(files.flat_map { |f| [f[:path], f[:from]] }.compact)
      files
    end

    # git apply refuses most of these itself (no --unsafe-paths is ever
    # passed); this is the explicit second check, and the only one for .git.
    def reject_unsafe!(paths)
      paths.each do |p|
        segments = p.split("/")
        next unless p.start_with?("/") || p.include?("\0") || segments.include?("..") ||
                    segments.any? { |s| s.casecmp?(".git") }

        raise Error, "Refusing to touch #{p.inspect}: paths must be inside the project and not under .git."
      end
    end

    def strip(path, prefix)
      prefix.empty? ? path : path.delete_prefix(prefix)
    end

    def run(cmd, stdin = nil)
      ProcessRunner.call(cmd, timeout: TIMEOUT, stdin_data: stdin, chdir: @root, max_bytes: OUTPUT_CAP)
    end

    def run!(cmd, stdin)
      r = run(cmd, stdin)
      raise Error, (r[:stderr].presence || r[:stdout]).strip unless r[:exit_status].success?

      r
    end
  end
end
