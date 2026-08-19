# frozen_string_literal: true

module Mbeditor
  # Parses db/schema.rb or db/structure.sql to extract table definitions.
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
    SCHEMA_RB_PATH = "db/schema.rb"
    STRUCTURE_SQL_PATH = "db/structure.sql"

    def initialize(model_name, workspace_root)
      @model_name     = model_name.to_s.strip
      @workspace_root = workspace_root.to_s
    end

    def call
      return nil if @model_name.empty? || @workspace_root.empty?

      table_name = derive_table_name(@model_name)

      # Try schema.rb first (Ruby format)
      result = try_schema_rb(table_name)
      return result if result

      # Try structure.sql (SQL format)
      result = try_structure_sql(table_name)
      return result if result

      Rails.logger.debug("SchemaService: table '#{table_name}' (from model '#{@model_name}') not found in db/schema.rb or db/structure.sql. Check if model has custom table_name.")
      nil
    end

    private

    # "User" → "users", "OrderItem" → "order_items", "Order Item" → "order_items"
    # Also checks the model file for an explicit `self.table_name = "..."` declaration.
    def derive_table_name(model_name)
      normalized = model_name.delete(" ")

      # Check model file for an explicit table_name override
      singular = ActiveSupport::Inflector.underscore(normalized)
      model_file = File.join(@workspace_root, "app", "models", "#{singular}.rb")
      if File.exist?(model_file)
        begin
          source = File.read(model_file, encoding: "utf-8")
          # Matches: self.table_name = "name"  or  = :name  or  = 'name'
          if (m = source.match(/self\.table_name\s*=\s*[:"']([^"'\s]+)["']?/))
            return m[1]
          end
        rescue StandardError
          # fall through to default derivation
        end
      end

      ActiveSupport::Inflector.tableize(normalized)
    end

    # Try to read and parse db/schema.rb
    def try_schema_rb(table_name)
      schema_path = File.join(@workspace_root, SCHEMA_RB_PATH)
      return nil unless File.exist?(schema_path)

      begin
        content = File.read(schema_path, encoding: "utf-8")
        parse_schema_rb(content, table_name)
      rescue StandardError => e
        Rails.logger.debug("SchemaService: failed to read #{schema_path}: #{e.message}")
        nil
      end
    end

    # Try to read and parse db/structure.sql
    def try_structure_sql(table_name)
      schema_path = File.join(@workspace_root, STRUCTURE_SQL_PATH)
      return nil unless File.exist?(schema_path)

      begin
        content = File.read(schema_path, encoding: "utf-8")
        parse_structure_sql(content, table_name)
      rescue StandardError => e
        Rails.logger.debug("SchemaService: failed to read #{schema_path}: #{e.message}")
        nil
      end
    end

    # ── Schema.rb parsing (Ruby DSL) ──────────────────────────────────────

    # Finds the create_table block and parses it.
    # Uses the leading-whitespace backreference to match the correct closing `end`.
    def parse_schema_rb(content, table_name)
      re = /^( *)create_table\s+"#{Regexp.escape(table_name)}"([^\n]*)\n(.*?)^\1end\b/m
      m  = content.match(re)
      return nil unless m

      body = m[3]

      {
        table:   table_name,
        model:   @model_name,
        columns: parse_schema_rb_columns(body),
        indexes: parse_schema_rb_indexes(body)
      }
    end

    # Parses `t.type "name", options...` column lines from schema.rb
    def parse_schema_rb_columns(body)
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

    # Parses `t.index ["col"], name: "idx", unique: true` index lines from schema.rb
    def parse_schema_rb_indexes(body)
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

    # ── Structure.sql parsing (SQL DDL) ──────────────────────────────────

    # Parses structure.sql (SQL format) to extract table definition
    def parse_structure_sql(content, table_name)
      # Match CREATE TABLE ... ( ... ) with support for various SQL dialects
      # Handles: PostgreSQL, MySQL, SQLite with quoted/unquoted names
      # Ends with different delimiters: ); ENGINE...; or just );
      quoted_name = Regexp.escape(table_name)
      # Schema prefix pattern: matches public., "public"., myschema., "myschema". or nothing.
      schema_prefix = /(?:(?:"[^"]+"|`[^`]+`|\w+)\.)?/
      patterns = [
        # PostgreSQL: CREATE TABLE [schema.]table ( ... );
        /CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?#{schema_prefix}["`]?#{quoted_name}["`]?\s*\(([\s\S]*?)\)\s*;/mi,
        # MySQL: CREATE TABLE [schema.]`table` ( ... ) ENGINE=...;
        /CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?#{schema_prefix}["`]?#{quoted_name}["`]?\s*\(([\s\S]*?)\)\s*(?:ENGINE|DEFAULT)/mi
      ]

      table_def = nil
      patterns.each do |pattern|
        if (m = content.match(pattern))
          table_def = m[1]
          break
        end
      end

      return nil unless table_def

      {
        table:   table_name,
        model:   @model_name,
        columns: parse_sql_columns(table_def),
        indexes: parse_sql_indexes(content, table_name)
      }
    end

    # Parses column definitions from SQL CREATE TABLE body
    def parse_sql_columns(table_def)
      columns = []

      # Process line by line to handle complex type declarations like decimal(10,2)
      table_def.each_line do |line|
        line = line.strip
        next if line.empty?
        next if line.match?(/^(PRIMARY|UNIQUE|FOREIGN|KEY|INDEX|CONSTRAINT)/i)

        # Extract column name and full definition
        # Matches: `name` type(...) constraints, name type NOT NULL, etc.
        if (m = line.match(/^["`]?(\w+)["`]?\s+(.+?)\s*,?\s*$/i))
          col_name = m[1]
          definition = m[2]

          # Split at constraint keywords to isolate the type
          # Extract everything before NOT NULL, NULL, AUTO_INCREMENT, DEFAULT, PRIMARY, etc.
          col_type_and_params = definition.split(/\s+(?:NOT\s+NULL|NULL|AUTO_INCREMENT|DEFAULT|PRIMARY|UNIQUE|CHECK|COLLATE|COMMENT|ON|USING)/i).first.strip.downcase

          # Extract base type (before parentheses)
          col_type = col_type_and_params.split('(').first.strip
          col = { name: col_name, type: sql_type_to_rails(col_type) }

          col[:null] = false if definition.match?(/\bNOT\s+NULL\b/i)
          col[:primary_key] = true if definition.match?(/\bPRIMARY\s+KEY\b/i)

          # Extract precision and scale for decimals/numeric types
          if (pm = col_type_and_params.match(/\((\d+),\s*(\d+)\)/))
            col[:precision] = pm[1].to_i
            col[:scale] = pm[2].to_i
          elsif (pm = col_type_and_params.match(/\((\d+)\)/))
            col[:limit] = pm[1].to_i
          end

          columns << col
        end
      end

      columns
    end

    # Parses index definitions from structure.sql
    def parse_sql_indexes(content, table_name)
      indexes = []

      # Match CREATE INDEX ... ON table_name (columns). UNIQUE is captured here
      # rather than re-scanned per index with a freshly compiled regex.
      pattern = /CREATE\s+(UNIQUE\s+)?INDEX\s+["`]?(\w+)["`]?\s+ON\s+(?:public\.)?["`]?#{Regexp.escape(table_name)}["`]?\s*\((.*?)\)/mi

      content.scan(pattern) do |unique, index_name, columns_str|
        cols = columns_str.split(',').map { |c| c.strip.gsub(/["`]/, '').split(/\s+/).first }.compact
        next if cols.empty?

        idx = {
          name: index_name,
          columns: cols
        }
        idx[:unique] = true if unique

        indexes << idx
      end

      indexes
    end

    # Map SQL types to Rails column types
    SQL_TYPE_TO_RAILS = {
      'integer' => 'integer',
      'int' => 'integer',
      'int4' => 'integer',
      'int2' => 'integer',
      'int8' => 'bigint',
      'bigint' => 'bigint',
      'smallint' => 'integer',
      'bigserial' => 'bigint',
      'serial' => 'integer',
      'varchar' => 'string',
      'character varying' => 'string',
      'character' => 'string',
      'char' => 'string',
      'text' => 'text',
      'citext' => 'string',
      'boolean' => 'boolean',
      'bool' => 'boolean',
      'decimal' => 'decimal',
      'numeric' => 'decimal',
      'real' => 'float',
      'float' => 'float',
      'float4' => 'float',
      'float8' => 'float',
      'double precision' => 'float',
      'double' => 'float',
      'money' => 'decimal',
      'timestamp' => 'datetime',
      'timestamp without time zone' => 'datetime',
      'timestamp with time zone' => 'datetime',
      'timestamptz' => 'datetime',
      'datetime' => 'datetime',
      'date' => 'date',
      'time' => 'time',
      'time without time zone' => 'time',
      'time with time zone' => 'time',
      'interval' => 'string',
      'json' => 'json',
      'jsonb' => 'jsonb',
      'uuid' => 'uuid',
      'bytea' => 'binary',
      'bit' => 'string',
      'bit varying' => 'string',
      'inet' => 'string',
      'cidr' => 'string',
      'macaddr' => 'string',
      'xml' => 'string',
      'hstore' => 'hstore',
      'tsvector' => 'string',
      'ltree' => 'string',
      'point' => 'string',
      'line' => 'string',
      'lseg' => 'string',
      'box' => 'string',
      'path' => 'string',
      'polygon' => 'string',
      'circle' => 'string'
    }.freeze

    def sql_type_to_rails(sql_type)
      SQL_TYPE_TO_RAILS[sql_type.downcase] || sql_type
    end
  end
end
