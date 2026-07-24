# frozen_string_literal: true

require "pathname"

module Mbeditor
  # Reads a log file incrementally from a byte offset. Pure Ruby, no subprocess.
  #
  # read_since(offset) -> { lines: Array<String>, offset: Integer, reset: Boolean }
  #   offset == nil  -> initial load: last INITIAL_TAIL_BYTES, reset: true
  #   offset >  size -> file rotated/truncated: re-read from 0, reset: true
  #   else           -> read new bytes from offset, capped at BYTE_CAP
  #
  # Only complete lines (terminated by "\n") are ever returned; the byte offset
  # advances solely past consumed complete lines, so a partial trailing line is
  # held back and delivered once its newline arrives.
  class LogTailService
    BYTE_CAP           = 256 * 1024
    INITIAL_TAIL_BYTES = 64 * 1024

    def initialize(log_path)
      @log_path = Pathname.new(log_path.to_s)
    end

    def read_since(offset)
      return empty(0) unless @log_path.exist?

      size = @log_path.size
      if offset.nil?
        start = [size - INITIAL_TAIL_BYTES, 0].max
        read_range(start, size, reset: true, trim_leading: start.positive?)
      elsif offset.to_i > size
        read_range(0, [size, BYTE_CAP].min, reset: true, trim_leading: false)
      else
        start = offset.to_i
        read_range(start, [start + BYTE_CAP, size].min, reset: false, trim_leading: false)
      end
    end

    private

    def empty(offset, reset: false)
      { lines: [], offset: offset, reset: reset }
    end

    def read_range(start, stop, reset:, trim_leading:)
      return empty(start, reset: reset) if stop <= start

      chunk = File.open(@log_path, "rb") do |f|
        f.seek(start)
        f.read(stop - start) || ""
      end

      last_nl = chunk.rindex("\n")
      return empty(start, reset: reset) if last_nl.nil? # no complete line yet

      consumed = chunk[0..last_nl]
      lines = consumed.force_encoding("UTF-8").scrub.split("\n")
      lines.shift if trim_leading && !lines.empty? # drop partial first line on initial tail
      { lines: lines, offset: start + consumed.bytesize, reset: reset }
    end
  end
end
