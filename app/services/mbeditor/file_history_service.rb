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

    # v1 (no "v") began tracking before the file content had arrived, so it
    # recorded the whole-file load as an insert-at-origin op against an empty
    # base — once per open. v2 begins tracking once the load has landed, so the
    # load is the base and only real edits are ops. Legacy files are migrated on
    # read (migrate_legacy!); legacy writes are normalized in #append.
    FORMAT_VERSION  = 2
    MAX_OPS         = 10_000
    COMPACT_TARGET  = 5_000
    MAX_AGE_SECONDS = 7 * 24 * 3600
    BASE_MAX_BYTES  = EditorStateService::STATE_MAX_BYTES
    # Op count alone doesn't bound size: a few huge pastes can outweigh MAX_OPS
    # tiny edits, so compaction also triggers on the serialized payload size.
    MAX_BYTES       = 4 * 1024 * 1024

    def initialize(workspace_root, lock_timeout: EditorStateService::DEFAULT_LOCK_TIMEOUT, max_bytes: MAX_BYTES)
      @root = workspace_root
      @lock_timeout = lock_timeout
      @max_bytes = max_bytes
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

      data = migrate_legacy!(path, data)
      return nil unless data

      { "base" => data["base"], "ops" => data["ops"] || [] }
    rescue JSON::ParserError
      FileUtils.rm_f(path)
      nil
    end

    # Appends ops, seeding the history with `base` on the first write for this
    # branch+path. `base_given` distinguishes "no base param at all" (an
    # error, except on a non-first write) from an explicit empty base (a
    # legitimate first snapshot — e.g. a file that is empty on disk, tracked
    # from "" before the first edit).
    #
    # `version` is the client's format version. A legacy client (absent or <
    # FORMAT_VERSION) sends base "" plus the whole-file load as its first op;
    # that is folded into the base here so the bad shape never reaches disk.
    def append(branch, rel_path, ops:, base: nil, base_given: false, version: nil)
      ops  = Array(ops)
      base = base.to_s

      if version.to_i < FORMAT_VERSION && base_given && base.empty?
        base = ops.shift[4].to_s if load_op?(ops.first)
        ops  = ops.reject { |op| load_op?(op) }
      end

      file = LockedJsonFile.new(history_path(branch, rel_path), lock_timeout: @lock_timeout, error_class: LockTimeoutError)

      file.with_lock do
        existing = file.read

        if existing.empty?
          raise BaseRequiredError unless base_given
          raise BaseTooLargeError if base.bytesize > BASE_MAX_BYTES

          existing = {
            "branch" => branch,
            "path"   => rel_path,
            "base"   => base,
            "ops"    => [],
            "v"      => FORMAT_VERSION,
            "t"      => Time.now.utc.iso8601
          }
        end

        existing["v"]   = FORMAT_VERSION
        existing["ops"] = (existing["ops"] || []) + ops
        existing["t"]   = Time.now.utc.iso8601

        payload = existing.to_json
        if existing["ops"].length > MAX_OPS || payload.bytesize > @max_bytes
          compact_until_bounded!(existing)
          payload = existing.to_json
        end

        file.write(payload)
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

    # Rewrites a v1 history into the v2 shape and returns it, or nil if there is
    # nothing left to replay (the file is then removed). A v2 file is returned
    # untouched. Writes are atomic (rename), so a concurrent reader never sees a
    # half-written file; the rewrite is idempotent, so a racing append that also
    # normalizes is harmless.
    def migrate_legacy!(path, data)
      return data if data["v"].to_i >= FORMAT_VERSION

      base = data["base"].to_s
      ops  = Array(data["ops"])

      if base.empty? && load_op?(ops.first)
        # The first load is exactly equivalent to the base it was applied to.
        base = ops.shift[4].to_s
        # Every later load starts another session whose preceding edits already
        # reproduce it. Left in place they concatenate the file onto itself;
        # dropping them reconstructs the last session's edits over the first
        # session's content.
        ops = ops.reject { |op| load_op?(op) }
      end

      migrated = data.merge("base" => base, "ops" => ops, "v" => FORMAT_VERSION)

      if base.empty? && ops.empty?
        FileUtils.rm_f(path)
        nil
      else
        LockedJsonFile.new(path, lock_timeout: @lock_timeout, error_class: LockTimeoutError).write(migrated)
        migrated
      end
    end

    # A whole-file load as the v1 client recorded it: an insertion at the very
    # start of the document. Its text is the file content at that open.
    def load_op?(op)
      return false unless op.is_a?(Array) && op.length >= 5

      op[0].to_i == 1 && op[1].to_i == 1 && op[2].to_i == 1 && op[3].to_i == 1
    end

    # Folds ops into the base until both the op count and the serialized size
    # are back under budget. Stops early when the op log is empty — a base that
    # alone exceeds the budget (a very large file) can't be shrunk further
    # without the current file contents, which the service does not have.
    def compact_until_bounded!(data)
      data["ops"] ||= []
      loop do
        break if data["ops"].length <= MAX_OPS && data.to_json.bytesize <= @max_bytes
        break if data["ops"].empty?

        data["base"] = compact_ops(data["base"], data["ops"].shift(COMPACT_TARGET))
      end
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
