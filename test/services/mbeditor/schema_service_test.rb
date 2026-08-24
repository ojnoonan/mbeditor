# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class SchemaServiceTest < ActiveSupport::TestCase
    SAMPLE_SCHEMA = <<~RUBY
      ActiveRecord::Schema[7.1].define(version: 2024_01_01_000000) do
        create_table "users", force: :cascade do |t|
          t.string "name", null: false
          t.string "email", null: false
          t.integer "age"
          t.boolean "admin", default: false
          t.decimal "balance", precision: 10, scale: 2
          t.datetime "created_at", null: false
          t.datetime "updated_at", null: false
          t.index ["email"], name: "index_users_on_email", unique: true
          t.index ["name", "age"], name: "index_users_on_name_and_age"
        end

        create_table "posts", force: :cascade do |t|
          t.string "title", null: false
          t.bigint "user_id", null: false
          t.datetime "created_at", null: false
        end
      end
    RUBY

    def setup
      @workspace = Dir.mktmpdir("mbeditor_schema_test_")
      db_dir = File.join(@workspace, "db")
      FileUtils.mkdir_p(db_dir)
      File.write(File.join(db_dir, "schema.rb"), SAMPLE_SCHEMA)
    end

    def teardown
      FileUtils.rm_rf(@workspace)
    end

    def call(model_name)
      SchemaService.new(model_name, @workspace).call
    end

    # ── found / not found ────────────────────────────────────────────────

    test "returns nil when schema file does not exist" do
      FileUtils.rm(File.join(@workspace, "db", "schema.rb"))
      assert_nil call("User")
    end

    test "returns nil for unknown model" do
      assert_nil call("Widget")
    end

    test "returns result hash for known model" do
      result = call("User")
      assert_instance_of Hash, result
    end

    # ── table / model name ───────────────────────────────────────────────

    test "result includes correct table name" do
      assert_equal "users", call("User")[:table]
    end

    test "result includes model name as given" do
      assert_equal "User", call("User")[:model]
    end

    test "strips spaces from model name for table lookup" do
      # No "order items" table in sample, just testing derivation doesn't blow up
      assert_nil call("Order Item")
    end

    # ── columns ──────────────────────────────────────────────────────────

    test "parses string column" do
      cols = call("User")[:columns]
      name_col = cols.find { |c| c[:name] == "name" }
      assert name_col, "expected name column"
      assert_equal "string", name_col[:type]
      assert_equal false, name_col[:null]
    end

    test "parses integer column without null constraint" do
      cols = call("User")[:columns]
      age_col = cols.find { |c| c[:name] == "age" }
      assert age_col
      assert_equal "integer", age_col[:type]
      refute age_col.key?(:null), "null key should be absent when not constrained"
    end

    test "parses boolean column with default" do
      cols = call("User")[:columns]
      admin_col = cols.find { |c| c[:name] == "admin" }
      assert admin_col
      assert_equal "boolean", admin_col[:type]
      assert_equal "false", admin_col[:default]
    end

    test "parses decimal column with precision and scale" do
      cols = call("User")[:columns]
      balance_col = cols.find { |c| c[:name] == "balance" }
      assert balance_col
      assert_equal "decimal", balance_col[:type]
      assert_equal 10, balance_col[:precision]
      assert_equal 2, balance_col[:scale]
    end

    test "does not include t.index lines as columns" do
      cols = call("User")[:columns]
      refute cols.any? { |c| c[:type] == "index" }
    end

    # ── indexes ──────────────────────────────────────────────────────────

    test "parses unique single-column index" do
      indexes = call("User")[:indexes]
      email_idx = indexes.find { |i| i[:name] == "index_users_on_email" }
      assert email_idx
      assert_equal ["email"], email_idx[:columns]
      assert email_idx[:unique]
    end

    test "parses non-unique multi-column index" do
      indexes = call("User")[:indexes]
      multi_idx = indexes.find { |i| i[:name] == "index_users_on_name_and_age" }
      assert multi_idx
      assert_equal ["name", "age"], multi_idx[:columns]
      refute multi_idx[:unique]
    end

    # ── second table ─────────────────────────────────────────────────────

    test "can retrieve a second table from the same schema" do
      result = call("Post")
      assert result
      assert_equal "posts", result[:table]
      cols = result[:columns]
      assert cols.any? { |c| c[:name] == "title" && c[:type] == "string" }
    end

    # ── workspace missing / empty model ──────────────────────────────────

    test "returns nil for blank model name" do
      assert_nil SchemaService.new("", @workspace).call
    end

    test "returns nil for blank workspace" do
      assert_nil SchemaService.new("User", "").call
    end

    # ── structure.sql support ────────────────────────────────────────────

    test "parses structure.sql (PostgreSQL format)" do
      # Remove schema.rb so it tries structure.sql
      FileUtils.rm(File.join(@workspace, "db", "schema.rb"))

      # Create a PostgreSQL-style structure.sql
      structure_sql = <<~SQL
        CREATE TABLE public.users (
            id bigint NOT NULL,
            name character varying NOT NULL,
            email character varying NOT NULL,
            admin boolean DEFAULT false NOT NULL,
            created_at timestamp(6) without time zone NOT NULL,
            updated_at timestamp(6) without time zone NOT NULL
        );

        CREATE INDEX index_users_on_email ON public.users USING btree (email);
      SQL

      File.write(File.join(@workspace, "db", "structure.sql"), structure_sql)

      result = call("User")
      assert result, "should find schema in structure.sql"
      assert_equal "users", result[:table]
      assert_equal "User", result[:model]

      cols = result[:columns]
      name_col = cols.find { |c| c[:name] == "name" }
      assert name_col
      assert_equal "string", name_col[:type]
      assert_equal false, name_col[:null]
    end

    test "structure.sql indexes carry unique only for CREATE UNIQUE INDEX" do
      FileUtils.rm(File.join(@workspace, "db", "schema.rb"))

      structure_sql = <<~SQL
        CREATE TABLE public.users (
            id bigint NOT NULL,
            email character varying NOT NULL
        );

        CREATE UNIQUE INDEX index_users_on_email ON public.users (email);
        CREATE INDEX index_users_on_id ON public.users (id);
      SQL

      File.write(File.join(@workspace, "db", "structure.sql"), structure_sql)

      indexes = call("User")[:indexes]
      assert indexes.find { |i| i[:name] == "index_users_on_email" }[:unique]
      refute indexes.find { |i| i[:name] == "index_users_on_id" }[:unique]
    end

    test "parses structure.sql (MySQL format)" do
      FileUtils.rm(File.join(@workspace, "db", "schema.rb"))

      structure_sql = <<~SQL
        CREATE TABLE `orders` (
          `id` bigint NOT NULL AUTO_INCREMENT,
          `status` varchar(255) NOT NULL DEFAULT 'pending',
          `total` decimal(10,2),
          `created_at` datetime(6) NOT NULL,
          `updated_at` datetime(6) NOT NULL,
          PRIMARY KEY (`id`),
          KEY `index_orders_on_status` (`status`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
      SQL

      File.write(File.join(@workspace, "db", "structure.sql"), structure_sql)

      result = call("Order")
      assert result, "should find schema in structure.sql"
      assert_equal "orders", result[:table]

      cols = result[:columns]
      status_col = cols.find { |c| c[:name] == "status" }
      assert status_col
      assert_equal "string", status_col[:type]

      total_col = cols.find { |c| c[:name] == "total" }
      assert total_col
      assert_equal "decimal", total_col[:type]
      assert_equal 10, total_col[:precision]
      assert_equal 2, total_col[:scale]
    end

    test "prefers schema.rb over structure.sql when both exist" do
      structure_sql = <<~SQL
        CREATE TABLE users (
            id integer NOT NULL
        );
      SQL

      File.write(File.join(@workspace, "db", "structure.sql"), structure_sql)

      result = call("User")
      assert result

      # Should have come from schema.rb (has name and email), not structure.sql (only has id)
      cols = result[:columns]
      assert cols.any? { |c| c[:name] == "name" }, "should parse from schema.rb, not structure.sql"
    end

    test "returns nil for unknown table in structure.sql" do
      FileUtils.rm(File.join(@workspace, "db", "schema.rb"))
      File.write(File.join(@workspace, "db", "structure.sql"), "CREATE TABLE users (id integer);")

      assert_nil call("Widget")
    end

    test "parses structure.sql with quoted schema prefix" do
      FileUtils.rm(File.join(@workspace, "db", "schema.rb"))
      File.write(File.join(@workspace, "db", "structure.sql"), <<~SQL)
        CREATE TABLE "public"."users" (
            id bigint NOT NULL,
            name character varying NOT NULL
        );
      SQL

      result = call("User")
      assert result, "should parse table with quoted schema prefix"
      assert_equal "users", result[:table]
      assert result[:columns].any? { |c| c[:name] == "name" }
    end

    test "parses structure.sql with non-public schema prefix" do
      FileUtils.rm(File.join(@workspace, "db", "schema.rb"))
      File.write(File.join(@workspace, "db", "structure.sql"), <<~SQL)
        CREATE TABLE myschema.users (
            id bigint NOT NULL,
            email character varying NOT NULL
        );
      SQL

      result = call("User")
      assert result, "should parse table with non-public schema prefix"
      assert_equal "users", result[:table]
    end

    test "parses structure.sql with no schema prefix" do
      FileUtils.rm(File.join(@workspace, "db", "schema.rb"))
      File.write(File.join(@workspace, "db", "structure.sql"), <<~SQL)
        CREATE TABLE users (
            id bigint NOT NULL,
            name character varying NOT NULL
        );
      SQL

      result = call("User")
      assert result, "should parse table with no schema prefix"
      assert_equal "users", result[:table]
    end

    test "reads custom table_name from model file" do
      models_dir = File.join(@workspace, "app", "models")
      FileUtils.mkdir_p(models_dir)
      File.write(File.join(models_dir, "user.rb"), <<~RUBY)
        class User < ApplicationRecord
          self.table_name = "accounts"
        end
      RUBY

      # Rewrite schema.rb with the custom table name
      File.write(File.join(@workspace, "db", "schema.rb"), <<~RUBY)
        ActiveRecord::Schema[7.1].define(version: 1) do
          create_table "accounts", force: :cascade do |t|
            t.string "name", null: false
          end
        end
      RUBY

      result = call("User")
      assert result, "should find table via custom self.table_name"
      assert_equal "accounts", result[:table]
      assert result[:columns].any? { |c| c[:name] == "name" }
    end

    test "reads custom table_name declared with symbol" do
      models_dir = File.join(@workspace, "app", "models")
      FileUtils.mkdir_p(models_dir)
      File.write(File.join(models_dir, "user.rb"), <<~RUBY)
        class User < ApplicationRecord
          self.table_name = :legacy_users
        end
      RUBY

      File.write(File.join(@workspace, "db", "schema.rb"), <<~RUBY)
        ActiveRecord::Schema[7.1].define(version: 1) do
          create_table "legacy_users", force: :cascade do |t|
            t.string "email", null: false
          end
        end
      RUBY

      result = call("User")
      assert result, "should find table via symbol self.table_name"
      assert_equal "legacy_users", result[:table]
    end

    # ── path containment ─────────────────────────────────────────────────

    # The controller validates the model name, but the service must not depend
    # on that: underscore("../../x") is "../../x", and File.join makes it a path.
    test "a traversing model name reads no file outside the workspace" do
      outside = Dir.mktmpdir("mbeditor_schema_outside_")
      File.write(File.join(outside, "secret.rb"), "self.table_name = \"pwned\"\n")

      begin
        rel = Pathname(outside).relative_path_from(Pathname(File.join(@workspace, "app", "models")))
        result = call(File.join(rel.to_s, "secret"))

        refute_equal "pwned", result&.dig(:table),
                     "the escaping model file must not be read for its table_name"
      ensure
        FileUtils.rm_rf(outside)
      end
    end

    # A name check cannot catch this one: "User" is a perfectly valid constant,
    # and the escape is in the filesystem rather than the parameter.
    test "a symlinked model file pointing outside the workspace is not read" do
      outside = Dir.mktmpdir("mbeditor_schema_outside_")
      File.write(File.join(outside, "evil.rb"), "self.table_name = \"pwned\"\n")
      models = File.join(@workspace, "app", "models")
      FileUtils.mkdir_p(models)

      begin
        File.symlink(File.join(outside, "evil.rb"), File.join(models, "user.rb"))
      rescue NotImplementedError, SystemCallError
        skip "symlinks unavailable on this filesystem"
      end

      begin
        result = call("User")
        refute_equal "pwned", result&.dig(:table),
                     "a symlink out of the workspace must not be followed"
      ensure
        FileUtils.rm_rf(outside)
      end
    end
  end
end
