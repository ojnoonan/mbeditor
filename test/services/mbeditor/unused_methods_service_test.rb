# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class UnusedMethodsServiceTest < Minitest::Test
    def setup
      @workspace = Dir.mktmpdir("mbeditor_unused_test_")
      Mbeditor.configure do |c|
        c.workspace_root = @workspace
        c.excluded_paths = %w[legacy]
      end
    end

    def teardown
      FileUtils.remove_entry(@workspace)
      Mbeditor.configure { |c| c.excluded_paths = Configuration.new.excluded_paths }
    end

    def write(path, content)
      full = File.join(@workspace, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, content)
    end

    def names
      UnusedMethodsService.call(@workspace)[:methods].map { |m| m[:name] }
    end

    def test_unused_ruby_method_is_reported_with_location
      write("app/models/thing.rb", "class Thing\n  def dead_one\n  end\n\n  def self.alive\n  end\nend\n")
      write("app/models/other.rb", "Thing.alive\n")

      result = UnusedMethodsService.call(@workspace)

      assert_equal [{ file: "app/models/thing.rb", line: 2, name: "dead_one", kind: "def" }], result[:methods]
      assert_equal 2, result[:scanned]
      refute result[:truncated]
    end

    def test_method_used_only_in_views_is_not_reported
      write("app/helpers/h.rb", "module H\n  def erb_used\n  end\n\n  def haml_used\n  end\nend\n")
      write("app/views/a.html.erb", "<%= erb_used %>\n")
      write("app/views/b.html.haml", "= haml_used\n")

      assert_equal [], names
    end

    def test_symbol_reference_counts_as_use
      write("app/controllers/c.rb", "class C\n  before_action :foo\n\n  private\n\n  def foo\n  end\nend\n")

      assert_equal [], names
    end

    def test_unused_js_function_is_found
      write("app/assets/a.js", "function deadFn() {}\nconst deadArrow = () => 1;\nclass K {\n  deadMethod() {\n  }\n}\nfunction liveFn() {}\nliveFn();\n")

      assert_equal %w[deadArrow deadFn deadMethod], names.sort
    end

    def test_excluded_path_is_ignored
      write("legacy/old.rb", "def old_dead\nend\n")

      result = UnusedMethodsService.call(@workspace)

      assert_equal [], result[:methods]
      assert_equal 0, result[:scanned]
    end

    def test_test_names_initialize_and_test_files_are_ignored
      write("app/models/m.rb", "class M\n  def initialize\n  end\n\n  def test_thing\n  end\nend\n")
      write("test/m_test.rb", "def helper_in_test\nend\n")

      assert_equal [], names
    end

    def test_files_lists_paths_where_every_method_is_unused
      write("app/models/all_dead.rb", "class AllDead\n  def a_dead\n  end\n\n  def b_dead\n  end\nend\n")
      write("app/models/mixed.rb", "class Mixed\n  def m_dead\n  end\n\n  def m_live\n  end\nend\n")
      write("app/models/use.rb", "Mixed.new.m_live\n")

      assert_equal ["app/models/all_dead.rb"], UnusedMethodsService.call(@workspace)[:files]
    end
  end
end
