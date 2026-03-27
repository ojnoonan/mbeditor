# frozen_string_literal: true

Mbeditor.configure do |config|
  # Allow developers to provide a custom RuboCop command for the dummy app.
  custom_rubocop_command = ENV["MBEDITOR_RUBOCOP_COMMAND"].to_s.strip

  config.rubocop_command = custom_rubocop_command unless custom_rubocop_command.empty?

  # Fake Redmine integration for the dummy app — no real server required.
  config.redmine_enabled = true
  config.redmine_url     = "https://redmine.example.test"
  config.redmine_api_key = "dummy-api-key"

  # Point the editor at a local sample workspace so branch commits contain
  # #ticket_id references that will be picked up by the Redmine panel.
  config.workspace_root = Rails.root.join("tmp", "sample_workspace").to_s

  # Test runner — uses Minitest.  The sample workspace test files require only
  # the standard library and minitest, so `bundle exec ruby -Itest` resolves
  # minitest via the gem project's own Gemfile (Bundler walks up from the
  # workspace directory until it finds the Gemfile at the repo root).
  config.test_framework = :minitest
  config.test_command   = "bundle exec ruby -Itest"
  config.test_timeout   = 30

  # Session-based authentication example.
  # The dummy app's SessionsController sets session[:authenticated] via POST /login.
  config.authenticate_with = proc {
    unless session[:authenticated]
      render plain: "Unauthorized", status: :unauthorized
    end
  }
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
    require "fileutils"
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
    FileUtils.mkdir_p(sample_workspace.join("tmp"))

    File.write(sample_workspace.join("README.md"),
               "# Sample Project\n\nThis is the dummy workspace for mbeditor development.\n")
    File.write(sample_workspace.join("app", "models", "user.rb"),
               "class User\n  attr_accessor :name, :email\nend\n")
    File.write(sample_workspace.join("app", "controllers", "application_controller.rb"),
               "class ApplicationController\n  def index\n    render plain: 'Hello'\n  end\nend\n")

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

  # ── Ensure test files always exist ──────────────────────────────────────────
  # Written on every boot so existing workspaces get the test suite even when
  # the git repo was already initialised.  Tests deliberately include a mix of
  # passing and failing cases so the Test button shows meaningful results.
  require "fileutils"
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
end
