# frozen_string_literal: true

require "test_helper"

module Mbeditor
  class RubyMethodRangesServiceTest < ActiveSupport::TestCase
    def ranges(src)
      RubyMethodRangesService.call(src)
    end

    def by_name(result)
      result[:methods].index_by { |m| m[:name] }
    end

    test "nested modules, self methods, endless defs, docs and heredocs" do
      src = <<~RUBY
        module Admin
          class OrdersController < Base
            # lists orders
            # newest first
            def index
              x = <<~E
                def fake
              E
              x.each do |y|
                y
              end
            end

            def self.build = new
            def one = 1
            def z; 2; end

            class << self
              def sing; end
            end
          end
        end
      RUBY
      r = by_name(ranges(src))
      assert_equal %w[index build one z sing], r.keys
      assert_equal({ start_line: 5, doc_start_line: 3, end_line: 12 }, r["index"].slice(:start_line, :doc_start_line, :end_line))
      assert_equal "Admin::OrdersController", r["index"][:owner]
      assert r["build"][:singleton]
      assert_equal [14, 14], r["build"].values_at(:start_line, :end_line)
      assert_equal [15, 15], r["one"].values_at(:start_line, :end_line)
      assert_equal [16, 16], r["z"].values_at(:start_line, :end_line)
      assert r["sing"][:singleton]
      refute r["index"][:singleton]
    end

    test "owners carry kind and range" do
      owners = ranges("module A\n  class B\n    def x; end\n  end\nend\n")[:owners]
      assert_equal [%w[module A 1 5], %w[class B 2 4]], owners.map { |o| [o[:kind], o[:name], o[:start_line].to_s, o[:end_line].to_s] }
    end

    test "syntax error returns error instead of raising" do
      assert_equal "Syntax error", ranges("def x\n  if\n")[:error]
    end

    test "oversized source is refused" do
      assert ranges("a" * (RubyMethodRangesService::MAX_BYTES + 1))[:error]
    end
  end
end
