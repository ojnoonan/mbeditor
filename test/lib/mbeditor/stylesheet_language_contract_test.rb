# frozen_string_literal: true

require "test_helper"

module Mbeditor
  # scss shipped mapped to Monaco's 'css' language in two places, and less was
  # mapped in neither, while PRETTIER_PARSERS already named both. The CSS
  # validator flagged every $variable, @use, & nesting and @mixin and produced
  # no highlighting, so scss opened as an unreadable wall of red; less fell
  # through to plaintext and got no highlighting or language service at all.
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

    # Monaco registers css, scss and less. Each must reach its own language:
    # scss was being sent to css, less was reaching nothing.
    %w[scss less].each do |lang|
      test "no stylesheet language map sends #{lang} somewhere else" do
        SOURCES.each do |relative|
          body = source(relative)

          refute_match(/'#{lang}':\s*'css'/, body, "#{relative} maps #{lang} to css")
          refute_match(/case 'css':case '#{lang}'/, body, "#{relative} lumps #{lang} in with css")
          assert_match(/'#{lang}'/, body, "#{relative} does not map #{lang} at all")
        end
      end

      test "#{lang}.erb is treated as #{lang}, the way css.erb is treated as css" do
        assert_match(/\\.#{lang}\\.erb\$/, source(SOURCES.first))
      end
    end
  end
end
