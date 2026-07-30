# frozen_string_literal: true

require "test_helper"

begin
  require "mini_racer"
rescue LoadError
  # This optional contract suite skips in minimal compatibility bundles.
end

module Mbeditor
  class EditorPanelOutlineContractTest < ActiveSupport::TestCase
    def setup
      skip "MiniRacer is not installed in this compatibility bundle" unless defined?(::MiniRacer)

      @context = MiniRacer::Context.new
      @context.eval(<<~JAVASCRIPT)
        var window = this;
        var hookStates = [];
        var hookRefs = [];
        var stateCursor = 0;
        var refCursor = 0;

        function resetHooks() {
          stateCursor = 0;
          refCursor = 0;
        }

        var React = {
          Fragment: 'fragment',
          useState: function (initial) {
            var index = stateCursor++;
            if (!(index in hookStates)) hookStates[index] = initial;
            return [
              hookStates[index],
              function (value) {
                hookStates[index] = typeof value === 'function' ? value(hookStates[index]) : value;
              }
            ];
          },
          useRef: function (initial) {
            var index = refCursor++;
            if (!hookRefs[index]) hookRefs[index] = { current: initial };
            return hookRefs[index];
          },
          useEffect: function () {},
          createElement: function (type, props) {
            var children = Array.prototype.slice.call(arguments, 2);
            props = props || {};
            if (props.ref && typeof type === 'string') {
              props.ref.current = {
                getBoundingClientRect: function () { return { bottom: 20, right: 80 }; }
              };
            }
            return { type: type, props: props, children: children };
          },
          memo: function (component) { return component; }
        };

        window.React = React;
        window.innerWidth = 1000;
        window.document = {
          addEventListener: function () {},
          removeEventListener: function () {},
          createElement: function () {
            return { style: {}, appendChild: function () {} };
          },
          body: {
            appendChild: function () {},
            removeChild: function () {}
          }
        };
        window.navigator = { platform: '' };
        window.EditorStore = {
          getState: function () { return { panes: [] }; },
          setState: function () {},
          setStatus: function () {}
        };
        window.FileService = {};
        window.MbeditorConfig = {};
        window.MbeditorUtilities = {};
        window.IconRegistry = {};

        function walkNodes(node, output) {
          output = output || [];
          if (Array.isArray(node)) {
            node.forEach(function (child) { walkNodes(child, output); });
            return output;
          }
          if (!node || typeof node !== 'object') return output;
          output.push(node);
          (node.children || []).forEach(function (child) { walkNodes(child, output); });
          return output;
        }

        function directNodes(node) {
          var output = [];
          (node.children || []).forEach(function (child) {
            if (Array.isArray(child)) {
              child.forEach(function (nested) {
                if (nested && typeof nested === 'object') output.push(nested);
              });
            } else if (child && typeof child === 'object') {
              output.push(child);
            }
          });
          return output;
        }

        function hasClass(node, className) {
          var classes = String((node.props || {}).className || '').split(/\\s+/);
          return classes.indexOf(className) !== -1;
        }

        function renderOutlineContract() {
          var source = [
            'class Outer',
            '  private',
            '  def hidden; end',
            '  test "case" do; end',
            '  class Inner',
            '    def plain; end',
            '  end',
            'end'
          ];
          var calls = [];
          var model = {
            getLineCount: function () { return source.length; },
            getLineContent: function (line) { return source[line - 1]; }
          };
          var editor = {
            getModel: function () { return model; },
            revealLineInCenter: function (line) { calls.push(['reveal', line]); },
            setPosition: function (position) {
              calls.push(['position', position.lineNumber, position.column]);
            },
            focus: function () { calls.push(['focus']); }
          };
          var props = {
            tab: {
              path: 'test/models/outer_test.rb',
              name: 'outer_test.rb',
              content: source.join('\\n')
            },
            paneId: 'pane-1',
            markers: [],
            editorPrefs: { toolbarIconOnly: false },
            monacoReady: true,
            treeData: []
          };

          function render() {
            resetHooks();
            return EditorPanel(props);
          }

          var tree = render();
          hookRefs[1].current = editor;
          var outlineButton = walkNodes(tree).filter(function (node) {
            return node.props && node.props.title === 'Jump to Outline';
          })[0];
          outlineButton.props.onClick();

          tree = render();
          var nodes = walkNodes(tree);
          var dropdown = nodes.filter(function (node) {
            return hasClass(node, 'ide-methods-dropdown');
          })[0];
          var rows = nodes.filter(function (node) {
            return hasClass(node, 'ide-outline-entry');
          });
          var testRow = rows.filter(function (node) {
            return node.props['data-outline-kind'] === 'test';
          })[0];
          var firstRow = rows[0];

          function activateWithClick() {
            calls = [];
            if (typeof testRow.props.onClick === 'function') testRow.props.onClick();
            return calls;
          }

          var click = activateWithClick();
          var dropdownChildren = directNodes(dropdown);
          var visibilityGroup = dropdownChildren.filter(function (node) {
            return hasClass(node, 'ide-methods-dropdown-visibility-group');
          })[0];

          return {
            firstRowType: firstRow.type,
            firstRowButtonType: firstRow.props.type || null,
            firstRowTabIndex: typeof firstRow.props.tabIndex === 'number' ? firstRow.props.tabIndex : null,
            firstRowAutoFocus: firstRow.props.autoFocus === true,
            testRowAriaLabel: testRow.props['aria-label'] || null,
            hasOnClick: typeof testRow.props.onClick === 'function',
            hasKeyDown: typeof testRow.props.onKeyDown === 'function',
            hasMouseDown: typeof testRow.props.onMouseDown === 'function',
            click: click,
            directClasses: dropdownChildren.map(function (node) {
              return String((node.props || {}).className || '');
            }),
            visibilityGroupClasses: visibilityGroup ? directNodes(visibilityGroup).map(function (node) {
              return String((node.props || {}).className || '');
            }) : []
          };
        }
      JAVASCRIPT
      @context.eval(File.read(Mbeditor::Engine.root.join("app/assets/javascripts/mbeditor/ruby_outline.js")))
      @context.eval(File.read(Mbeditor::Engine.root.join("app/assets/javascripts/mbeditor/components/EditorPanel.js")))
    end

    test "outline rows expose native button click activation" do
      result = @context.eval("renderOutlineContract()")

      assert_equal "button", result.fetch("firstRowType")
      assert_equal "button", result.fetch("firstRowButtonType")
      assert_equal 0, result.fetch("firstRowTabIndex")
      assert_equal true, result.fetch("firstRowAutoFocus")
      assert_equal "case, line 4", result.fetch("testRowAriaLabel")
      assert_equal true, result.fetch("hasOnClick")
      assert_equal false, result.fetch("hasKeyDown")
      assert_equal false, result.fetch("hasMouseDown")
      assert_equal(
        [["reveal", 4], ["position", 4, 1], ["focus"]],
        result.fetch("click")
      )
    end

    test "visibility headings are bounded to consecutive visible method runs" do
      result = @context.eval("renderOutlineContract()")

      assert_equal(
        [
          "ide-methods-dropdown-visibility-group",
          "ide-methods-dropdown-item ide-outline-entry ide-outline-entry-test",
          "ide-methods-dropdown-item ide-outline-entry ide-outline-entry-method"
        ],
        result.fetch("directClasses")
      )
      assert_equal(
        [
          "ide-methods-dropdown-visibility",
          "ide-methods-dropdown-item ide-outline-entry ide-outline-entry-method"
        ],
        result.fetch("visibilityGroupClasses")
      )
    end
  end
end
