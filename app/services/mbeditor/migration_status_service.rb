# frozen_string_literal: true

module Mbeditor
  # Read-only migration status: db/migrate files joined with the versions in
  # schema_migrations. One SELECT, no migrate/rollback, no subprocess, no writes.
  class MigrationStatusService
    FILE = /\A(\d+)_(.+)\.rb\z/
    TABLE_CALL = /\b(?:create_table|change_table|drop_table|add_column|remove_column|rename_column|change_column|add_index|remove_index|add_reference|remove_reference|add_belongs_to)\s*\(?\s*[:"'](\w+)/
    SCHEMA_VERSION = /define\s*\(\s*version:\s*([\d_]+)/

    def self.call(root)
      applied, error = applied_versions
      files = Dir.glob(File.join(root, "db", "migrate", "*.rb")).filter_map { |abs| entry(root, abs, applied) }
      known = files.to_set { |m| m[:version] }
      {
        db: applied ? "ok" : "unavailable",
        error: error,
        migrations: files.sort_by { |m| -m[:version].to_i },
        orphaned: applied ? (applied - known.to_a).sort.reverse : [],
        schema_version: schema_version(root)
      }
    end

    def self.applied_versions
      versions = ActiveRecord::Base.connection_pool.with_connection do |conn|
        conn.select_values("SELECT version FROM schema_migrations").map(&:to_s)
      end
      [versions, nil]
    rescue StandardError => e
      [nil, e.class.name]
    end

    def self.entry(root, abs, applied)
      m = File.basename(abs).match(FILE) or return nil
      version = m[1]
      {
        version: version,
        name: m[2],
        file: abs.delete_prefix("#{root}/"),
        tables: File.read(abs).scan(TABLE_CALL).flatten.uniq,
        status: applied.nil? ? "unknown" : (applied.include?(version) ? "up" : "down")
      }
    rescue SystemCallError
      nil
    end

    def self.schema_version(root)
      File.read(File.join(root, "db", "schema.rb"))[SCHEMA_VERSION, 1]&.delete("_")
    rescue SystemCallError
      nil
    end

    private_class_method :applied_versions, :entry, :schema_version
  end
end
