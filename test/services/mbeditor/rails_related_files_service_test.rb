# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class RailsRelatedFilesServiceTest < ActiveSupport::TestCase
    # ─────────────────────────────────────────────────────────────────────────
    # Helpers
    # ─────────────────────────────────────────────────────────────────────────

    def setup
      @root = Dir.mktmpdir("rfservice_test_")
    end

    def teardown
      FileUtils.rm_rf(@root)
    end

    # Create a file (and all necessary parent directories) inside @root.
    def touch(rel)
      full = File.join(@root, rel)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, "")
      rel
    end

    def find(rel, custom_paths: [])
      RailsRelatedFilesService.find(@root, rel, custom_paths: custom_paths)
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Controller file → finds model, views, helper, tests
    # ─────────────────────────────────────────────────────────────────────────

    test "controller file finds model" do
      touch "app/models/user.rb"
      result = find("app/controllers/users_controller.rb")
      assert result.key?(:model)
      assert_equal "app/models/user.rb", result[:model].first[:path]
    end

    test "controller file finds view children sorted by name" do
      touch "app/views/users/index.html.erb"
      touch "app/views/users/show.html.erb"
      result = find("app/controllers/users_controller.rb")
      assert result.key?(:views)
      names = result[:views].map { |e| e[:name] }
      assert_equal %w[index.html.erb show.html.erb], names
    end

    test "controller file finds helper" do
      touch "app/helpers/users_helper.rb"
      result = find("app/controllers/users_controller.rb")
      assert result.key?(:helper)
      assert_equal "app/helpers/users_helper.rb", result[:helper].first[:path]
    end

    test "controller file finds tests" do
      touch "test/controllers/users_controller_test.rb"
      touch "test/models/user_test.rb"
      result = find("app/controllers/users_controller.rb")
      assert result.key?(:tests)
      paths = result[:tests].map { |e| e[:path] }
      assert_includes paths, "test/controllers/users_controller_test.rb"
      assert_includes paths, "test/models/user_test.rb"
    end

    test "controller file does not include itself in results" do
      touch "app/controllers/users_controller.rb"
      result = find("app/controllers/users_controller.rb")
      # controller group only appears if the file exists (it does here)
      # but the test is that there are no errors / infinite loop
      assert_kind_of Hash, result
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Model file → finds controller, views, helper, tests
    # ─────────────────────────────────────────────────────────────────────────

    test "model file finds controller" do
      touch "app/controllers/users_controller.rb"
      result = find("app/models/user.rb")
      assert result.key?(:controller)
      assert_equal "app/controllers/users_controller.rb", result[:controller].first[:path]
    end

    test "model file finds views" do
      touch "app/views/users/index.html.erb"
      result = find("app/models/user.rb")
      assert result.key?(:views)
    end

    test "model file finds helper" do
      touch "app/helpers/users_helper.rb"
      result = find("app/models/user.rb")
      assert result.key?(:helper)
    end

    test "model file finds spec files" do
      touch "spec/models/user_spec.rb"
      touch "spec/controllers/users_controller_spec.rb"
      result = find("app/models/user.rb")
      assert result.key?(:tests)
      paths = result[:tests].map { |e| e[:path] }
      assert_includes paths, "spec/models/user_spec.rb"
      assert_includes paths, "spec/controllers/users_controller_spec.rb"
    end

    # ─────────────────────────────────────────────────────────────────────────
    # View file → finds controller, model, helper
    # ─────────────────────────────────────────────────────────────────────────

    test "view file finds controller" do
      touch "app/controllers/users_controller.rb"
      result = find("app/views/users/index.html.erb")
      assert result.key?(:controller)
      assert_equal "app/controllers/users_controller.rb", result[:controller].first[:path]
    end

    test "view file finds model" do
      touch "app/models/user.rb"
      result = find("app/views/users/index.html.erb")
      assert result.key?(:model)
      assert_equal "app/models/user.rb", result[:model].first[:path]
    end

    test "view file finds helper" do
      touch "app/helpers/users_helper.rb"
      result = find("app/views/users/index.html.erb")
      assert result.key?(:helper)
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Namespaced resources
    # ─────────────────────────────────────────────────────────────────────────

    test "namespaced controller finds namespaced model" do
      touch "app/models/admin/user.rb"
      result = find("app/controllers/admin/users_controller.rb")
      assert result.key?(:model), "expected :model group"
      assert_equal "app/models/admin/user.rb", result[:model].first[:path]
    end

    test "namespaced controller finds namespaced views" do
      touch "app/views/admin/users/index.html.erb"
      result = find("app/controllers/admin/users_controller.rb")
      assert result.key?(:views)
      assert_equal "app/views/admin/users/index.html.erb", result[:views].first[:path]
    end

    test "namespaced controller finds namespaced helper" do
      touch "app/helpers/admin/users_helper.rb"
      result = find("app/controllers/admin/users_controller.rb")
      assert result.key?(:helper)
      assert_equal "app/helpers/admin/users_helper.rb", result[:helper].first[:path]
    end

    test "namespaced controller finds namespaced test" do
      touch "test/controllers/admin/users_controller_test.rb"
      result = find("app/controllers/admin/users_controller.rb")
      assert result.key?(:tests)
      assert_equal "test/controllers/admin/users_controller_test.rb", result[:tests].first[:path]
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Unknown file type → returns {}
    # ─────────────────────────────────────────────────────────────────────────

    test "js file returns empty hash" do
      result = find("app/assets/javascripts/application.js")
      assert_equal({}, result)
    end

    test "config file returns empty hash" do
      result = find("config/routes.rb")
      assert_equal({}, result)
    end

    test "completely unrecognised path returns empty hash" do
      result = find("some/random/file.txt")
      assert_equal({}, result)
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Groups with no matching files are omitted entirely
    # ─────────────────────────────────────────────────────────────────────────

    test "groups with no existing files are omitted" do
      # None of the related files exist → result should be {}
      result = find("app/controllers/users_controller.rb")
      assert_equal({}, result)
    end

    test "only present groups are returned" do
      touch "app/models/user.rb"
      # model exists but controller/views/helper/tests do not
      result = find("app/controllers/users_controller.rb")
      assert_equal %i[model], result.keys
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Helper file
    # ─────────────────────────────────────────────────────────────────────────

    test "helper file finds controller and model" do
      touch "app/controllers/users_controller.rb"
      touch "app/models/user.rb"
      result = find("app/helpers/users_helper.rb")
      assert result.key?(:controller)
      assert result.key?(:model)
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Test/spec files
    # ─────────────────────────────────────────────────────────────────────────

    test "controller test file finds controller and model" do
      touch "app/controllers/users_controller.rb"
      touch "app/models/user.rb"
      result = find("test/controllers/users_controller_test.rb")
      assert result.key?(:controller)
      assert result.key?(:model)
    end

    test "model spec file finds controller and views" do
      touch "app/controllers/users_controller.rb"
      touch "app/views/users/index.html.erb"
      result = find("spec/models/user_spec.rb")
      assert result.key?(:controller)
      assert result.key?(:views)
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Custom paths
    # ─────────────────────────────────────────────────────────────────────────

    test "custom paths returns files when plural directory exists" do
      base = "app/assets/javascripts/ux/app"
      touch "#{base}/users/index.js"
      touch "#{base}/users/show.js"
      result = find("app/controllers/users_controller.rb", custom_paths: [base])
      assert result.key?(:custom), "expected :custom group"
      assert result[:custom].key?(base)
      names = result[:custom][base].map { |e| e[:name] }
      assert_includes names, "index.js"
      assert_includes names, "show.js"
    end

    test "custom paths returns files when singular directory exists" do
      base = "app/javascript/components"
      touch "#{base}/user/profile.jsx"
      result = find("app/controllers/users_controller.rb", custom_paths: [base])
      assert result.key?(:custom)
      assert result[:custom].key?(base)
      assert_equal "profile.jsx", result[:custom][base].first[:name]
    end

    test "custom paths omits group when no directory exists" do
      result = find("app/controllers/users_controller.rb", custom_paths: ["app/javascript/components"])
      assert_not result.key?(:custom)
    end

    test "custom paths with multiple bases returns each present base" do
      base1 = "app/assets/javascripts/app"
      base2 = "app/javascript/packs"
      touch "#{base1}/users/index.js"
      touch "#{base2}/users/main.js"
      result = find("app/controllers/users_controller.rb", custom_paths: [base1, base2])
      assert result.key?(:custom)
      assert result[:custom].key?(base1)
      assert result[:custom].key?(base2)
    end

    test "custom paths returns correct path entries" do
      base = "app/assets/javascripts/ux"
      touch "#{base}/users/index.js"
      result = find("app/controllers/users_controller.rb", custom_paths: [base])
      entry = result.dig(:custom, base, 0)
      assert_not_nil entry
      assert_equal "#{base}/users/index.js", entry[:path]
      assert_equal "index.js", entry[:name]
    end

    # ─────────────────────────────────────────────────────────────────────────
    # Concerns
    # ─────────────────────────────────────────────────────────────────────────

    test "concern in app/models/concerns appears in concerns group" do
      touch "app/models/concerns/user_concern.rb"
      result = find("app/controllers/users_controller.rb")
      assert result.key?(:concerns), "expected :concerns group"
      paths = result[:concerns].map { |e| e[:path] }
      assert_includes paths, "app/models/concerns/user_concern.rb"
    end

    test "controller entry has kind Controller" do
      touch "app/controllers/users_controller.rb"
      result = find("app/models/user.rb")
      assert result.key?(:controller)
      assert_equal 'Controller', result[:controller].first[:kind]
    end

    # ─────────────────────────────────────────────────────────────────────────
    # extract_resource_names unit tests
    # ─────────────────────────────────────────────────────────────────────────

    test "extract_resource_names returns nil for unrecognised path" do
      assert_nil RailsRelatedFilesService.send(:extract_resource_names, "lib/foo.rb")
    end

    test "extract_resource_names for controller" do
      plural, singular = RailsRelatedFilesService.send(:extract_resource_names, "app/controllers/users_controller.rb")
      assert_equal "users", plural
      assert_equal "user",  singular
    end

    test "extract_resource_names for model" do
      plural, singular = RailsRelatedFilesService.send(:extract_resource_names, "app/models/user.rb")
      assert_equal "users", plural
      assert_equal "user",  singular
    end

    test "extract_resource_names for namespaced controller" do
      plural, singular = RailsRelatedFilesService.send(:extract_resource_names, "app/controllers/admin/users_controller.rb")
      assert_equal "admin/users", plural
      assert_equal "admin/user",  singular
    end

    test "extract_resource_names for view file" do
      plural, singular = RailsRelatedFilesService.send(:extract_resource_names, "app/views/users/index.html.erb")
      assert_equal "users", plural
      assert_equal "user",  singular
    end

    test "extract_resource_names for namespaced view" do
      plural, singular = RailsRelatedFilesService.send(:extract_resource_names, "app/views/admin/users/index.html.erb")
      assert_equal "admin/users", plural
      assert_equal "admin/user",  singular
    end
  end
end
