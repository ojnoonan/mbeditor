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

    def views
      UnusedMethodsService.call(@workspace)[:views]
    end

    def test_render_form_builder_local_uses_sibling_form_partial
      write("app/views/rules/_form.html.haml", "x")
      write("app/views/rules/new.html.haml", "= render form\n")
      write("app/controllers/rules_controller.rb", "class RulesController < ApplicationController\n  def new\n  end\nend\n")

      assert_empty views
    end

    def test_partial_named_after_a_model_is_used_whatever_the_render_variable
      write("app/models/account_warning.rb", "class AccountWarning; end\n")
      write("app/views/admin/account_warnings/_account_warning.html.haml", "x")

      assert_empty views
    end

    def test_gem_override_dirs_are_never_reported
      write("Gemfile.lock", "GEM\n  specs:\n    kaminari (1.2.2)\n")
      write("app/views/kaminari/_gap.html.haml", "x")

      assert_empty views
    end

    def test_action_inherited_from_a_workspace_or_gem_controller_is_used
      write("app/controllers/admin/settings_controller.rb",
            "module Admin\n  class SettingsController < BaseController\n    def show\n    end\n  end\nend\n")
      write("app/controllers/admin/base_controller.rb", "module Admin\n  class BaseController < ApplicationController\n  end\nend\n")
      write("app/controllers/admin/settings/about_controller.rb", "class Admin::Settings::AboutController < Admin::SettingsController\nend\n")
      write("app/controllers/auth/sessions_controller.rb", "class Auth::SessionsController < Devise::SessionsController\nend\n")
      write("app/views/admin/settings/about/show.html.haml", "x")
      write("app/views/auth/sessions/new.html.haml", "x")
      write("app/views/admin/settings/about/stale.html.haml", "x")

      assert_equal ["app/views/admin/settings/about/stale.html.haml"], views
    end

    def test_file_named_by_its_constant_or_import_is_not_dead
      write("app/workers/purge_worker.rb", "class PurgeWorker\n  def helper_x\n  end\nend\n")
      write("app/models/caller.rb", "PurgeWorker.perform_async\n")
      write("app/javascript/types/quotes.ts", "export function quoteHelper() {}\n")
      write("app/javascript/app.ts", "import type { Q } from './types/quotes';\n")
      write("app/javascript/dead_utils.ts", "export function deadHelper() {}\n")
      write("config/initializers/patch.rb", "module Patch\n  def patched_x\n  end\nend\n")

      assert_equal ["app/javascript/dead_utils.ts"], UnusedMethodsService.call(@workspace)[:files]
    end

    def test_unrendered_partial_is_reported_and_layout_application_never
      write("app/views/users/_orphan.html.erb", "x")
      write("app/views/layouts/application.html.erb", "x")

      assert_equal ["app/views/users/_orphan.html.erb"], views
    end

    def test_rendered_partials_are_not_reported
      write("app/views/users/_form.html.erb", "x")
      write("app/views/users/_user.html.erb", "x")
      write("app/views/users/_row.html.erb", "x")
      write("app/views/shared/_nav.html.haml", "x")
      write("app/views/layouts/_flash.html.erb", "x")
      write("app/views/users/new.html.erb", "<%= render 'form' %>")
      write("app/views/users/index.html.erb", "<%= render @users %>\n<%= render partial: :row %>")
      write("app/views/layouts/application.html.haml", "= render 'shared/nav'\n= render layout: \"layouts/flash\" do\n")
      write("app/controllers/users_controller.rb", "class UsersController\n  def new; end\n  def index; end\nend\n")

      assert_equal [], views
    end

    def test_action_template_with_def_is_not_reported_but_orphan_is
      write("app/controllers/pages_controller.rb", "class PagesController\n  def home; end\nend\n")
      write("app/views/pages/home.html.erb", "x")
      write("app/views/pages/stale.html.erb", "x")
      write("app/views/pages/data.json.jbuilder", "x")

      assert_equal ["app/views/pages/data.json.jbuilder", "app/views/pages/stale.html.erb"], views
    end

    def test_controller_render_by_name_and_mailer_views_are_not_reported
      write("app/controllers/pages_controller.rb", "class PagesController\n  def home\n    render :other\n  end\nend\n")
      write("app/views/pages/other.html.erb", "x")
      write("app/mailers/user_mailer.rb", "class UserMailer\n  def welcome; end\nend\n")
      write("app/views/user_mailer/welcome.text.erb", "x")

      assert_equal [], views
    end

    def test_methods_defined_in_view_files_are_not_reported
      write("app/views/a.html.erb", "<% def inline_dead; end %>")

      assert_equal [], names
    end
  end
end
