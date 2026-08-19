# frozen_string_literal: true

require "digest"

module Mbeditor
  class FileTreeService
    MUTEX = Mutex.new
    private_constant :MUTEX

    def self.build(workspace_root)
      root = workspace_root.to_s
      MUTEX.synchronize do
        @cache ||= {}
        entry = @cache[root]
        if entry && (Process.clock_gettime(Process::CLOCK_MONOTONIC) - entry[:ts]) < 15
          return entry[:data]
        end
      end

      matcher = ExclusionMatcher.new(Mbeditor.configuration.excluded_paths, root: root)
      data = traverse(root, root, matcher)

      MUTEX.synchronize do
        @cache ||= {}
        @cache[root] = { ts: Process.clock_gettime(Process::CLOCK_MONOTONIC), data: data }
      end

      data
    end

    # The tree already serialized, plus a digest of that body, memoized inside
    # the same cache entry. /files is polled every 10s and the payload is ~1 MB,
    # so the digest is what turns an unchanged poll into a 304.
    def self.cached_json(workspace_root)
      root = workspace_root.to_s
      data = build(root)

      MUTEX.synchronize do
        entry = (@cache ||= {})[root]
        return entry[:json] if entry && entry[:json] && entry[:data].equal?(data)

        # to_json, not JSON.generate: `render json:` used ActiveSupport's
        # encoder, and the body must stay byte-identical.
        body = data.to_json
        payload = { body: body, digest: Digest::SHA1.hexdigest(body) }
        entry[:json] = payload if entry
        payload
      end
    end

    def self.invalidate(workspace_root)
      MUTEX.synchronize do
        @cache ||= {}
        @cache.delete(workspace_root.to_s)
      end
      nil
    end

    def self.reset!
      MUTEX.synchronize { @cache = {} }
      nil
    end

    def self.traverse(dir, workspace_root, matcher, max_depth: 10, depth: 0)
      return [] if depth >= max_depth

      entries = Dir.entries(dir).sort.reject { |e| e == "." || e == ".." }
      entries.filter_map do |name|
        full = File.join(dir, name)
        rel  = full.delete_prefix(workspace_root + "/")
        rel  = "" if rel == workspace_root
        is_excl = matcher.excluded?(rel)

        # One lstat instead of directory?/symlink?/size — three stats per entry
        # over a whole tree. lstat does not follow, so a symlink is never a
        # folder here, exactly as the directory?-and-not-symlink? test intended;
        # a symlinked file still reports its *target's* size, as it always did.
        st = (File.lstat(full) rescue nil)

        if st&.directory?
          children = is_excl ? [] : traverse(full, workspace_root, matcher, max_depth: max_depth, depth: depth + 1)
          node = { name: name, type: "folder", path: rel, children: children }
          node[:excluded] = true if is_excl
          node
        else
          node = { name: name, type: "file", path: rel }
          node[:size] = ((st&.symlink? ? File.size(full) : st&.size) rescue nil) unless is_excl
          node[:excluded] = true if is_excl
          node
        end
      end
    rescue Errno::EACCES
      []
    end
    private_class_method :traverse
  end
end
