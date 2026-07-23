# frozen_string_literal: true

require "test_helper"
require "mini_racer"

module Mbeditor
  class RubyOutlineTest < ActiveSupport::TestCase
    def setup
      @context = MiniRacer::Context.new
      @context.eval("var window = this;")
      @context.eval(File.read(Mbeditor::Engine.root.join("app/assets/javascripts/mbeditor/ruby_outline.js")))
    end

    def parse(source, path: "test/models/user_test.rb")
      @context.eval("RubyOutline.parse(#{source.lines.to_json}, { path: #{path.to_json} })")
    end

    def entries(source, path: "test/models/user_test.rb")
      parse(source, path: path).fetch("entries")
    end

    test "parses methods and Rails tests with visibility" do
      result = parse(<<~RUBY)
        class UserTest
          private
          def helper
          end

          test "is valid" do
          end
        end
      RUBY

      assert_equal(
        {
          "entries" => [
            { "line" => 3, "name" => "helper", "kind" => "method",
              "depth" => 0, "visibility" => "private" },
            { "line" => 6, "name" => "is valid", "kind" => "test",
              "depth" => 0, "visibility" => nil }
          ],
          "truncated" => false
        },
        result
      )
    end

    test "tracks visibility independently in nested class and module scopes" do
      assert_equal(
        [
          { "line" => 3, "name" => "hidden", "kind" => "method", "depth" => 0, "visibility" => "private" },
          { "line" => 5, "name" => "visible", "kind" => "method", "depth" => 0, "visibility" => "public" },
          { "line" => 7, "name" => "guarded", "kind" => "method", "depth" => 0, "visibility" => "protected" },
          { "line" => 10, "name" => "nested_secret", "kind" => "method", "depth" => 0, "visibility" => "private" },
          { "line" => 12, "name" => "outer_guarded", "kind" => "method", "depth" => 0, "visibility" => "protected" }
        ],
        entries(<<~RUBY)
          class UserTest
            private
            def hidden; end
            public
            def visible; end
            protected
            def guarded; end
            module Inner
              private
              def nested_secret; end
            end
            def outer_guarded; end
          end
        RUBY
      )
    end

    test "parses class and instance method declarations" do
      assert_equal(
        [
          { "line" => 2, "name" => "self.build", "kind" => "method", "depth" => 0, "visibility" => "public" },
          { "line" => 4, "name" => "configure", "kind" => "method", "depth" => 0, "visibility" => nil },
          { "line" => 6, "name" => "test_name", "kind" => "method", "depth" => 0, "visibility" => nil }
        ],
        entries(<<~RUBY)
          class UserTest
            def self.build; end
            class << self
              def configure; end
            end
            def test_name; end
          end
        RUBY
      )
    end

    test "keeps singleton methods public after a private instance section" do
      assert_equal(
        [
          { "line" => 3, "name" => "self.singleton_method", "kind" => "method", "depth" => 0, "visibility" => "public" },
          { "line" => 4, "name" => "instance_method", "kind" => "method", "depth" => 0, "visibility" => "private" }
        ],
        entries(<<~RUBY)
          class UserTest
            private
            def self.singleton_method; end
            def instance_method; end
          end
        RUBY
      )
    end

    test "parses supported Rails test declaration forms including multiline headers" do
      assert_equal(
        [
          { "line" => 2, "name" => "single", "kind" => "test", "depth" => 0, "visibility" => nil },
          { "line" => 3, "name" => "double", "kind" => "test", "depth" => 0, "visibility" => nil },
          { "line" => 4, "name" => "parenthesized", "kind" => "test", "depth" => 0, "visibility" => nil },
          { "line" => 5, "name" => "braced", "kind" => "test", "depth" => 0, "visibility" => nil },
          { "line" => 6, "name" => "across lines", "kind" => "test", "depth" => 0, "visibility" => nil }
        ],
        entries(<<~RUBY)
          class UserTest
            test 'single' do; end
            test "double" do; end
            test("parenthesized") do; end
            test("braced") { }
            test(
              "across lines"
            ) do
            end
          end
        RUBY
      )
    end

    test "uses a stable fallback for an unparenthesized multiline description" do
      assert_equal(
        [
          { "line" => 1, "name" => "test at line 1", "kind" => "test", "depth" => 0, "visibility" => nil }
        ],
        entries(<<~'RUBY')
          test "first
          second" do
          end
        RUBY
      )
    end

    test "uses a stable fallback for a parenthesized multiline description" do
      assert_equal(
        [
          { "line" => 1, "name" => "test at line 1", "kind" => "test", "depth" => 0, "visibility" => nil }
        ],
        entries(<<~'RUBY')
          test("first
          second") do
          end
        RUBY
      )
    end

    test "parses RSpec suites and examples with nested suite depth" do
      assert_equal(
        [
          { "line" => 1, "name" => "User", "kind" => "suite", "depth" => 0, "visibility" => nil },
          { "line" => 2, "name" => "validation", "kind" => "suite", "depth" => 1, "visibility" => nil },
          { "line" => 3, "name" => "accepts a user", "kind" => "test", "depth" => 2, "visibility" => nil },
          { "line" => 5, "name" => "a feature", "kind" => "suite", "depth" => 1, "visibility" => nil },
          { "line" => 6, "name" => "a scenario", "kind" => "test", "depth" => 2, "visibility" => nil },
          { "line" => 8, "name" => "an example", "kind" => "test", "depth" => 1, "visibility" => nil }
        ],
        entries(<<~RUBY, path: "spec/models/user_spec.rb")
          RSpec.describe "User" do
            context "validation" do
              it "accepts a user" do; end
            end
            feature "a feature" do
              scenario "a scenario" do; end
            end
            example "an example" do; end
          end
        RUBY
      )
    end

    test "parses RSpec-qualified context and feature suites with nested depth" do
      assert_equal(
        [
          { "line" => 1, "name" => "state", "kind" => "suite", "depth" => 0, "visibility" => nil },
          { "line" => 2, "name" => "flow", "kind" => "suite", "depth" => 1, "visibility" => nil },
          { "line" => 3, "name" => "works", "kind" => "test", "depth" => 2, "visibility" => nil }
        ],
        entries(<<~RUBY, path: "spec/features/user_spec.rb")
          RSpec.context "state" do
            RSpec.feature "flow" do
              it "works" do; end
            end
          end
        RUBY
      )
    end

    test "parses describe specify and unqualified suite forms" do
      assert_equal(
        [
          { "line" => 1, "name" => "a model", "kind" => "suite", "depth" => 0, "visibility" => nil },
          { "line" => 2, "name" => "works", "kind" => "test", "depth" => 1, "visibility" => nil },
          { "line" => 4, "name" => "another model", "kind" => "suite", "depth" => 0, "visibility" => nil },
          { "line" => 5, "name" => "also works", "kind" => "test", "depth" => 1, "visibility" => nil }
        ],
        entries(<<~'RUBY', path: "spec/models/user_spec.rb")
          describe "a model" do
            specify "works" do; end
          end
          feature "another model" do
            example "also works" do; end
          end
        RUBY
      )
    end

    test "uses an unquoted Ruby constant as a static suite name" do
      assert_equal(
        [
          { "line" => 1, "name" => "User", "kind" => "suite", "depth" => 0, "visibility" => nil }
        ],
        entries(<<~RUBY, path: "spec/models/user_spec.rb")
          RSpec.describe User do
          end
        RUBY
      )
    end

    test "uses fallback names for dynamic interpolated and symbol descriptions" do
      assert_equal(
        [
          { "line" => 1, "name" => "test at line 1", "kind" => "test", "depth" => 0, "visibility" => nil },
          { "line" => 2, "name" => "suite at line 2", "kind" => "suite", "depth" => 0, "visibility" => nil },
          { "line" => 3, "name" => "suite at line 3", "kind" => "suite", "depth" => 1, "visibility" => nil }
        ],
        entries(<<~'RUBY', path: "spec/models/user_spec.rb")
          test description_for(:user) do; end
          describe "user #{role}" do
            context :validation do; end
          end
        RUBY
      )
    end

    test "keeps interpolation-looking text literal in single-quoted descriptions" do
      assert_equal(
        [
          { "line" => 1, "name" => 'literal #{name}', "kind" => "test", "depth" => 0, "visibility" => nil }
        ],
        entries(<<~'RUBY')
          test 'literal #{name}' do; end
        RUBY
      )
    end

    test "ignores declarations inside Ruby literals and comments" do
      assert_equal(
        [
          { "line" => 19, "name" => "real", "kind" => "method", "depth" => 0, "visibility" => nil }
        ],
        entries(<<~'RUBY')
          # def comment; end
          value = "def string; end"
          pattern = /def regex; end/
          percent = %q{def percent_literal; end}
          =begin
          def block_comment; end
          =end
          message = <<~TEXT
          def heredoc; end
          describe "fake" do
          TEXT
          test "not a declaration"
          context "not a suite"
          it "not a test"
          # a blank line follows

          class UserTest

            def real; end
          end
        RUBY
      )
    end

    test "does not emit test DSL calls outside test paths" do
      assert_equal(
        [],
        entries(<<~RUBY, path: "app/models/user.rb")
          test "not a Rails test" do; end
          context "not an RSpec suite" do; end
          it "not an RSpec example" do; end
        RUBY
      )
    end

    test "requires an actual block opener for test DSL declarations" do
      assert_equal(
        [],
        entries(<<~RUBY, path: "spec/models/user_spec.rb")
          test :do
          describe metadata: { do: true }
        RUBY
      )
    end

    test "does not mistake an argument hash for a trailing block brace" do
      assert_equal(
        [],
        entries(<<~RUBY, path: "spec/models/user_spec.rb")
          describe User, { do: true }
        RUBY
      )
    end

    test "distinguishes nested and splatted hashes from genuine trailing brace blocks" do
      assert_equal(
        [
          { "line" => 4, "name" => "suite at line 4", "kind" => "suite", "depth" => 0, "visibility" => nil },
          { "line" => 5, "name" => "test at line 5", "kind" => "test", "depth" => 0, "visibility" => nil }
        ],
        entries(<<~RUBY, path: "spec/models/user_spec.rb")
          describe metadata({foo: true})
          test options.merge({foo: true})
          describe User, **{foo: true}
          describe(metadata({foo: true})) { }
          test(options.merge({foo: true})) { }
        RUBY
      )
    end

    test "does not borrow a later declaration block or skip real entries" do
      assert_equal(
        [
          { "line" => 2, "name" => "helper", "kind" => "method", "depth" => 0, "visibility" => nil },
          { "line" => 3, "name" => "real", "kind" => "test", "depth" => 0, "visibility" => nil }
        ],
        entries(<<~RUBY)
          test "not runnable"
          def helper; end
          test "real" do; end
        RUBY
      )
    end

    test "does not leak rejected lookahead lexical state into later parsing" do
      assert_equal(
        [
          { "line" => 3, "name" => "helper", "kind" => "method", "depth" => 0, "visibility" => nil }
        ],
        entries(<<~RUBY)
          test "unfinished
          description"
          def helper; end
        RUBY
      )
    end

    test "ignores comments and heredoc contents while scanning multiline headers" do
      assert_equal(
        [
          { "line" => 6, "name" => "helper", "kind" => "method", "depth" => 0, "visibility" => nil },
          { "line" => 7, "name" => "test at line 7", "kind" => "test", "depth" => 0, "visibility" => nil }
        ],
        entries(<<~RUBY)
          test(
            <<~LABEL
            do
            LABEL
          )
          def helper; end
          test(
            # do is only a comment
            "real"
          ) do
          end
        RUBY
      )
    end

    test "skips malformed declarations and retains later definitions in source order" do
      assert_equal(
        [
          { "line" => 3, "name" => "first", "kind" => "method", "depth" => 0, "visibility" => nil },
          { "line" => 5, "name" => "second", "kind" => "method", "depth" => 0, "visibility" => nil }
        ],
        entries(<<~RUBY, path: "spec/models/user_spec.rb")
          class UserTest
            def (
            def first; end
            test( do
            def second; end
          end
        RUBY
      )
    end

    test "limits output to five thousand entries" do
      source = (1..5001).map { |number| "def method_#{number}; end\n" }.join
      result = parse(source)

      assert_equal 5000, result.fetch("entries").length
      assert_equal "method_1", result.fetch("entries").first.fetch("name")
      assert_equal "method_5000", result.fetch("entries").last.fetch("name")
      assert_equal true, result.fetch("truncated")
    end

    test "recognizes supported test paths" do
      assert_equal true, @context.eval("RubyOutline.isTestPath('test/models/user_test.rb')")
      assert_equal true, @context.eval("RubyOutline.isTestPath('spec/models/user_spec.rb')")
      assert_equal true, @context.eval("RubyOutline.isTestPath('lib/user_test.rb')")
      assert_equal true, @context.eval("RubyOutline.isTestPath('lib/user_spec.rb')")
      assert_equal false, @context.eval("RubyOutline.isTestPath('app/models/user.rb')")
    end
  end
end
