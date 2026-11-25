# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

module Mbeditor
  class RelatedFilesServiceTest < Minitest::Test
    GRAPH = {
      ok: true,
      models: [
        { name: "User", table: "users", file: "app/models/user.rb" },
        { name: "Order", table: "orders", file: "app/models/order.rb" },
        { name: "Profile", table: "profiles", file: "app/models/profile.rb" }
      ],
      edges: [
        { from: "User", to: "Order", macro: "has_many", name: "orders", through: nil },
        { from: "Order", to: "User", macro: "belongs_to", name: "user", through: nil }
      ]
    }.freeze

    def setup
      @dir = Dir.mktmpdir("mbeditor_rfs_")
      write("app/models/user.rb", "class User < ApplicationRecord; end\n")
      write("app/models/order.rb", "class Order < ApplicationRecord; end\n")
      write("app/models/profile.rb", "class Profile < ApplicationRecord; end\n")
      write("app/controllers/users_controller.rb", "class UsersController; end\n")
      write("app/views/users/index.html.erb", "<h1>x</h1>\n")
      write("app/helpers/users_helper.rb", "module UsersHelper; end\n")
      write("test/models/user_test.rb", "# t\n")
      write("db/migrate/001_create_users.rb", "create_table :users do |t|\nend\n")
      write("db/migrate/002_add_age_to_users.rb", "add_column :users, :age, :integer\n")
      write("db/migrate/003_add_user_to_orders.rb", "add_reference :orders, :user, foreign_key: true\n")
      write("db/migrate/004_create_things.rb", "create_table :things do |t|\n  t.references :user\nend\n")
      write("db/migrate/005_unrelated.rb", "create_table :users_roles_x do |t|\nend\nadd_column :posts, :title, :string\n")
      write("db/schema.rb", "create_table \"users\", force: :cascade do |t|\nend\n")
      write("lib/billing.rb", "Billing.charge(User.first)\n")
      write("lib/audit.rb", "Audit.log('users')\n")
      write("lib/other.rb", "Username = 1\n")
      ModelGraphService.define_singleton_method(:call) { |_root| GRAPH }
    end

    def teardown
      ModelGraphService.singleton_class.send(:remove_method, :call)
      FileUtils.remove_entry(@dir)
    end

    def write(rel, content)
      full = File.join(@dir, rel)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, content)
    end

    def run_service(query = "User", excluded: [])
      RelatedFilesService.call(@dir, query, excluded_paths: excluded)
    end

    def by_path(result)
      result[:files].to_h { |f| [f[:path], f] }
    end

    def test_convention_files_are_direct
      files = by_path(run_service)
      {
        "app/models/user.rb" => "model", "app/controllers/users_controller.rb" => "controller",
        "app/views/users/index.html.erb" => "view", "app/helpers/users_helper.rb" => "helper",
        "test/models/user_test.rb" => "test"
      }.each do |path, reason|
        assert_equal reason, files.dig(path, :reason), path
        assert files[path][:direct], path
      end
    end

    def test_associated_models_are_one_hop_and_not_direct
      files = by_path(run_service)
      assert_equal "has_many :orders", files.dig("app/models/order.rb", :reason)
      refute files["app/models/order.rb"][:direct]
      assert_nil files["app/models/profile.rb"]
    end

    def test_incoming_association_names_the_owning_model
      graph = GRAPH.merge(edges: [{ from: "Order", to: "User", macro: "belongs_to", name: "user", through: nil }])
      ModelGraphService.define_singleton_method(:call) { |_root| graph }
      write("app/models/order.rb", "class Order; end\n")
      assert_equal "belongs_to :user (Order)", by_path(run_service).dig("app/models/order.rb", :reason)
    end

    def test_migrations_and_schema_are_direct
      files = by_path(run_service)
      assert_equal "alters users", files.dig("db/migrate/001_create_users.rb", :reason)
      assert_equal "alters users", files.dig("db/migrate/002_add_age_to_users.rb", :reason)
      assert_equal "adds user reference", files.dig("db/migrate/003_add_user_to_orders.rb", :reason)
      assert_equal "adds user reference", files.dig("db/migrate/004_create_things.rb", :reason)
      assert_equal "defines users", files.dig("db/schema.rb", :reason)
      assert_nil files["db/migrate/005_unrelated.rb"]
      assert(%w[db/migrate/001_create_users.rb db/schema.rb].all? { |p| files[p][:direct] })
    end

    def test_references_use_word_boundaries_and_are_not_direct
      files = by_path(run_service)
      assert_equal "references User", files.dig("lib/billing.rb", :reason)
      assert_equal "references users", files.dig("lib/audit.rb", :reason)
      refute files["lib/billing.rb"][:direct]
      assert_nil files["lib/other.rb"]
    end

    def test_dedupe_keeps_the_direct_reason
      result = run_service
      paths = result[:files].map { |f| f[:path] }
      assert_equal paths.uniq, paths
      assert_equal "model", by_path(result).dig("app/models/user.rb", :reason)
    end

    def test_reference_cap_is_reported
      (RelatedFilesService::MAX_REFERENCE_FILES + 5).times { |i| write("lib/gen/g#{i}.rb", "User.first\n") }
      result = run_service
      assert result[:capped]
      assert_operator result[:files].count { |f| f[:reason].start_with?("references") }, :<=, RelatedFilesService::MAX_REFERENCE_FILES
    end

    def test_not_capped_for_a_small_workspace
      refute run_service[:capped]
    end

    def test_excluded_paths_are_dropped_everywhere
      files = by_path(run_service(excluded: %w[db lib app/models/order.rb]))
      assert_empty files.keys.grep(%r{\A(db|lib)/})
      assert_nil files["app/models/order.rb"]
      assert files["app/models/user.rb"]
    end

    def test_models_outside_the_workspace_are_dropped
      graph = GRAPH.merge(models: GRAPH[:models] + [{ name: "Ghost", table: "ghosts", file: "../outside.rb" }],
                          edges: [{ from: "User", to: "Ghost", macro: "has_one", name: "ghost", through: nil }])
      ModelGraphService.define_singleton_method(:call) { |_root| graph }
      assert(run_service[:files].none? { |f| f[:path].include?("..") })
    end

    def test_without_a_model_the_table_name_is_underscore_pluralize
      write("lib/widget.rb", "Db.table('widget_parts')\n")
      assert_equal "references widget_parts", by_path(run_service("WidgetPart")).dig("lib/widget.rb", :reason)
    end
  end
end
