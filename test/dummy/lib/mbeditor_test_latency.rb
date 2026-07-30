# frozen_string_literal: true

# Test-only middleware that injects artificial latency into the editor's
# server requests, so system tests can exercise the editor against a slow
# server / slow network connection. It is a no-op unless a test sets a delay
# via MbeditorTestLatency.with(seconds) { ... }.
#
# The system-test Puma server runs in a separate thread within the same process
# as the test, so a mutex-guarded delay set on the test thread is visible to the
# server thread.
module MbeditorTestLatency
  @mutex = Mutex.new
  @delay = 0.0

  class << self
    def delay
      @mutex.synchronize { @delay }
    end

    def delay=(seconds)
      @mutex.synchronize { @delay = seconds.to_f }
    end

    # Run a block with the given per-request delay applied to editor API
    # requests, restoring the previous delay afterwards.
    def with(seconds)
      previous = delay
      self.delay = seconds
      yield
    ensure
      self.delay = previous
    end
  end

  class Middleware
    # Editor data/API requests that should be slowed. The HTML shell and the
    # static asset / Monaco bundle requests are left fast so the page still
    # boots; the latency targets the XHRs the editor makes while in use
    # (file load/save, tree, state, search, git status, …) — exactly where a
    # slow server would be felt.
    def initialize(app)
      @app = app
    end

    def call(env)
      delay = MbeditorTestLatency.delay
      sleep(delay) if delay.positive? && delayable?(env)
      @app.call(env)
    end

    private

    def delayable?(env)
      path = "#{env['SCRIPT_NAME']}#{env['PATH_INFO']}"
      return false unless path.start_with?("/mbeditor")
      return false if path == "/mbeditor" || path == "/mbeditor/"          # HTML shell
      return false if path.start_with?("/mbeditor/assets")                  # CSS/JS bundle
      return false if path.start_with?("/mbeditor/monaco-editor")           # Monaco bundle/workers

      true
    end
  end
end
