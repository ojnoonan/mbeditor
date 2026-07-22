# frozen_string_literal: true

require "open3"
require "json"
require "digest"
require "shellwords"
require "timeout"

module Mbeditor
  # Manages a persistent ruby-lsp process per workspace and speaks the
  # Language Server Protocol to it over stdio (Content-Length framing).
  #
  # Lives in lib/ (required from lib/mbeditor.rb, NOT autoloaded) so Zeitwerk
  # code reloads in the host's dev environment cannot wipe the registry and
  # orphan the child process.
  #
  # Usage:
  #   client = RubyLspClient.for(workspace_root)
  #   client.request_with_document("textDocument/definition", abs_path, content,
  #                                position: { line: 0, character: 4 })
  # Raises NotReadyError / TimeoutError for callers to fall back to the
  # legacy grep/Ripper services.
  class RubyLspClient
    class Error < StandardError; end
    class TimeoutError < Error; end
    class NotReadyError < Error; end

    INIT_TIMEOUT = 15 # seconds for the initialize handshake
    SHUTDOWN_GRACE = 2 # seconds before pgroup KILL
    MAX_RESTARTS = 3
    RESTART_WINDOW = 300 # seconds
    RESTART_BACKOFFS = [1, 5, 25].freeze # min seconds between crash and retry

    REGISTRY_MUTEX = Mutex.new
    private_constant :REGISTRY_MUTEX

    class << self
      def for(workspace_root)
        root = workspace_root.to_s
        REGISTRY_MUTEX.synchronize do
          @registry ||= {}
          unless @at_exit_registered
            at_exit { stop_all }
            @at_exit_registered = true
          end
          @registry[root] ||= new(root)
        end
      end

      def stop_all
        clients = REGISTRY_MUTEX.synchronize { (@registry || {}).values.dup }
        clients.each do |c|
          begin
            c.stop
          rescue StandardError
            nil
          end
        end
      end

      # Tests only.
      def reset!
        stop_all
        REGISTRY_MUTEX.synchronize { @registry = {} }
      end
    end

    def initialize(root)
      @root         = root
      @state_mutex  = Mutex.new # lifecycle transitions
      @write_mutex  = Mutex.new # stdin framing
      @pending_mutex = Mutex.new # id => Queue map + id allocation
      @doc_mutex    = Mutex.new # document sync ordered with positional requests
      @pending      = {}
      @docs         = {}
      @next_id      = 0
      @state        = :stopped # :stopped | :ready | :crashed | :failed
      @crash_times  = []
    end

    attr_reader :state

    def ready?
      ensure_started
      @state == :ready
    end

    # Syncs the document (didOpen / full-text didChange) and issues a request
    # against it under one mutex, so concurrent Puma threads can't interleave
    # a positional request with a stale document.
    # +params+ is an explicit hash (not keywords) so it can't collide with the
    # +timeout:+ keyword.
    def request_with_document(method, path, content, params = {}, timeout: nil)
      raise NotReadyError, "ruby-lsp is not running" unless ready?

      uri = "file://#{path}"
      @doc_mutex.synchronize do
        sync_document(uri, content)
        request(method, params.merge(textDocument: { uri: uri }), timeout: timeout)
      end
    end

    def request(method, params, timeout: nil)
      timeout ||= (Mbeditor.configuration.ruby_lsp_timeout || 3).to_f
      queue = Queue.new
      id = @pending_mutex.synchronize do
        @next_id += 1
        @pending[@next_id] = queue
        @next_id
      end

      write_message({ jsonrpc: "2.0", id: id, method: method, params: params })

      msg = pop_with_timeout(queue, timeout)
      raise TimeoutError, "#{method} timed out after #{timeout}s" if msg.nil?
      raise Error, msg["error"]["message"].to_s if msg["error"]

      msg["result"]
    ensure
      @pending_mutex.synchronize { @pending.delete(id) } if id
    end

    # Queue#pop only accepts a timeout: keyword from Ruby 3.2 onwards, and the
    # gem supports 3.0. Returns nil on timeout either way.
    QUEUE_POP_SUPPORTS_TIMEOUT = RUBY_VERSION >= "3.2"

    def pop_with_timeout(queue, timeout)
      return queue.pop(timeout: timeout) if QUEUE_POP_SUPPORTS_TIMEOUT

      begin
        Timeout.timeout(timeout) { queue.pop }
      rescue Timeout::Error
        nil
      end
    end

    def stop
      @state_mutex.synchronize do
        next unless @wait_thr

        @stopping = true
        begin
          request("shutdown", nil, timeout: 1)
        rescue StandardError
          nil
        end
        begin
          write_message({ jsonrpc: "2.0", method: "exit" })
        rescue StandardError
          nil
        end
        unless @wait_thr.join(SHUTDOWN_GRACE)
          begin
            Process.kill("-KILL", @wait_thr.pid)
          rescue StandardError
            nil
          end
        end
        cleanup_process
        @state = :stopped
        @stopping = false
      end
    end

    private

    def ensure_started
      @state_mutex.synchronize do
        return if @state == :ready || @state == :failed
        return unless restart_allowed?

        start_locked
      end
    end

    def restart_allowed?
      return true if @crash_times.empty?

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @crash_times.reject! { |t| now - t > RESTART_WINDOW }
      if @crash_times.length >= MAX_RESTARTS
        @state = :failed
        return false
      end
      backoff = RESTART_BACKOFFS[[@crash_times.length - 1, 0].max] || RESTART_BACKOFFS.last
      now - @crash_times.last >= backoff
    end

    def start_locked
      cmd = resolve_command
      @stdin, @stdout, @stderr, @wait_thr = Open3.popen3(*cmd, chdir: @root, pgroup: true)
      @stdin.binmode
      @stdout.binmode

      start_reader_thread
      start_stderr_thread
      start_monitor_thread

      result = request("initialize", {
        processId: Process.pid,
        rootUri: "file://#{@root}",
        capabilities: {
          textDocument: {
            synchronization: { didSave: false },
            definition: {}, hover: {}, completion: {},
            diagnostic: { dynamicRegistration: false }
          }
        },
        initializationOptions: {}
      }, timeout: INIT_TIMEOUT)
      raise Error, "no initialize result" if result.nil?

      write_message({ jsonrpc: "2.0", method: "initialized", params: {} })
      @docs = {}
      @state = :ready
    rescue StandardError => e
      Rails.logger.warn("[mbeditor] ruby-lsp start failed: #{e.class}: #{e.message}") if defined?(Rails)
      record_crash
      cleanup_process
      @state = @crash_times.length >= MAX_RESTARTS ? :failed : :crashed
    end

    def resolve_command
      # Single source of truth for command resolution (config override,
      # bin/ stub, installed gem, bundle exec). Runs at request time, when
      # the app/services autoload path is fully booted.
      AvailabilityProbe.ruby_lsp_command(@root)
    end

    # ── framing ────────────────────────────────────────────────────────────

    def write_message(payload)
      json = JSON.generate(payload)
      frame = "Content-Length: #{json.bytesize}\r\n\r\n#{json}"
      @write_mutex.synchronize do
        raise Error, "ruby-lsp stdin closed" if @stdin.nil? || @stdin.closed?

        @stdin.write(frame)
        @stdin.flush
      end
    end

    def start_reader_thread
      stdout = @stdout
      @reader_thread = Thread.new do
        loop do
          msg = read_message(stdout)
          break if msg.nil?

          dispatch(msg)
        end
      rescue StandardError
        nil
      end
    end

    def read_message(io)
      content_length = nil
      loop do
        line = io.gets("\r\n")
        return nil if line.nil?

        line = line.chomp("\r\n")
        break if line.empty?

        if (m = line.match(/\AContent-Length:\s*(\d+)\z/i))
          content_length = m[1].to_i
        end
      end
      return nil if content_length.nil?

      body = io.read(content_length)
      return nil if body.nil? || body.bytesize < content_length

      JSON.parse(body)
    rescue JSON::ParserError
      {} # skip malformed frame, keep the stream alive
    end

    def dispatch(msg)
      if msg["id"] && msg["method"]
        # Server-initiated request — answer minimally so ruby-lsp isn't blocked.
        result = case msg["method"]
                 when "workspace/configuration"
                   Array.new(Array(msg.dig("params", "items")).length)
                 end
        begin
          write_message({ jsonrpc: "2.0", id: msg["id"], result: result })
        rescue StandardError
          nil
        end
      elsif msg["id"]
        queue = @pending_mutex.synchronize { @pending[msg["id"]] }
        queue << msg if queue
      end
      # Notifications (diagnostics, progress, logs) are ignored in v1.
    end

    def start_stderr_thread
      stderr = @stderr
      @stderr_thread = Thread.new do
        while (line = stderr.gets)
          Rails.logger.debug("[mbeditor] ruby-lsp stderr: #{line.chomp}") if defined?(Rails)
        end
      rescue StandardError
        nil
      end
    end

    def start_monitor_thread
      wait_thr = @wait_thr
      @monitor_thread = Thread.new do
        wait_thr.value # blocks until process exit
        @state_mutex.synchronize do
          next if @stopping || @wait_thr != wait_thr

          record_crash
          cleanup_process
          @state = @crash_times.length >= MAX_RESTARTS ? :failed : :crashed
        end
        fail_pending_requests
      rescue StandardError
        nil
      end
    end

    def record_crash
      @crash_times << Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def fail_pending_requests
      queues = @pending_mutex.synchronize do
        qs = @pending.values.dup
        @pending.clear
        qs
      end
      queues.each { |q| q << { "error" => { "message" => "ruby-lsp exited" } } }
    end

    def cleanup_process
      [@stdin, @stdout, @stderr].each do |io|
        begin
          io&.close
        rescue StandardError
          nil
        end
      end
      @stdin = @stdout = @stderr = nil
      @wait_thr = nil
      @docs = {}
    end

    # ── document sync ──────────────────────────────────────────────────────

    # Sends the buffer's current contents to the server.
    #
    # ruby-lsp advertises TextDocumentSyncKind::INCREMENTAL and its
    # Document#push_edits dereferences `edit[:range]` unconditionally, so a
    # rangeless full-text didChange raises inside the server and the document
    # silently keeps its previous contents. Rather than compute incremental
    # ranges, re-open the document: didClose + didOpen replaces the server's
    # copy wholesale and is guaranteed correct for unsaved buffers.
    def sync_document(uri, content)
      digest = Digest::SHA1.hexdigest(content)
      doc = @docs[uri]
      return if doc && doc[:digest] == digest

      version = doc ? doc[:version] + 1 : 1
      if doc
        write_message({ jsonrpc: "2.0", method: "textDocument/didClose", params: {
          textDocument: { uri: uri }
        } })
      end
      write_message({ jsonrpc: "2.0", method: "textDocument/didOpen", params: {
        textDocument: { uri: uri, languageId: "ruby", version: version, text: content }
      } })
      @docs[uri] = { version: version, digest: digest }
    end
  end
end
