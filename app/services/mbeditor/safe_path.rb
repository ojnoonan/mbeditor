# frozen_string_literal: true

module Mbeditor
  # Containment check for paths that may not exist yet.
  #
  # +File.realpath+ refuses to resolve a path whose final component is missing,
  # so callers that create files have to reason about the nearest existing
  # ancestor instead. Doing that with +File.exist?+ is unsafe: it *follows*
  # symlinks, so a symlink pointing at a missing target reports false and an
  # existence walk steps straight past it, back to the safely-contained parent.
  # A subsequent +File.open+ follows the link and writes outside the root.
  #
  # SafePath resolves the link chain itself with +File.symlink?+/+File.readlink+
  # (both lstat-based, neither follows) so a dangling symlink is judged by where
  # it points, not by whether that target happens to exist yet.
  module SafePath
    # Guards against symlink cycles, which surface as a path that neither
    # exists nor terminates.
    MAX_SYMLINK_HOPS = 32

    module_function

    # True when +path+ resolves to a location inside +root+, following every
    # symlink component including dangling ones. +root+ must exist.
    def within?(root, path)
      real_root = File.realpath(root.to_s)
      target    = canonical(path.to_s)
      return false unless target

      target == real_root || target.start_with?("#{real_root}/")
    rescue SystemCallError
      false
    end

    # The filesystem location a write to +path+ would actually land on, with
    # all symlinks expanded. Returns nil when the link chain cycles or exceeds
    # MAX_SYMLINK_HOPS.
    def canonical(path, hops = 0)
      return nil if hops > MAX_SYMLINK_HOPS
      # Anything that exists (including a symlink with a live target) resolves
      # normally; realpath expands the whole chain for us.
      return File.realpath(path) if File.exist?(path)

      parent = File.dirname(path)
      return nil if parent == path # ran off the top without finding anything

      real_parent = canonical(parent, hops)
      return nil unless real_parent

      if File.symlink?(path)
        canonical(File.absolute_path(File.readlink(path), real_parent), hops + 1)
      else
        File.join(real_parent, File.basename(path))
      end
    end
  end
end
