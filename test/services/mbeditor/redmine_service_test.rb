# frozen_string_literal: true

require 'test_helper'

module Mbeditor
  # RedmineService#call is prepended by the dummy app initializer with fixture
  # data so no real HTTP calls are needed via `call`. Config-guard tests go
  # through `call` (the prepend also runs those checks). HTTP-level tests call
  # the private `fetch_issue` directly so WebMock stubs are exercised without
  # the prepend intercepting the call.
  class RedmineServiceTest < Minitest::Test
    BASE_URL = 'https://redmine.example.test'
    API_KEY  = 'test_api_key'

    ISSUE_JSON = JSON.generate(
      'issue' => {
        'id'          => 42,
        'subject'     => 'Fix the bug',
        'description' => 'It crashes on startup',
        'status'      => { 'name' => 'Open' },
        'author'      => { 'name' => 'Alice' },
        'journals'    => [
          { 'notes' => 'Reproduced on staging.', 'user' => { 'name' => 'Bob' },
            'created_on' => '2026-01-01T00:00:00Z' },
          { 'notes' => '', 'user' => { 'name' => 'Eve' },
            'created_on' => '2026-01-02T00:00:00Z' }
        ]
      }
    ).freeze

    def setup
      @original_enabled = Mbeditor.configuration.redmine_enabled
      @original_url     = Mbeditor.configuration.redmine_url
      @original_api_key = Mbeditor.configuration.redmine_api_key
    end

    def teardown
      Mbeditor.configure do |c|
        c.redmine_enabled = @original_enabled
        c.redmine_url     = @original_url
        c.redmine_api_key = @original_api_key
      end
    end

    def with_redmine_configured
      Mbeditor.configure do |c|
        c.redmine_enabled = true
        c.redmine_url     = BASE_URL
        c.redmine_api_key = API_KEY
      end
      yield
    end

    def issue_url(id = '42')
      "#{BASE_URL}/issues/#{id}.json"
    end

    # Config-guard paths (go through call — prepend also runs these checks)

    def test_raises_redmine_disabled_error_when_not_enabled
      Mbeditor.configure { |c| c.redmine_enabled = false }
      assert_raises(RedmineDisabledError) { RedmineService.new(issue_id: '1').call }
    end

    def test_raises_redmine_config_error_when_url_is_nil
      Mbeditor.configure do |c|
        c.redmine_enabled = true
        c.redmine_url     = nil
        c.redmine_api_key = 'dummy_key'
      end
      assert_raises(RedmineConfigError) { RedmineService.new(issue_id: '1').call }
    end

    def test_raises_redmine_config_error_when_api_key_is_nil
      Mbeditor.configure do |c|
        c.redmine_enabled = true
        c.redmine_url     = BASE_URL
        c.redmine_api_key = nil
      end
      assert_raises(RedmineConfigError) { RedmineService.new(issue_id: '1').call }
    end

    # -------------------------------------------------------------------------
    # HTTP behaviour — WebMock stubs at the network layer, fetch_issue called
    # directly to bypass the dummy app prepend on call.
    # -------------------------------------------------------------------------

    def test_fetch_issue_returns_mapped_hash_on_success
      stub_request(:get, issue_url)
        .to_return(status: 200, body: ISSUE_JSON,
                   headers: { 'Content-Type' => 'application/json' })

      with_redmine_configured do
        result = RedmineService.new(issue_id: '42').send(:fetch_issue, BASE_URL, API_KEY)

        assert_equal 42,                       result['id']
        assert_equal 'Fix the bug',            result['title']
        assert_equal 'It crashes on startup',  result['description']
        assert_equal 'Open',                   result['status']
        assert_equal 'Alice',                  result['author']
        assert_equal 1,                        result['notes'].length
        assert_equal 'Reproduced on staging.', result['notes'].first['note']
      end
    end

    def test_fetch_issue_sends_api_key_header
      # The .with(headers:) constraint causes WebMock to raise if the header is
      # absent — the stub match itself acts as the assertion.
      stub_request(:get, issue_url)
        .with(headers: { 'X-Redmine-API-Key' => API_KEY })
        .to_return(status: 200, body: ISSUE_JSON,
                   headers: { 'Content-Type' => 'application/json' })

      with_redmine_configured do
        RedmineService.new(issue_id: '42').send(:fetch_issue, BASE_URL, API_KEY)
      end
    end

    def test_fetch_issue_raises_on_non_200_response
      stub_request(:get, issue_url('999')).to_return(status: 404, body: '')

      with_redmine_configured do
        err = assert_raises(RuntimeError) do
          RedmineService.new(issue_id: '999').send(:fetch_issue, BASE_URL, API_KEY)
        end
        assert_match(/404/, err.message)
      end
    end

    def test_fetch_issue_raises_on_network_timeout
      stub_request(:get, issue_url).to_timeout

      with_redmine_configured do
        assert_raises(Timeout::Error) do
          RedmineService.new(issue_id: '42').send(:fetch_issue, BASE_URL, API_KEY)
        end
      end
    end
  end
end
