# frozen_string_literal: true

require "test_helper"

begin
  require "mini_racer"
rescue LoadError
  # This parser suite skips in minimal compatibility bundles.
end

module Mbeditor
  # Exercises classifyLogLine from LogPanel.js against real Rails log output.
  class LogLineClassifierTest < ActiveSupport::TestCase
    def setup
      skip "MiniRacer is not installed in this compatibility bundle" unless defined?(::MiniRacer)

      @context = MiniRacer::Context.new
      @context.eval("var window = this; var React = { createElement: function () {} };")
      @context.eval(File.read(Mbeditor::Engine.root.join("app/assets/javascripts/mbeditor/components/LogPanel.js")))
    end

    def classify(line)
      @context.eval("LogPanel.classifyLine(#{line.to_json})")
    end

    test "request lifecycle lines are distinguished" do
      assert_equal "request", classify('Started GET "/mbeditor" for ::1 at 2026-07-27 12:09:23 +1000')
      assert_equal "controller", classify("Processing by Mbeditor::EditorsController#index as HTML")
      assert_equal "muted", classify("Redirected to http://localhost:3789/mbeditor")
      assert_equal "render", classify("  Rendering layout layouts/mbeditor/application.html.erb")
      assert_equal "render", classify("  Rendered index.html.erb (Duration: 0.1ms | GC: 0.0ms)")
    end

    test "a Completed line takes its colour from the status code" do
      assert_equal "success", classify("Completed 200 OK in 22ms (Views: 21.9ms | GC: 8.3ms)")
      assert_equal "success", classify("Completed 204 No Content in 3ms")
      assert_equal "muted",   classify("Completed 301 Moved Permanently in 0ms")
      assert_equal "error",   classify("Completed 404 Not Found in 5ms")
      assert_equal "error",   classify("Completed 500 Internal Server Error in 120ms")
    end

    test "queries are recognised across their common shapes" do
      assert_equal "sql", classify(%(  User Load (0.3ms)  SELECT "users".* FROM "users"))
      assert_equal "sql", classify(%(  CACHE User Load (0.0ms)  SELECT "users".* FROM "users"))
      assert_equal "sql", classify("  TRANSACTION (0.1ms)  BEGIN")
      assert_equal "sql", classify(%(  SQL (1.2ms)  INSERT INTO "articles" ("title") VALUES ($1)))
    end

    test "failures and warnings are separated" do
      assert_equal "error", classify("FATAL -- : boom")
      assert_equal "error", classify("ActiveRecord::RecordNotFound (Couldn't find User with 'id'=9):")
      assert_equal "warn",  classify("DEPRECATION WARNING: config.x is deprecated")
      assert_equal "trace", classify("app/controllers/articles_controller.rb:12:in `show'")
    end

    test "a status code inside a Completed line wins over the generic error sweep" do
      # Without ordering, "Completed 200 ... Error" style noise could flip green
      # rows to red; the Completed rules run first for exactly this reason.
      assert_equal "success", classify("Completed 200 OK in 4ms (ErrorReporting: 0.1ms)")
    end

    test "mbeditor's own lines are marked" do
      assert_equal "mbeditor", classify("[mbeditor] watching /app for external changes")
    end

    test "ordinary output is left uncoloured" do
      assert_nil classify("just some app output")
      assert_nil classify("")
      assert_nil @context.eval("LogPanel.classifyLine(null)")
    end
  end
end
