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
  end
end
