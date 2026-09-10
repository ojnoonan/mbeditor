# frozen_string_literal: true

require "open3"
require "json"
require "digest"
require "shellwords"
require "timeout"
require "uri"

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
    # One step per retry the crash budget actually allows: restart_allowed?
    # latches :failed at MAX_RESTARTS crashes, so a third entry is unreachable.
    RESTART_BACKOFFS = [1, 5].freeze # min seconds between crash and retry
    MAX_OPEN_DOCUMENTS = 20 # LRU cap; the evicted URI is didClose'd
    DOC_LOCK_POLL = 0.005 # seconds between @doc_mutex acquire attempts

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
      # Lock order, never taken in any other sequence:
      #   @doc_mutex   → @write_mutex
      #   @state_mutex → @write_mutex
      #   @pending_mutex is a leaf; no other lock is taken while holding it.
      # @state_mutex is never held across the initialize handshake or a
      # round-trip other than shutdown's, so a wedged server cannot park the
      # threads that only want to ask whether it is up.
      @state_mutex  = Mutex.new # lifecycle transitions
      @write_mutex  = Mutex.new # stdin framing
      @pending_mutex = Mutex.new # id => Queue map + id allocation
      @doc_mutex    = Mutex.new # document sync ordered with positional requests
      @pending      = {}
      @docs         = {}
      @next_id      = 0
      @state        = :stopped # :stopped | :starting | :ready | :crashed | :failed
      @crash_times  = []
      @last_error   = nil # last start failure, surfaced to the editor's status chip
    end

    attr_reader :state

    def ready?
      ensure_started
      @state == :ready
    end

    # A snapshot for the editor's status indicator. Deliberately does not start
    # the process — asking "how are you?" must not be what boots the server.
    #
    # Deliberately lock-free: @state_mutex is held for the whole of a start
    # (up to INIT_TIMEOUT) and a restart, and a status chip polled every 10s
    # must not queue behind a handshake. Each field is one reference read, so
    # the worst case is a snapshot that is one transition out of date.
    def health
      { state: @state, restarts: @crash_times.length, error: @last_error }
    end

    # Clears the crash budget so a client latched at :failed can be revived
    # without restarting the whole Rails process. Clearing @crash_times is the
    # load-bearing part: restart_allowed? re-latches :failed immediately if the
    # window still holds MAX_RESTARTS entries.
    def reset!
      stop
      @state_mutex.synchronize do
        @crash_times.clear
        @last_error = nil
        @state = :stopped
      end
      ready?
    end

    # Syncs the document (didOpen / full-text didChange) and issues a request
    # against it, so concurrent Puma threads can't interleave a positional
    # request with a stale document.
    # +params+ is an explicit hash (not keywords) so it can't collide with the
    # +timeout:+ keyword.
    #
    # @doc_mutex covers the sync and the write, not the wait: LSP processes
    # messages in order, so once the request is on the wire behind its didOpen
    # the server already sees the right document. Holding it across the
    # round-trip serialised every ruby-lsp request in the process for up to the
    # full request timeout.
    def request_with_document(method, path, content, params = {}, timeout: nil)
      raise NotReadyError, "ruby-lsp is not running" unless ready?

      uri = file_uri(path)
      timeout ||= (Mbeditor.configuration.ruby_lsp_timeout || 3).to_f
      # One deadline covers the queue wait and the round-trip. Timing only the
      # round-trip let a hover queued behind a 10s diagnostics call hold a Puma
      # thread for 13s while doing nothing.
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      id, queue = with_doc_lock(method, deadline) do
        sync_document(uri, content)
        send_request(method, params.merge(textDocument: { uri: uri }))
      end
      await_response(method, id, queue, remaining(deadline))
    end

    def remaining(deadline)
      [deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max
    end

    # ponytail: polled try_lock rather than a queue of waiters. The ceiling is
    # DOC_LOCK_POLL of granularity and no FIFO fairness; swap in a
    # ConditionVariable if either ever shows up in a profile.
    def with_doc_lock(method, deadline)
      until @doc_mutex.try_lock
        raise TimeoutError, "#{method} timed out waiting for the document lock" if remaining(deadline).zero?

        sleep DOC_LOCK_POLL
      end
      begin
        yield
      ensure
        @doc_mutex.unlock
      end
    end

    def request(method, params, timeout: nil)
      timeout ||= (Mbeditor.configuration.ruby_lsp_timeout || 3).to_f
      id, queue = send_request(method, params)
      await_response(method, id, queue, timeout)
    end

    # Registers a response queue and puts the request on the wire. Returns
    # [id, queue] for #await_response.
    def send_request(method, params)
      queue = Queue.new
      id = @pending_mutex.synchronize do
        @next_id += 1
        @pending[@next_id] = queue
        @next_id
      end

      begin
        write_message({ jsonrpc: "2.0", id: id, method: method, params: params })
      rescue StandardError
        @pending_mutex.synchronize { @pending.delete(id) }
        raise
      end

      [id, queue]
    end

    def await_response(method, id, queue, timeout)
      msg = pop_with_timeout(queue, timeout)
      if msg.nil?
        # Nobody is going to read this answer; tell the server to stop
        # computing it rather than leave it indexing for an abandoned caller.
        cancel_request(id)
        raise TimeoutError, "#{method} timed out after #{timeout}s"
      end
      raise Error, msg["error"]["message"].to_s if msg["error"]

      msg["result"]
    ensure
      @pending_mutex.synchronize { @pending.delete(id) }
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

    # Ruby 3.4 renamed the RFC2396 parser and deprecated escape on the RFC3986
    # one DEFAULT_PARSER now points at, so name it explicitly where it exists.
    URI_PARSER = defined?(URI::RFC2396_PARSER) ? URI::RFC2396_PARSER : URI::DEFAULT_PARSER
    private_constant :URI_PARSER

    # A workspace path is not a URI: a space raises URI::InvalidURIError inside
    # ruby-lsp and a `#` silently truncates the path at the fragment. Every
    # file:// URI this class builds goes through here.
    def file_uri(path)
      "file://#{URI_PARSER.escape(path.to_s)}"
    end

    def cancel_request(id)
      write_message({ jsonrpc: "2.0", method: "$/cancelRequest", params: { id: id } })
    rescue StandardError
      nil
    end

    # :starting is what lets the handshake run outside @state_mutex: it claims
    # the start for one thread, so a concurrent caller neither starts a second
    # process nor waits on a server that may take INIT_TIMEOUT to answer. Such
    # a caller is told "not ready" and falls back to the grep/Ripper path.
    def ensure_started
      @state_mutex.synchronize do
        return if %i[ready failed starting].include?(@state)
        return unless restart_allowed?

        @state = :starting
      end
      start_handshake
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

    def start_handshake
      cmd = resolve_command
      @stdin, @stdout, @stderr, @wait_thr = Open3.popen3(*cmd, chdir: @root, pgroup: true)
      @stdin.binmode
      @stdout.binmode

      start_reader_thread
      start_stderr_thread
      start_monitor_thread

      result = request("initialize", {
        processId: Process.pid,
        rootUri: file_uri(@root),
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
      # Still :starting means nobody else has ruled on this process: the
      # monitor thread reaching the exit first, or a stop, owns the transition.
      @state_mutex.synchronize { @state = :ready if @state == :starting }
    rescue StandardError => e
      Rails.logger.warn("[mbeditor] ruby-lsp start failed: #{e.class}: #{e.message}") if defined?(Rails)
      @state_mutex.synchronize do
        next unless @state == :starting

        @last_error = "#{e.class}: #{e.message}"
        record_crash
        cleanup_process
        @state = @crash_times.length >= MAX_RESTARTS ? :failed : :crashed
      end
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
        # EOF is the first and cheapest news that the server is gone. The
        # monitor thread also fails pending requests, but only after it can
        # take @state_mutex, so waiting for it costs the caller its whole
        # timeout — INIT_TIMEOUT for the handshake.
        fail_pending_requests if @stdout.equal?(stdout)
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
        status = wait_thr.value # blocks until process exit
        @state_mutex.synchronize do
          next if @stopping || @wait_thr != wait_thr

          # A crash mid-session leaves no exception to quote, so the exit
          # status is the only reason the status chip can show.
          @last_error = "ruby-lsp exited (#{status.exitstatus || status})"
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
      # A failed handshake (INIT_TIMEOUT on a large app) otherwise orphans a
      # ruby-lsp that is still indexing. No-op once the child has exited.
      begin
        Process.kill("-KILL", @wait_thr.pid) if @wait_thr
      rescue StandardError
        nil
      end

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
      # Deleted and re-inserted below, so @docs stays in least-recently-used
      # order: a plain Hash preserves insertion order, which is the whole LRU.
      doc = @docs.delete(uri)
      if doc && doc[:digest] == digest
        @docs[uri] = doc
        return
      end

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
      evict_documents
    end

    # Nothing tells the client that a tab closed, so without a cap the server
    # keeps every file ever hovered open and indexed for the whole session.
    def evict_documents
      while @docs.length > MAX_OPEN_DOCUMENTS
        stale_uri, = @docs.shift
        write_message({ jsonrpc: "2.0", method: "textDocument/didClose", params: {
          textDocument: { uri: stale_uri }
        } })
      end
    end
  end
end
