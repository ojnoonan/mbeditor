# frozen_string_literal: true

require "test_helper"

module Mbeditor
  # Reproduces the exact failure resilient routing exists to survive: a broken
  # host config/routes.rb that, on reload, wipes Mbeditor::Engine.routes via the
  # RoutesReloader's clear!. Even then, mbeditor must stay reachable at its mount
  # prefix because the ResilientRouter middleware dispatches to the private,
  # isolated route set the reloader can never touch.
  #
  # These tests mutate the dummy app's real config/routes.rb, so each one MUST
  # restore it and reload — a broken file left behind would poison every later
  # test in the suite.
  class ResilientRoutingTest < ActionDispatch::IntegrationTest
    ROUTES_PATH = Rails.root.join("config", "routes.rb")

    BROKEN_ROUTES = <<~RUBY
      Rails.application.routes.draw do
        get "intentionally_broken", to: "nope#nope"
      # missing `end` below — a SyntaxError, which is a ScriptError, not a StandardError
    RUBY

    # Distinctive sentinel raised from inside an mbeditor action, so the error
    # page can be checked to confirm the failure is attributed to mbeditor and
    # not to anything else (e.g. the host's broken-routes error).
    SELF_ERROR_MESSAGE = "deliberate mbeditor-internal failure"

    setup do
      @original_routes = File.read(ROUTES_PATH)
      Mbeditor.configure { |c| c.allowed_environments = %i[test development] }
    end

    teardown do
      Mbeditor.configure { |c| c.allowed_environments = [:development] }
    end

    # Break the host routes, force a reload (which clears every registered route
    # set), then restore and recover regardless of what the block does.
    def with_broken_host_routes
      File.write(ROUTES_PATH, BROKEN_ROUTES)
      begin
        Rails.application.reload_routes!
      rescue ScriptError
        # Expected: the SyntaxError surfaces here. The damage (cleared route
        # sets) is already done, which is exactly the state we want to test.
      end
      yield
    ensure
      File.write(ROUTES_PATH, @original_routes)
      Rails.application.reload_routes!
    end

    test "mbeditor stays reachable at its mount prefix when the host routes are broken" do
      with_broken_host_routes do
        assert_empty Mbeditor::Engine.routes.routes.to_a,
                     "precondition: the broken reload should have wiped the engine route set"

        get "/mbeditor/ping"

        assert_response :ok
        assert_equal({ "ok" => true }, JSON.parse(@response.body))
      end
    end

    test "a healthy request reaches the host mount so host main_app URLs stay unprefixed" do
      # Regression: when resilient routing intercepted *every* /mbeditor request
      # (not only broken-routes ones), the host's authenticate_with redirect ran
      # inside the private route set with SCRIPT_NAME="/mbeditor", so main_app
      # url helpers wrongly prepended the mount prefix — turning a host login
      # redirect of "/" into "/mbeditor/". Healthy requests must pass through to
      # the normal engine mount where main_app generates host-rooted paths.
      Mbeditor.configure { |c| c.authenticate_with = proc { redirect_to main_app.root_path } }

      get "/mbeditor/"

      assert_redirected_to "/",
        "the host auth redirect must target the host path, not the /mbeditor-prefixed engine path"
    ensure
      Mbeditor.configure { |c| c.authenticate_with = nil }
    end

    test "session-based authenticate_with still authorizes resilient-routed requests" do
      Mbeditor.configure do |c|
        c.authenticate_with = proc do
          render(plain: "Unauthorized", status: :unauthorized) unless session[:authenticated]
        end
      end

      post "/login" # healthy host route establishes the session
      get "/mbeditor/ping"
      assert_response :ok, "sanity: session-based auth works while routes are healthy"

      with_broken_host_routes do
        assert_empty Mbeditor::Engine.routes.routes.to_a

        get "/mbeditor/ping"

        assert_response :ok, "the resilient path must read the session cookie, not bypass it"
      end
    ensure
      Mbeditor.configure { |c| c.authenticate_with = nil }
    end

    test "verify_mbeditor_client still guards writes on resilient-routed requests" do
      with_broken_host_routes do
        assert_empty Mbeditor::Engine.routes.routes.to_a

        # No X-Mbeditor-Client header — the before_action must reject the write.
        post "/mbeditor/file"

        assert_response :forbidden
      end
    end

    test "the editor shell renders at the mount prefix when the host routes are broken" do
      with_broken_host_routes do
        assert_empty Mbeditor::Engine.routes.routes.to_a,
                     "precondition: the broken reload should have wiped the engine route set"

        get "/mbeditor"

        assert_response :ok
        assert_includes @response.body, %(href="/mbeditor/manifest.webmanifest"),
                        "the PWA manifest link must resolve from MountPath, not the wiped route helper"
      end
    end

    test "the PWA manifest resolves its URLs at the mount prefix when the host routes are broken" do
      with_broken_host_routes do
        assert_empty Mbeditor::Engine.routes.routes.to_a

        get "/mbeditor/manifest.webmanifest"

        assert_response :ok
        manifest = JSON.parse(@response.body)
        assert_equal "/mbeditor/", manifest["start_url"]
        assert_equal "/mbeditor/", manifest["scope"]
        assert_equal "/mbeditor/mbeditor-icon.svg", manifest.dig("icons", 0, "src")
      end
    end

    test "render-path URLs follow a custom mount_path under broken routes" do
      Mbeditor.configure { |c| c.mount_path = "/admin/editor" }

      with_broken_host_routes do
        assert_empty Mbeditor::Engine.routes.routes.to_a

        get "/admin/editor"
        assert_response :ok
        assert_includes @response.body, %(href="/admin/editor/manifest.webmanifest")

        get "/admin/editor/manifest.webmanifest"
        assert_response :ok
        assert_equal "/admin/editor/", JSON.parse(@response.body)["start_url"]
      end
    ensure
      Mbeditor.configure { |c| c.mount_path = nil }
    end

    # Reproduce a healthy route load the way Rails does on reload: redraw the
    # table, then fire the :after_routes_loaded hook (finisher.rb's reloader
    # to_run block does exactly this pair). Leaves the table healthy, so it
    # cannot poison later tests.
    def with_healthy_route_load
      Rails.application.routes_reloader.reload!
      ActiveSupport.run_load_hooks(:after_routes_loaded, Rails.application)
    end

    test "a healthy route load auto-detects and caches the mount prefix" do
      original = Mbeditor::MountPath.cached
      Mbeditor::MountPath.cached = nil

      with_healthy_route_load

      assert_equal "/mbeditor", Mbeditor::MountPath.cached,
                   "the after_routes_loaded hook must populate the cache from the healthy table " \
                   "(a nil cache would mean the hook is not wired and resolve only falls back to the default)"
    ensure
      Mbeditor::MountPath.cached = original
    end

    test "the auto-detected prefix survives a route-table clear" do
      with_healthy_route_load # caches the real mount prefix from the live table
      assert_equal "/mbeditor", Mbeditor::MountPath.cached, "precondition: healthy load cached the prefix"

      with_broken_host_routes do
        assert_empty Mbeditor::Engine.routes.routes.to_a,
                     "precondition: the broken reload should have wiped the engine route set"

        assert_equal "/mbeditor", Mbeditor::MountPath.cached,
                     "the broken reload must not clobber the prefix cached from the earlier healthy load"
        assert_equal "/mbeditor", Mbeditor::MountPath.resolve,
                     "resolve must keep returning the cached prefix while the table is wiped"
      end
    end

    # Make an mbeditor request deliberately fail from *inside* its own request
    # handling by stubbing a service one of its actions calls. editors#files
    # renders FileTreeService.build directly and does not rescue, so the raised
    # error bubbles out of the controller and up the middleware stack.
    #
    # Restores via alias on the captured singleton class rather than rebinding a
    # captured Method object. A healthy mbeditor request now flows through the
    # host stack's Reloader (no longer bypassed by the resilient router), so the
    # inner `get` can reload FileTreeService when an earlier broken-routes test
    # left the code reloader dirty. The request itself still hits the stub and
    # returns 500; only a Method#rebind in `ensure` would fail with "can't bind
    # singleton method to a different class". alias_method stays within the
    # original singleton class, so the restore is reload-safe.
    def with_raising_mbeditor_action
      # Flush any pending code reload first, but only when the host routes are
      # healthy. An earlier broken-routes test can leave the reloader dirty, and
      # a healthy mbeditor request now traverses the Reloader — an unflushed
      # reload would fire mid-request, swap out the stubbed FileTreeService, and
      # let the real #build run (200 instead of the expected 500). Reloading up
      # front resolves the constant to its final class so the stub sticks for the
      # request. Skip it under broken routes: that path is served by the private
      # set (the Reloader is bypassed, so the stub already sticks) and reload!
      # would itself raise on the syntactically broken routes.rb.
      Rails.application.reloader.reload! if Mbeditor::Engine.routes.routes.any?
      meta = Mbeditor::FileTreeService.singleton_class
      meta.send(:alias_method, :__mbeditor_orig_build, :build)
      meta.send(:define_method, :build) { |*| raise SELF_ERROR_MESSAGE }
      yield
    ensure
      meta.send(:alias_method, :build, :__mbeditor_orig_build)
      meta.send(:remove_method, :__mbeditor_orig_build)
    end

    test "an exception inside mbeditor request handling surfaces as Rails' standard error response" do
      with_raising_mbeditor_action do
        get "/mbeditor/files"
      end

      assert_response :internal_server_error,
                      "mbeditor's own failure must surface as a real 500, not a silent or success response"
      assert_includes @response.body, SELF_ERROR_MESSAGE,
                      "the error page must attribute the failure to mbeditor's own exception, proving the " \
                      "ResilientRouter sits below DebugExceptions so Rails' normal error handling renders it"
    end

    test "a raising mbeditor request stays attributable to mbeditor when the host routes are broken" do
      with_broken_host_routes do
        assert_empty Mbeditor::Engine.routes.routes.to_a,
                     "precondition: the broken reload should have wiped the engine route set"

        with_raising_mbeditor_action do
          get "/mbeditor/files"
        end

        assert_response :internal_server_error,
                        "the mbeditor-internal failure must be a real error response, distinct from the " \
                        "resilient-routing success the other broken-routes tests assert"
        assert_includes @response.body, SELF_ERROR_MESSAGE,
                        "the failure must be attributed to mbeditor's own exception, not masquerade as " \
                        "the host's broken-routes error"
        refute_includes @response.body, "intentionally_broken",
                        "the error must come from mbeditor, not from the broken host routes.rb"
      end
    end

    test "the middleware sits above the Reloader but below the exception and executor middleware" do
      names = Rails.application.middleware.map(&:name)
      router = names.index("Mbeditor::Rack::ResilientRouter")

      refute_nil router, "ResilientRouter must be inserted into the middleware stack"
      assert_operator router, :<, names.index("ActionDispatch::Reloader"),
                      "must sit above the Reloader so mbeditor is intercepted before any route reload can raise"
      assert_operator router, :>, names.index("ActionDispatch::DebugExceptions"),
                      "must sit below DebugExceptions so mbeditor's own errors still get Rails error pages"
      assert_operator router, :>, names.index("ActionDispatch::Executor"),
                      "must sit below the Executor so dispatch runs inside app.executor's connection management"
    end
  end
end
