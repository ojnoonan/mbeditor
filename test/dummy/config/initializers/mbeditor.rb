# frozen_string_literal: true

require "fileutils"

# Ensure the sample workspace directory exists before anything else so that
# config.workspace_root passes the engine's directory-existence validation.
_sample_workspace_path = Rails.root.join("tmp", "sample_workspace")
FileUtils.mkdir_p(_sample_workspace_path)

Mbeditor.configure do |config|
  # Allow developers to provide a custom RuboCop command for the dummy app.
  custom_rubocop_command = ENV["MBEDITOR_RUBOCOP_COMMAND"].to_s.strip

  config.rubocop_command = custom_rubocop_command unless custom_rubocop_command.empty?

  # Fake Redmine integration for the dummy app — no real server required.
  config.redmine_enabled = true
  config.redmine_url     = "https://redmine.example.test"
  config.redmine_api_key = "dummy-api-key"

  # Point the editor at the sample workspace so the file tree shows sample
  # files (with git history, tests, and feature demos) rather than the bare
  # Rails dummy-app skeleton.  The directory is guaranteed to exist above.
  config.workspace_root = _sample_workspace_path.to_s

  # Test runner — uses Minitest.  The sample workspace test files require only
  # the standard library and minitest, so `bundle exec ruby -Itest` resolves
  # minitest via the gem project's own Gemfile (Bundler walks up from the
  # workspace directory until it finds the Gemfile at the repo root).
  config.test_framework = :minitest
  config.test_command   = "bundle exec ruby -Itest"
  config.test_timeout   = 30

  # No authentication required for the dummy development server.
end

# Override RedmineService#call in the dummy app to return fixture data so that
# the browser-based development UI shows a realistic Redmine card without
# needing a real Redmine server.
Rails.application.config.after_initialize do
  # ── Bootstrap sample workspace ──────────────────────────────────────────────
  # Create a small git repo under tmp/sample_workspace with a few commits that
  # reference Redmine ticket IDs.  This makes the Redmine card appear in the Git
  # panel when running the dummy development server without a real project.
  #
  # The repo is created once and left in place on subsequent boots.
  sample_workspace = Rails.root.join("tmp", "sample_workspace")

  unless sample_workspace.join(".git").exist?
    FileUtils.mkdir_p(sample_workspace)

    git_env = {
      "GIT_AUTHOR_NAME"     => "Dev User",
      "GIT_AUTHOR_EMAIL"    => "dev@example.test",
      "GIT_COMMITTER_NAME"  => "Dev User",
      "GIT_COMMITTER_EMAIL" => "dev@example.test"
    }

    ws = sample_workspace.to_s

    system(git_env, "git", "init", ws, out: File::NULL, err: File::NULL)
    system(git_env, "git", "-C", ws, "config", "user.email", "dev@example.test",
           out: File::NULL, err: File::NULL)
    system(git_env, "git", "-C", ws, "config", "user.name", "Dev User",
           out: File::NULL, err: File::NULL)

    # Seed a few source files so the file tree is not empty
    FileUtils.mkdir_p(sample_workspace.join("app", "models"))
    FileUtils.mkdir_p(sample_workspace.join("app", "controllers"))
    FileUtils.mkdir_p(sample_workspace.join("app", "assets", "javascripts"))
    FileUtils.mkdir_p(sample_workspace.join("tmp"))

    File.write(sample_workspace.join("README.md"),
               "# Sample Project\n\nThis is the dummy workspace for mbeditor development.\n")
    File.write(sample_workspace.join("app", "models", "user.rb"),
               "class User\n  attr_accessor :name, :email\nend\n")
    File.write(sample_workspace.join("app", "controllers", "application_controller.rb"),
               "class ApplicationController\n  def index\n    render plain: 'Hello'\n  end\nend\n")
    File.write(sample_workspace.join("app", "assets", "javascripts", "users.js.erb"), <<~JS)
      // Generated at: <%= Time.current.iso8601 %>
      // Asset pipeline ERB example — values injected at precompile time

      var APP_CONFIG = {
        apiBase:     "<%= Rails.application.config.api_base_url rescue '/api/v1' %>",
        environment: "<%= Rails.env %>",
        csrfParam:   "<%= Rails.application.config.action_controller.request_forgery_protection_token || 'authenticity_token' %>",
        maxUploadMb: <%= defined?(MAX_UPLOAD_MB) ? MAX_UPLOAD_MB : 10 %>
      };

      // Route helpers baked in at compile time
      var ROUTES = {
        users:    "<%= users_path rescue '/users' %>",
        newUser:  "<%= new_user_path rescue '/users/new' %>"
      };

      (function() {
        "use strict";

        function initUserList() {
          var rows = document.querySelectorAll("tr[data-user-id]");
          rows.forEach(function(row) {
            row.addEventListener("click", function() {
              window.location = APP_CONFIG.apiBase + "/users/" + row.dataset.userId;
            });
          });
        }

        document.addEventListener("DOMContentLoaded", initUserList);
      })();
    JS

    system(git_env, "git", "-C", ws, "add", ".", out: File::NULL, err: File::NULL)
    system(git_env, "git", "-C", ws, "commit", "-m", "Initial project setup",
           out: File::NULL, err: File::NULL)

    # Commit referencing ticket #123 (pagination bug)
    File.write(sample_workspace.join("app", "models", "pagination.rb"),
               "module Pagination\n  def self.paginate(items, page, per_page)\n    items.drop((page - 1) * per_page).first(per_page)\n  end\nend\n")
    system(git_env, "git", "-C", ws, "add", ".", out: File::NULL, err: File::NULL)
    system(git_env, "git", "-C", ws, "commit", "-m", "Fix duplicate rows on page 3+ - refs #123",
           out: File::NULL, err: File::NULL)

    # Commit referencing ticket #42 (dark-mode) — most recent, will be matched first
    File.write(sample_workspace.join("app", "controllers", "theme_controller.rb"),
               "class ThemeController\n  THEMES = %i[light dark].freeze\nend\n")
    system(git_env, "git", "-C", ws, "add", ".", out: File::NULL, err: File::NULL)
    system(git_env, "git", "-C", ws, "commit", "-m", "Implement dark-mode toggle for navigation - refs #42",
           out: File::NULL, err: File::NULL)
  end

  # ── Ensure .rubocop.yml exists ──────────────────────────────────────────────
  # Written on every boot so the Settings panel can show the config link.
  File.write(sample_workspace.join(".rubocop.yml"), <<~YAML) unless sample_workspace.join(".rubocop.yml").exist?
    AllCops:
      NewCops: enable
      TargetRubyVersion: 3.2

    Style/StringLiterals:
      Enabled: true
      EnforcedStyle: double_quotes

    Style/FrozenStringLiteralComment:
      Enabled: false

    Metrics/MethodLength:
      Max: 20

    Layout/LineLength:
      Max: 120
  YAML

  # ── Ensure test files always exist ──────────────────────────────────────────
  # Written on every boot so existing workspaces get the test suite even when
  # the git repo was already initialised.  Tests deliberately include a mix of
  # passing and failing cases so the Test button shows meaningful results.
  FileUtils.mkdir_p(sample_workspace.join("test", "models"))
  FileUtils.mkdir_p(sample_workspace.join("test", "controllers"))

  File.write(sample_workspace.join("test", "models", "user_test.rb"), <<~RUBY)
    require "minitest/autorun"
    require_relative "../../app/models/user"

    class UserTest < Minitest::Test
      def test_has_name_attribute
        user = User.new
        user.name = "Alice"
        assert_equal "Alice", user.name
      end

      def test_has_email_attribute
        user = User.new
        user.email = "alice@example.com"
        assert_equal "alice@example.com", user.email
      end

      def test_name_starts_nil
        assert_nil User.new.name
      end

      # Intentional failure — email validation is not implemented yet
      def test_validates_email_format
        user = User.new
        user.email = "not-an-email"
        assert user.email.include?("@"), "Expected email to contain @, got: \#{user.email}"
      end

      # Intentional failure — name blank guard is not implemented yet
      def test_name_cannot_be_blank
        user = User.new
        user.name = ""
        refute user.name.empty?, "name should not be blank"
      end
    end
  RUBY

  File.write(sample_workspace.join("test", "models", "pagination_test.rb"), <<~RUBY)
    require "minitest/autorun"
    require_relative "../../app/models/pagination"

    class PaginationTest < Minitest::Test
      ITEMS = (1..20).to_a

      def test_first_page
        assert_equal [1, 2, 3, 4, 5], Pagination.paginate(ITEMS, 1, 5)
      end

      def test_second_page
        assert_equal [6, 7, 8, 9, 10], Pagination.paginate(ITEMS, 2, 5)
      end

      def test_last_page
        assert_equal [16, 17, 18, 19, 20], Pagination.paginate(ITEMS, 4, 5)
      end

      def test_page_beyond_end_is_empty
        assert_empty Pagination.paginate(ITEMS, 10, 5)
      end

      # Intentional failure — Pagination doesn't validate per_page > 0
      def test_raises_on_zero_per_page
        assert_raises(ArgumentError) { Pagination.paginate(ITEMS, 1, 0) }
      end

      # Intentional failure — Pagination doesn't validate negative page numbers
      def test_raises_on_negative_page
        assert_raises(ArgumentError) { Pagination.paginate(ITEMS, -1, 5) }
      end
    end
  RUBY

  File.write(sample_workspace.join("test", "controllers", "theme_controller_test.rb"), <<~RUBY)
    require "minitest/autorun"
    require_relative "../../app/controllers/theme_controller"

    class ThemeControllerTest < Minitest::Test
      def test_themes_includes_light
        assert_includes ThemeController::THEMES, :light
      end

      def test_themes_includes_dark
        assert_includes ThemeController::THEMES, :dark
      end

      def test_themes_is_frozen
        assert ThemeController::THEMES.frozen?
      end

      # Intentional failure — system theme is not implemented yet
      def test_themes_includes_system
        assert_includes ThemeController::THEMES, :system,
          "Expected THEMES to include :system for OS-level dark mode sync"
      end
    end
  RUBY

  # ── Feature demo files ──────────────────────────────────────────────────────
  # Written on every boot.  Each file demonstrates one of the new editor
  # features so developers can test them immediately after starting the server.

  File.write(sample_workspace.join("FEATURES.md"), <<~MD)
    # Mbeditor — New Features

    ## Zen / Focus Mode
    **Shortcut:** `Cmd+Shift+Z` (Mac) / `Ctrl+Shift+Z` (Linux/Windows)

    Hides the file-tree sidebar and the Git panel so you can concentrate on
    the file you are editing.  Monaco automatically fills the reclaimed space.
    A small **ZEN** badge appears in the status bar — click it or press the
    shortcut again to exit.

    ## Bulk Find & Replace
    1. Open the **SEARCH** sidebar tab.
    2. Click the **⇄** (Toggle Replace) button to show the replace input.
    3. Type your search term in the top input and the replacement in the
       second input.
    4. Click **Replace All** and confirm.  The editor updates every open file
       that was affected in real time.

    **Try it:** search for `TODO:` and replace with `DONE:` across the
    `app/services/` directory demo files below.

    ## Prefetch on Hover
    Hover over any file in the tree for more than 200 ms.  The editor quietly
    fetches the file content in the background so that clicking it opens
    instantly with zero network delay.

    ## Client-Side Search Cache
    The last 20 search queries are cached for 30 seconds.  Re-running an
    identical query (same text, regex flag, case flag, word flag) returns
    results immediately without hitting the server.

    ## Undo-Aware Dirty Tracking
    Make a few edits, then undo them all (`Cmd+Z` / `Ctrl+Z`).  Once you are
    back to the saved state the dirty dot (●) in the tab header disappears
    automatically — no save required.

    ## LRU Model Cap
    At most **15 Monaco models** are kept in memory at once.  When you open a
    16th file, the least-recently-used model that is not currently visible is
    silently disposed.  You can verify in the browser console:

    ```js
    Object.keys(window.__mbeditorModels).length  // ≤ 15
    ```

    ## Fast Startup
    The file tree and shell UI now appear before Monaco has finished
    downloading.  The editor pane shows a "Loading editor…" skeleton and
    activates as soon as Monaco is ready, with no blank-page wait.
  MD

  FileUtils.mkdir_p(sample_workspace.join("app", "services"))

  File.write(sample_workspace.join("app", "services", "notification_service.rb"), <<~RUBY)
    # Demo file for bulk find-and-replace.
    # Try replacing every TODO: with DONE: using the Search → Replace panel.

    class NotificationService
      # TODO: add retry logic for failed deliveries
      def deliver(user, message)
        # TODO: validate message length before sending
        Rails.logger.info("Delivering to \#{user.email}: \#{message}")
        UserMailer.notification(user, message).deliver_later
      end

      # TODO: implement batch delivery to reduce mailer overhead
      def deliver_batch(users, message)
        users.each { |u| deliver(u, message) }
      end

      # TODO: persist delivery receipts to the database
      def receipt_for(user, message_id)
        { user_id: user.id, message_id: message_id, delivered_at: Time.current }
      end
    end
  RUBY

  File.write(sample_workspace.join("app", "services", "analytics_service.rb"), <<~RUBY)
    # Demo file for bulk find-and-replace.
    # TODO: items here should all be replaced together with the ones above.

    class AnalyticsService
      # TODO: connect to a real analytics backend
      def track(event, properties = {})
        Rails.logger.info("[Analytics] \#{event}: \#{properties.inspect}")
      end

      # TODO: add user-level opt-out check
      def page_view(path, user: nil)
        track("page_view", path: path, user_id: user&.id)
      end

      # TODO: buffer events and flush in batches
      def flush
        # no-op for now
      end
    end
  RUBY

  File.write(sample_workspace.join("app", "models", "product.rb"), <<~RUBY)
    # Demo file for undo-aware dirty tracking.
    # Open this file, make some edits, then undo them all (Cmd+Z / Ctrl+Z).
    # The dirty dot (●) in the tab should disappear once you are back to the
    # saved state — even before you press Save.

    class Product
      attr_accessor :name, :price, :stock

      def initialize(name:, price:, stock: 0)
        @name  = name
        @price = price
        @stock = stock
      end

      def in_stock?
        @stock > 0
      end

      def discount(percent)
        @price * (1 - percent / 100.0)
      end
    end
  RUBY

  File.write(sample_workspace.join("app", "models", "order.rb"), <<~RUBY)
    # Rich-content demo file for the search sidebar.
    # Search for "Order", "total", or "status" to see the full-text search
    # and client-side cache in action — run the same query twice to verify
    # the second result is instant (cache hit, no network round-trip).

    class Order
      STATUSES = %w[pending processing shipped delivered cancelled].freeze

      attr_reader :id, :line_items, :status

      def initialize(id)
        @id         = id
        @line_items = []
        @status     = "pending"
      end

      def add_item(product, quantity: 1)
        @line_items << { product: product, quantity: quantity }
      end

      def total
        @line_items.sum { |li| li[:product].price * li[:quantity] }
      end

      def advance_status!
        idx = STATUSES.index(@status) || 0
        @status = STATUSES[idx + 1] || @status
      end

      def cancelled?
        @status == "cancelled"
      end
    end
  RUBY

  # ── JS/JSX test files ───────────────────────────────────────────────────────
  # Written on every boot so they survive a tmp/ wipe.
  FileUtils.mkdir_p(sample_workspace.join("app", "assets", "javascripts"))

  # globals_test.js — verifies that host-app window globals (RequestMethods,
  # ReactWindow, ModalStore) are auto-detected and not flagged as undefined.
  # Also checks that JSDoc optional params don't produce false squiggles.
  File.write(sample_workspace.join("app", "assets", "javascripts", "globals_test.js"), <<~JS)
    // Syntax-highlighting smoke test: globals and optional parameters.
    //
    // None of the globals below should show "Cannot find name" errors —
    // they are auto-detected from window at editor load time.
    // Optional @param calls with the argument omitted should be error-free.

    // --- Globals injected by the host Rails app ---
    var methods = RequestMethods.all();
    var win     = ReactWindow.current();
    var store   = ModalStore.getInstance();

    // --- Optional parameter smoke tests ---

    /**
     * @param {string} message
     * @param {string} [title]
     */
    function showAlert(message, title) {
      return (title || "Alert") + ": " + message;
    }

    /**
     * @param {Object} options
     * @param {string} options.url
     * @param {string} [options.method]
     * @param {Object} [options.body]
     */
    function makeRequest(options) {
      var method = options.method || "GET";
      return fetch(options.url, { method: method, body: options.body });
    }

    showAlert("Hello");
    showAlert("Hello", "World");
    makeRequest({ url: "/api/data" });
    makeRequest({ url: "/api/data", method: "POST", body: { key: "value" } });
  JS

  # globals_test.jsx — same checks in JSX: globals in component bodies,
  # optional props without "missing argument" errors.
  File.write(sample_workspace.join("app", "assets", "javascripts", "globals_test.jsx"), <<~JSX)
    // Syntax-highlighting smoke test: JSX globals and optional props.
    //
    // ReactWindow, RequestMethods, and ModalStore should not show errors.
    // Components with optional props should not produce missing-argument squiggles.

    // --- Globals injected by the host Rails app ---
    var config    = ReactWindow.getConfig();
    var endpoints = RequestMethods.endpoints();
    var openModal = ModalStore.open;

    // --- React components with optional props ---

    /**
     * @param {{ title: string, subtitle?: string, onClose?: Function }} props
     */
    function Modal(props) {
      return (
        <div className="modal">
          <h2>{props.title}</h2>
          {props.subtitle && <p>{props.subtitle}</p>}
          {props.onClose && <button onClick={props.onClose}>Close</button>}
        </div>
      );
    }

    /**
     * @param {{ items: Array, loading?: boolean }} props
     */
    function ItemList(props) {
      if (props.loading) {
        return <div>Loading...</div>;
      }
      return (
        <ul>
          {props.items.map(function(item, idx) {
            return <li key={idx}>{item.name}</li>;
          })}
        </ul>
      );
    }

    // All four calls below should be error-free — optional props omitted intentionally
    var a = <Modal title="Confirm" />;
    var b = <Modal title="Info" subtitle="More detail" />;
    var c = <ItemList items={[{ name: "First" }]} />;
    var d = <ItemList items={[]} loading={true} />;
  JSX

  File.write(sample_workspace.join("app", "assets", "javascripts", "missing_closing_tag.jsx"), <<~JSX)
    // Error: JSX element is never closed
    function Greeting({ name }) {
      return (
        <div className="greeting">
          <h1>Hello, {name}!</h1>
          <p>Welcome back.
        </div>
      );
    }
  JSX

  File.write(sample_workspace.join("app", "assets", "javascripts", "unexpected_token.jsx"), <<~JSX)
    // Error: unexpected token — stray equals sign in JSX attribute
    function Button({ label }) {
      return (
        <button class="btn" onClick={= handleClick}>
          {label}
        </button>
      );
    }
  JSX

  File.write(sample_workspace.join("app", "assets", "javascripts", "invalid_expression.jsx"), <<~JSX)
    // Error: invalid JS expression inside JSX braces
    function Counter({ count }) {
      return (
        <div>
          <span>Count: {count +}</span>
          <button>Increment</button>
        </div>
      );
    }
  JSX

  # ── Fake RedmineService ──────────────────────────────────────────────────────
  Mbeditor::RedmineService.prepend(Module.new do
    FAKE_ISSUES = {
      "42"  => {
        "id"          => 42,
        "title"       => "Implement dark-mode toggle for main navigation",
        "description" => "Users have requested a dark-mode option.\n\nAcceptance criteria:\n- Toggle in the top-right corner\n- Preference persisted to localStorage\n- All existing components must respect the theme variable",
        "status"      => "In Progress",
        "author"      => "Alice Nguyen",
        "notes"       => [
          "Agreed to use CSS custom properties for theming.",
          "Prototype approved in design review on 2026-03-10."
        ]
      },
      "123" => {
        "id"          => 123,
        "title"       => "Fix pagination bug on Projects index page",
        "description" => "When navigating to page 3+ the results are duplicated.\n\nSteps to reproduce:\n1. Go to /projects\n2. Click 'Next' twice\n3. Observe duplicate rows in the table",
        "status"      => "New",
        "author"      => "Bob Smith",
        "notes"       => []
      },
      "999" => {
        "id"          => 999,
        "title"       => "Upgrade Rails to 8.0",
        "description" => "Track the upgrade path from Rails 7.1 → 8.0. Follow the official upgrade guide and update all deprecated APIs.",
        "status"      => "Closed",
        "author"      => "Carol Jones",
        "notes"       => [
          "All deprecation warnings resolved.",
          "Deployed to staging on 2026-02-28 — no issues found."
        ]
      }
    }.freeze

    def call
      # Still run the normal config validation (raises RedmineDisabledError /
      # RedmineConfigError when url or api_key are blank) so tests that exercise
      # those error paths continue to work.  Only the network call is stubbed.
      raise Mbeditor::RedmineDisabledError unless Mbeditor.configuration.redmine_enabled

      config = Mbeditor.configuration
      raise Mbeditor::RedmineConfigError, "redmine_url is not configured"     if config.redmine_url.blank?
      raise Mbeditor::RedmineConfigError, "redmine_api_key is not configured" if config.redmine_api_key.blank?

      # Return a matching fixture if we have one, otherwise generate a
      # plausible-looking generic issue so any #<number> in a commit works.
      FAKE_ISSUES.fetch(issue_id.to_s) do
        {
          "id"          => issue_id.to_i,
          "title"       => "Issue ##{issue_id} (dummy)",
          "description" => "This is a placeholder issue generated by the dummy Redmine integration.\nEdit test/dummy/config/initializers/mbeditor.rb to add real fixtures.",
          "status"      => "New",
          "author"      => "Dummy User",
          "notes"       => []
        }
      end
    end
  end)

  # ── Belt-and-suspenders workspace_root override ─────────────────────────────
  # Re-apply here so it wins regardless of initializer load order or any Spring
  # preloader that may have cached an earlier empty configuration.
  Mbeditor.configure { |c| c.workspace_root = sample_workspace.to_s }

  # Remove any stale Rails-root workspace state so the browser doesn't restore
  # cross-workspace tabs on the first load after the workspace moved.
  stale_state = Rails.root.join("tmp", "mbeditor_workspace.json")
  FileUtils.rm_f(stale_state)
end
