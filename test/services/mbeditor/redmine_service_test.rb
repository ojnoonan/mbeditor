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
        fake_response.stub(:body, issue_body) do
          Net::HTTP.stub(:new, ->(_host, _port) {
            mock_http = Minitest::Mock.new
            mock_http.expect(:use_ssl=, nil, [true])
            mock_http.expect(:open_timeout=, nil, [RedmineService::TIMEOUT_SECONDS])
            mock_http.expect(:read_timeout=, nil, [RedmineService::TIMEOUT_SECONDS])
            mock_http.expect(:request, fake_response, [Net::HTTP::Get])
            mock_http
          }) do
            result = RedmineService.new(issue_id: '42').call

            assert_equal 42, result['id']
            assert_equal 'Fix the bug', result['title']
            assert_equal 'It crashes on startup', result['description']
            assert_equal 'Open', result['status']
            assert_equal 'Alice', result['author']
            assert_kind_of Array, result['notes']
          end
        end
      end
    end

    def test_raises_runtime_error_when_http_returns_404
      with_redmine_configured do
        fake_response = Net::HTTPNotFound.new('1.1', '404', 'Not Found')
        fake_response.stub(:body, '') do
          Net::HTTP.stub(:new, ->(_host, _port) {
            mock_http = Minitest::Mock.new
            mock_http.expect(:use_ssl=, nil, [true])
            mock_http.expect(:open_timeout=, nil, [RedmineService::TIMEOUT_SECONDS])
            mock_http.expect(:read_timeout=, nil, [RedmineService::TIMEOUT_SECONDS])
            mock_http.expect(:request, fake_response, [Net::HTTP::Get])
            mock_http
          }) do
            assert_raises(RuntimeError) do
              RedmineService.new(issue_id: '999').call
            end
          end
        end
      end
    end
  end
end
