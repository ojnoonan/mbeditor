# frozen_string_literal: true

module Mbeditor
  # Parses db/schema.rb to extract the table definition for a given model name.
  # Returns nil when the schema file is missing or the table is not found.
  #
  # Return format:
  #   {
  #     table:   "users",
  #     model:   "User",
  #     columns: [{ name: "id", type: "integer" }, ...],
  #     indexes: [{ name: "idx_users_on_email", columns: ["email"], unique: true }]
  #   }
  class SchemaService
    SCHEMA_PATH = "db/schema.rb"

    def initialize(model_name, workspace_root)
      @model_name     = model_name.to_s.strip
      @workspace_root = workspace_root.to_s
    end

    def call
      return nil if @model_name.empty? || @workspace_root.empty?

      table_name  = derive_table_name(@model_name)
      schema_path = File.join(@workspace_root, SCHEMA_PATH)
      return nil unless File.exist?(schema_path)

      begin
        content = File.read(schema_path, encoding: "utf-8")
      rescue Errno::ENOENT, Errno::EACCES
        return nil
      end

      parse_table(content, table_name)
    end

    private

    # "User" → "users", "OrderItem" → "order_items", "Order Item" → "order_items"
    def derive_table_name(model_name)
      normalized = model_name.delete(" ")
      ActiveSupport::Inflector.tableize(normalized)
    end

    # Finds the create_table block and parses it.
    # Uses the leading-whitespace backreference to match the correct closing `end`.
    def parse_table(content, table_name)
      re = /^( *)create_table\s+"#{Regexp.escape(table_name)}"([^\n]*)\n(.*?)^\1end\b/m
      m  = content.match(re)
      return nil unless m

      body = m[3]

      {
        table:   table_name,
        model:   @model_name,
        columns: parse_columns(body),
        indexes: parse_indexes(body)
      }
    end

    # Parses `t.type "name", options...` column lines.
    def parse_columns(body)
      columns = []
      body.scan(/^\s+t\.(\w+)\s+"([^"]+)"(.*)$/) do |type, name, rest|
        next if type == "index"

        col = { name: name, type: type }
        col[:null]        = false if rest.include?("null: false")
        col[:primary_key] = true  if rest.include?("primary_key: true")

        if (m = rest.match(/default:\s*(.+?)(?:,\s*\w|$)/))
          col[:default] = m[1].strip
        end
        if (m = rest.match(/limit:\s*(\d+)/))
          col[:limit] = m[1].to_i
        end
        if (m = rest.match(/precision:\s*(\d+)/))
          col[:precision] = m[1].to_i
        end
        if (m = rest.match(/scale:\s*(\d+)/))
          col[:scale] = m[1].to_i
        end

        columns << col
      end
      columns
    end

    # Parses `t.index ["col"], name: "idx", unique: true` index lines.
    def parse_indexes(body)
      indexes = []
      body.scan(/^\s+t\.index\s+\[([^\]]*)\](.*)$/) do |cols_str, rest|
        cols = cols_str.scan(/"([^"]+)"/).flatten
        next if cols.empty?

        idx = { columns: cols }
        if (m = rest.match(/name:\s*"([^"]+)"/))
          idx[:name] = m[1]
        end
        idx[:unique] = true if rest.include?("unique: true")
        indexes << idx
      end
      indexes
    end
  end
end
