# frozen_string_literal: true

require 'test_helper'
require 'net/http'

module Mbeditor
  class RedmineServiceTest < Minitest::Test
    def setup
      @original_enabled   = Mbeditor.configuration.redmine_enabled
      @original_url       = Mbeditor.configuration.redmine_url
      @original_api_key   = Mbeditor.configuration.redmine_api_key
    end

    def teardown
      Mbeditor.configure do |c|
        c.redmine_enabled  = @original_enabled
        c.redmine_url      = @original_url
        c.redmine_api_key  = @original_api_key
      end
    end

    # -------------------------------------------------------------------------
    # Disabled / config-error paths (no HTTP needed)
    # -------------------------------------------------------------------------

    def test_raises_redmine_disabled_error_when_not_enabled
      Mbeditor.configure { |c| c.redmine_enabled = false }

      assert_raises(RedmineDisabledError) do
        RedmineService.new(issue_id: '1').call
      end
    end

    def test_raises_redmine_config_error_when_url_is_nil
      Mbeditor.configure do |c|
        c.redmine_enabled  = true
        c.redmine_url      = nil
        c.redmine_api_key  = 'dummy_key'
      end

      assert_raises(RedmineConfigError) do
        RedmineService.new(issue_id: '1').call
      end
    end

    def test_raises_redmine_config_error_when_api_key_is_nil
      Mbeditor.configure do |c|
        c.redmine_enabled  = true
        c.redmine_url      = 'https://redmine.example.com'
        c.redmine_api_key  = nil
      end

      assert_raises(RedmineConfigError) do
        RedmineService.new(issue_id: '1').call
      end
    end

    # -------------------------------------------------------------------------
    # HTTP paths (stubbed)
    # -------------------------------------------------------------------------

    def with_redmine_configured
      Mbeditor.configure do |c|
        c.redmine_enabled  = true
        c.redmine_url      = 'https://redmine.example.com'
        c.redmine_api_key  = 'test_api_key'
      end
      yield
    end

    def with_http_new_stub(stub_proc)
      net_http_singleton = class << Net::HTTP; self; end
      net_http_singleton.alias_method :__original_new_for_redmine_test, :new
      Net::HTTP.define_singleton_method(:new, &stub_proc)
      yield
    ensure
      net_http_singleton.alias_method :new, :__original_new_for_redmine_test
      net_http_singleton.remove_method :__original_new_for_redmine_test
    end

    def test_returns_issue_hash_with_correct_keys_for_valid_response
      with_redmine_configured do
        issue_body = JSON.generate({
          'issue' => {
            'id'          => 42,
            'subject'     => 'Fix the bug',
            'description' => 'It crashes on startup',
            'status'      => { 'name' => 'Open' },
            'author'      => { 'name' => 'Alice' },
            'journals'    => []
          }
        })

        fake_response = Net::HTTPSuccess.new('1.1', '200', 'OK')
        fake_response.define_singleton_method(:body) { issue_body }
        fake_http = Object.new
        fake_http.define_singleton_method(:use_ssl=) { |_value| }
        fake_http.define_singleton_method(:open_timeout=) { |_value| }
        fake_http.define_singleton_method(:read_timeout=) { |_value| }
        fake_http.define_singleton_method(:request) do |request|
          raise 'expected Net::HTTP::Get' unless request.is_a?(Net::HTTP::Get)

          fake_response
        end
        with_http_new_stub(->(_host, _port) {
          fake_http
        }) do
          result = RedmineService.new(issue_id: '42').send(
            :fetch_issue,
            Mbeditor.configuration.redmine_url,
            Mbeditor.configuration.redmine_api_key
          )

          assert_equal 42, result['id']
          assert_equal 'Fix the bug', result['title']
          assert_equal 'It crashes on startup', result['description']
          assert_equal 'Open', result['status']
          assert_equal 'Alice', result['author']
          assert_kind_of Array, result['notes']
        end
      end
    end

    def test_raises_runtime_error_when_http_returns_404
      with_redmine_configured do
        fake_response = Net::HTTPNotFound.new('1.1', '404', 'Not Found')
        fake_response.define_singleton_method(:body) { '' }
        fake_http = Object.new
        fake_http.define_singleton_method(:use_ssl=) { |_value| }
        fake_http.define_singleton_method(:open_timeout=) { |_value| }
        fake_http.define_singleton_method(:read_timeout=) { |_value| }
        fake_http.define_singleton_method(:request) do |request|
          raise 'expected Net::HTTP::Get' unless request.is_a?(Net::HTTP::Get)

          fake_response
        end
        with_http_new_stub(->(_host, _port) {
          fake_http
        }) do
          assert_raises(RuntimeError) do
            RedmineService.new(issue_id: '999').send(
              :fetch_issue,
              Mbeditor.configuration.redmine_url,
              Mbeditor.configuration.redmine_api_key
            )
          end
        end
      end
    end
  end
end
