# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class MigrationStatusServiceTest < ActiveSupport::TestCase
    FakeConn = Struct.new(:versions) do
      def select_values(_sql) = versions
    end

    class FakePool
      def initialize(conn = nil, error: nil)
        @conn = conn
        @error = error
      end

      def with_connection
        raise @error if @error

        yield @conn
      end
    end

    def setup
      @root = Dir.mktmpdir("mbeditor_mig_")
      FileUtils.mkdir_p(File.join(@root, "db", "migrate"))
      write("20240101000000_create_users.rb", "create_table :users do |t|\nend\nadd_index :users, :email\n")
      write("20240201000000_add_age_to_posts.rb", "add_column :posts, :age, :integer\n")
      File.write(File.join(@root, "db", "schema.rb"), "ActiveRecord::Schema[7.1].define(version: 2024_02_01_000000) do\nend\n")
    end

    def teardown
      FileUtils.rm_rf(@root)
    end

    test "marks applied and pending, newest first, with tables and orphans" do
      result = with_pool(FakePool.new(FakeConn.new(%w[20240101000000 19990101000000]))) { MigrationStatusService.call(@root) }
      assert_equal "ok", result[:db]
      assert_equal %w[20240201000000 20240101000000], result[:migrations].map { |m| m[:version] }
      assert_equal %w[down up], result[:migrations].map { |m| m[:status] }
      assert_equal %w[users], result[:migrations].last[:tables]
      assert_equal %w[posts], result[:migrations].first[:tables]
      assert_equal "db/migrate/20240201000000_add_age_to_posts.rb", result[:migrations].first[:file]
      assert_equal %w[19990101000000], result[:orphaned]
      assert_equal "20240201000000", result[:schema_version]
    end

    test "models come from tables: one per table, Other when none" do
      write("20240301000000_link_order_items.rb", "add_reference :order_items, :user\nadd_column :users, :n, :integer\n")
      write("20240401000000_run_sql.rb", "execute 'select 1'\n")
      by_version = with_pool(FakePool.new(FakeConn.new([]))) { MigrationStatusService.call(@root) }[:migrations].to_h { |m| [m[:version], m[:models]] }

      assert_equal %w[OrderItem User], by_version["20240301000000"]
      assert_equal %w[Other], by_version["20240401000000"]
      assert_equal %w[Post], by_version["20240201000000"]
    end

    test "unreachable database yields unknown statuses and never raises" do
      result = with_pool(FakePool.new(error: RuntimeError.new("boom"))) { MigrationStatusService.call(@root) }
      assert_equal "unavailable", result[:db]
      assert_equal "RuntimeError", result[:error]
      assert_equal %w[unknown unknown], result[:migrations].map { |m| m[:status] }
      assert_empty result[:orphaned]
    end

    private

    def write(name, body)
      File.write(File.join(@root, "db", "migrate", name), body)
    end

    def with_pool(pool)
      original = ActiveRecord::Base.method(:connection_pool)
      ActiveRecord::Base.define_singleton_method(:connection_pool) { pool }
      yield
    ensure
      ActiveRecord::Base.define_singleton_method(:connection_pool, original)
    end
  end
end
