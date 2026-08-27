# frozen_string_literal: true

module Mbeditor
  # Per-branch, per-file undo history: the ops the client couldn't replay from
  # its own in-memory undo stack (a reload, a second tab) get persisted here as
  # a base snapshot plus an appended op log, keyed by branch+path so switching
  # branches doesn't cross-contaminate history.
  #
  # Built on LockedJsonFile — the same sidecar-lock + atomic-write primitive
  # EditorStateService uses — rather than a hand-rolled flock loop that wrote
  # in place with truncate/rewind. A crash mid-write there truncated history
  # instead of leaving the previous file untouched.
  class FileHistoryService
    LockTimeoutError  = LockedJsonFile::LockTimeoutError
    BaseRequiredError = Class.new(StandardError)
    BaseTooLargeError = Class.new(StandardError)

    MAX_OPS         = 10_000
    COMPACT_TARGET  = 5_000
    MAX_AGE_SECONDS = 7 * 24 * 3600
    BASE_MAX_BYTES  = EditorStateService::STATE_MAX_BYTES

    def initialize(workspace_root, lock_timeout: EditorStateService::DEFAULT_LOCK_TIMEOUT)
      @root = workspace_root
      @lock_timeout = lock_timeout
    end

    # Returns { "base" => ..., "ops" => [...] }, or nil if there is no history
    # or it aged out (an aged-out file is pruned as a side effect).
    def read(branch, rel_path)
      path = history_path(branch, rel_path)
      return nil unless File.exist?(path)

      data = JSON.parse(File.read(path))

      if data["t"] && (Time.now.utc - Time.parse(data["t"])) > MAX_AGE_SECONDS
        FileUtils.rm_f(path)
        return nil
      end

      { "base" => data["base"], "ops" => data["ops"] || [] }
    rescue JSON::ParserError
      FileUtils.rm_f(path)
      nil
    end

    # Appends ops, seeding the history with `base` on the first write for this
    # branch+path. `base_given` distinguishes "no base param at all" (an
    # error, except on a non-first write) from an explicit empty base (a
    # legitimate first snapshot — the client starts tracking before the file
    # content has arrived, so the load itself is the first op against "").
    def append(branch, rel_path, ops:, base: nil, base_given: false)
      file = LockedJsonFile.new(history_path(branch, rel_path), lock_timeout: @lock_timeout, error_class: LockTimeoutError)

      file.with_lock do
        existing = file.read

        if existing.empty?
          raise BaseRequiredError unless base_given
          raise BaseTooLargeError if base.to_s.bytesize > BASE_MAX_BYTES

          existing = { "branch" => branch, "path" => rel_path, "base" => base.to_s, "ops" => [], "t" => Time.now.utc.iso8601 }
        end

        existing["ops"] = (existing["ops"] || []) + ops
        existing["t"]   = Time.now.utc.iso8601

        if existing["ops"].length > MAX_OPS
          to_compact       = existing["ops"].shift(COMPACT_TARGET)
          existing["base"] = compact_ops(existing["base"], to_compact)
        end

        file.write(existing)
      end
      nil
    end

    # Deletes history files for branches no longer in active_branches.
    def prune(active_branches:)
      hist_dir = @root.join("tmp", "mbeditor_history")
      return unless File.directory?(hist_dir)

      Dir.glob(File.join(hist_dir, "*.json")) do |hist_file|
        data = begin
          JSON.parse(File.read(hist_file))
        rescue JSON::ParserError => e
          Rails.logger.error("[mbeditor] FileHistoryService#prune: skipping corrupt history file #{hist_file}: #{e.message}")
          nil
        end
        next unless data.is_a?(Hash) && data["branch"]

        FileUtils.rm_f(hist_file) unless active_branches.include?(data["branch"])
      end
      nil
    end

    private

    def history_path(branch, rel_path)
      branch_hash = Digest::SHA256.hexdigest(branch.to_s)[0, 16]
      file_hash   = Digest::SHA256.hexdigest(rel_path.to_s)[0, 16]
      @root.join("tmp", "mbeditor_history", "#{branch_hash}_#{file_hash}.json")
    end

    # Replays a batch of ops against `base` to fold them into a new snapshot
    # once the op log outgrows MAX_OPS, so history keeps a bounded number of
    # ops without losing anything: base + remaining ops still reconstructs the
    # same document. Each op is [startLine, startCol, endLine, endCol, insertedText],
    # 1-based, matching Monaco's model.onDidChangeContent ranges.
    def compact_ops(base, ops)
      text = base.to_s
      ops.each do |op|
        sl, sc, el, ec, ins = op[0].to_i, op[1].to_i, op[2].to_i, op[3].to_i, op[4].to_s
        lines = text.split("\n", -1)
        sl0  = [[sl - 1, 0].max, [lines.length - 1, 0].max].min
        el0  = [[el - 1, 0].max, [lines.length - 1, 0].max].min
        sc0  = sc - 1
        ec0  = ec - 1
        prefix    = (lines[sl0] || "")[0, sc0] || ""
        suffix    = (lines[el0] || "")[ec0..] || ""
        ins_lines = ins.split("\n", -1)
        new_seg   = if ins_lines.length <= 1
          [prefix + (ins_lines[0] || "") + suffix]
        else
          [prefix + ins_lines[0]] + ins_lines[1..-2] + [ins_lines[-1] + suffix]
        end
        text = (lines[0...sl0] + new_seg + lines[(el0 + 1)..]).join("\n")
      end
      text
    rescue StandardError
      base.to_s
    end
  end
end
