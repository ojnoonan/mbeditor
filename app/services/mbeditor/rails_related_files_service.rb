# frozen_string_literal: true

module Mbeditor
  # Given a workspace-relative file path, finds related Rails files grouped by
  # type: controller, model, views, helper, tests, and custom directories.
  #
  # Only groups with at least one existing file are included in the result.
  # All returned paths are workspace-relative strings.
  module RailsRelatedFilesService
    module_function

    # Returns a hash of groups.  Example:
    #
    #   {
    #     controller: [{path: "app/controllers/users_controller.rb", name: "users_controller.rb"}],
    #     model:      [{path: "app/models/user.rb",                  name: "user.rb"}],
    #     views:      [{path: "app/views/users/index.html.erb",      name: "index.html.erb"}],
    #     helper:     [{path: "app/helpers/users_helper.rb",         name: "users_helper.rb"}],
    #     tests:      [{path: "test/controllers/users_controller_test.rb", name: "users_controller_test.rb"}],
    #     custom:     {"app/assets/javascripts/app" => [{path: "...", name: "..."}]}
    #   }
    #
    # Returns {} when the path does not match any known Rails convention.
    def find(workspace_root, relative_path, custom_paths: [])
      plural, singular = extract_resource_names(relative_path, custom_paths: custom_paths)
      return {} unless plural && singular

      result = {}

      # ── controller ────────────────────────────────────────────────────────────
      controller_path = "app/controllers/#{plural}_controller.rb"
      if file_exists?(workspace_root, controller_path)
        result[:controller] = [entry(controller_path, kind: 'Controller')]
      end

      # ── model ─────────────────────────────────────────────────────────────────
      model_path = "app/models/#{singular}.rb"
      if file_exists?(workspace_root, model_path)
        result[:model] = [entry(model_path, kind: 'Model')]
      end

      # ── views ─────────────────────────────────────────────────────────────────
      views_dir = File.join(workspace_root, "app", "views", plural)
      if File.directory?(views_dir)
        children = dir_children(workspace_root, "app/views/#{plural}", kind: 'View')
        result[:views] = children unless children.empty?
      end

      # ── helper ────────────────────────────────────────────────────────────────
      helper_path = "app/helpers/#{plural}_helper.rb"
      if file_exists?(workspace_root, helper_path)
        result[:helper] = [entry(helper_path, kind: 'Helper')]
      end

      # ── tests ─────────────────────────────────────────────────────────────────
      test_candidates = [
        "test/controllers/#{plural}_controller_test.rb",
        "test/models/#{singular}_test.rb",
        "spec/controllers/#{plural}_controller_spec.rb",
        "spec/models/#{singular}_spec.rb"
      ]
      tests = test_candidates.select { |p| file_exists?(workspace_root, p) }.map { |p| entry(p, kind: 'Test') }
      result[:tests] = tests unless tests.empty?

      # ── concerns ──────────────────────────────────────────────────────────────
      plain_plural   = plural.split('/').last
      plain_singular = singular.split('/').last
      concern_dirs = ['app/models/concerns', 'app/controllers/concerns']
      concern_files = []
      concern_dirs.each do |dir|
        children = dir_children(workspace_root, dir, kind: 'Concern')
        matching = children.select { |c|
          base = File.basename(c[:path], '.*')
          base == plain_plural || base == plain_singular ||
            base.start_with?("#{plain_plural}_") || base.start_with?("#{plain_singular}_") ||
            base.end_with?("_#{plain_plural}") || base.end_with?("_#{plain_singular}")
        }
        concern_files.concat(matching)
      end
      result[:concerns] = concern_files.uniq { |c| c[:path] } unless concern_files.empty?

      # ── custom paths ──────────────────────────────────────────────────────────
      custom_result = {}
      Array(custom_paths).each do |base|
        base = base.to_s.strip
        next if base.empty?

        # Derive a human-readable kind from the last segment of the base path
        custom_kind = base.split('/').last.to_s.tr('_', ' ').split.map(&:capitalize).join(' ')

        [plural, singular].uniq.each do |name|
          rel_dir = "#{base}/#{name}"
          abs_dir = File.join(workspace_root, rel_dir)
          next unless File.directory?(abs_dir)

          begin
            real_ws = File.realpath(workspace_root)
            real_dir = File.realpath(abs_dir)
            next unless real_dir.start_with?("#{real_ws}/") || real_dir == real_ws
          rescue Errno::ENOENT, Errno::EACCES
            next
          end

          children = dir_children(workspace_root, rel_dir, kind: custom_kind)
          next if children.empty?

          custom_result[base] ||= []
          custom_result[base].concat(children)
        end
      end
      result[:custom] = custom_result unless custom_result.empty?

      result
    end

    # ---------------------------------------------------------------------------
    # Helpers
    # ---------------------------------------------------------------------------

    # Returns [plural, singular] workspace-relative resource name strings
    # (may include namespace prefix, e.g. "admin/users", "admin/user"),
    # or nil when the path does not match a known Rails convention.
    def extract_resource_names(relative_path, custom_paths: [])
      parts = relative_path.to_s.split("/")
      return nil unless parts.length >= 2

      # Custom paths are checked first so they work regardless of top-level prefix.
      # Paths under app/assets/, app/javascript/, etc. never reach the standard
      # "app" branch, so the check must happen before the case statement.
      Array(custom_paths).each do |base|
        base = base.to_s.strip
        next if base.empty?
        next unless relative_path.start_with?("#{base}/")
        rest = relative_path.delete_prefix("#{base}/")
        resource = rest.split('/').first.to_s.sub(/\.[^.]+$/, '') # first segment, no extension
        resource = resource.sub(/_(controller|model|helper|service)$/, '') # strip Rails suffixes
        next if resource.empty?
        return [pluralize(resource), singularize(resource)]
      end

      case parts[0]
      when "app"
        case parts[1]
        when "controllers"
          # app/controllers/[namespace/]name_controller.rb
          # also handles app/controllers/concerns/name_concern.rb
          if parts[2] == "concerns"
            return nil unless parts.length >= 4 && parts.last.end_with?(".rb")
            file_base = parts.last.delete_suffix(".rb")
            singular = file_base.sub(/_concern$/, '').sub(/^concern_/, '')
            plural = pluralize(singular)
            return [plural, singular]
          end

          return nil unless parts.last.end_with?("_controller.rb")

          ns_and_file = parts[2..]
          file = ns_and_file.last
          ns   = ns_and_file[0..-2]  # may be empty
          base = file.delete_suffix("_controller.rb")
          plural   = (ns + [base]).join("/")
          singular = (ns + [singularize(base)]).join("/")
          [plural, singular]

        when "models"
          # app/models/[namespace/]name.rb
          # also handles app/models/concerns/name_concern.rb
          if parts[2] == "concerns"
            return nil unless parts.length >= 4 && parts.last.end_with?(".rb")
            file_base = parts.last.delete_suffix(".rb")
            singular = file_base.sub(/_concern$/, '').sub(/^concern_/, '')
            plural = pluralize(singular)
            return [plural, singular]
          end

          return nil unless parts.last.end_with?(".rb")

          ns_and_file = parts[2..]
          file = ns_and_file.last.delete_suffix(".rb")
          ns   = ns_and_file[0..-2]
          singular = (ns + [file]).join("/")
          plural   = (ns + [pluralize(file)]).join("/")
          [plural, singular]

        when "views"
          # app/views/[namespace/]resource/anything
          return nil unless parts.length >= 4

          # All path segments between "views" and the view filename form the resource path.
          # e.g. app/views/admin/users/index.html.erb → view_resource = ["admin","users"]
          # e.g. app/views/users/index.html.erb       → view_resource = ["users"]
          view_resource = parts[2..parts.length - 2]
          plural   = view_resource.join("/")
          singular = (view_resource[0..-2] + [singularize(view_resource.last)]).join("/")
          [plural, singular]

        when "helpers"
          # app/helpers/[namespace/]name_helper.rb
          return nil unless parts.last.end_with?("_helper.rb")

          ns_and_file = parts[2..]
          file = ns_and_file.last
          ns   = ns_and_file[0..-2]
          base = file.delete_suffix("_helper.rb")
          plural   = (ns + [base]).join("/")
          singular = (ns + [singularize(base)]).join("/")
          [plural, singular]

        else
          nil
        end

      when "test", "spec"
        framework = parts[0]
        case parts[1]
        when "controllers"
          # test/controllers/[ns/]name_controller_test.rb
          suffix = framework == "test" ? "_controller_test.rb" : "_controller_spec.rb"
          return nil unless parts.last.end_with?(suffix)

          ns_and_file = parts[2..]
          file = ns_and_file.last
          ns   = ns_and_file[0..-2]
          base = file.delete_suffix(suffix)
          plural   = (ns + [base]).join("/")
          singular = (ns + [singularize(base)]).join("/")
          [plural, singular]

        when "models"
          # test/models/[ns/]name_test.rb
          suffix = framework == "test" ? "_test.rb" : "_spec.rb"
          return nil unless parts.last.end_with?(suffix)

          ns_and_file = parts[2..]
          file = ns_and_file.last
          ns   = ns_and_file[0..-2]
          base = file.delete_suffix(suffix)
          singular = (ns + [base]).join("/")
          plural   = (ns + [pluralize(base)]).join("/")
          [plural, singular]

        else
          nil
        end

      else
        nil
      end
    end

    def entry(rel_path, kind: nil)
      { path: rel_path, name: File.basename(rel_path), type: :file, kind: kind }
    end

    def file_exists?(workspace_root, rel_path)
      File.exist?(File.join(workspace_root, rel_path))
    end

    # Returns direct file children (not subdirectories) of a workspace-relative
    # directory, sorted by name, as {path:, name:, type: :file, kind:} hashes.
    def dir_children(workspace_root, rel_dir, kind: nil)
      abs_dir = File.join(workspace_root, rel_dir)
      return [] unless File.directory?(abs_dir)

      Dir.entries(abs_dir)
         .reject { |n| n.start_with?(".") }
         .sort
         .filter_map do |name|
           full = File.join(abs_dir, name)
           next unless File.file?(full)

           { path: "#{rel_dir}/#{name}", name: name, type: :file, kind: kind }
         end
    end

    def singularize(word)
      ActiveSupport::Inflector.singularize(word)
    end

    def pluralize(word)
      ActiveSupport::Inflector.pluralize(word)
    end

    private_class_method :entry, :file_exists?, :dir_children, :singularize, :pluralize, :extract_resource_names
  end
end
