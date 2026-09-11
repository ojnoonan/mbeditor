# frozen_string_literal: true

require "test_helper"

module Mbeditor
  # scss shipped mapped to Monaco's 'css' language in two places while
  # PRETTIER_PARSERS already said 'scss'. The CSS validator then flagged every
  # $variable, @use, & nesting and @mixin, and the css tokenizer produced no
  # highlighting at all, so an scss file opened as an unreadable wall of red.
  #
  # A source guard, not a behavioural one: the language is chosen inside
  # EditorPanel's render and is only observable through a Monaco stub. It
  # catches what actually went wrong, which is these copies drifting apart.
  class StylesheetLanguageContractTest < ActiveSupport::TestCase
    SOURCES = %w[
      app/assets/javascripts/mbeditor/components/EditorPanel.js
      app/assets/javascripts/mbeditor/components/DiffViewer.js
    ].freeze

    def source(relative)
      File.read(Mbeditor::Engine.root.join(relative))
    end

    test "no stylesheet language map sends scss to css" do
      SOURCES.each do |relative|
        body = source(relative)

        refute_match(/'scss':\s*'css'/, body, "#{relative} maps scss to css")
        refute_match(/case 'css':case 'scss'/, body, "#{relative} lumps scss in with css")
        assert_match(/'scss'/, body, "#{relative} no longer mentions scss at all")
      end
    end

    test "scss.erb is treated as scss, the way css.erb is treated as css" do
      assert_match(/\\.scss\\.erb\$/, source(SOURCES.first))
    end
  end
end
