# frozen_string_literal: true

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

        if File.directory?(full) && !File.symlink?(full)
          children = is_excl ? [] : traverse(full, workspace_root, matcher, max_depth: max_depth, depth: depth + 1)
          node = { name: name, type: "folder", path: rel, children: children }
          node[:excluded] = true if is_excl
          node
        else
          node = { name: name, type: "file", path: rel }
          node[:size] = (File.size(full) rescue nil) unless is_excl
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
