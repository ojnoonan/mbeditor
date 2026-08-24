# frozen_string_literal: true

module Mbeditor
  class LogsController < ApplicationController
    # GET /logs/tail[?offset=N]
    # Reads the active environment's log file incrementally. Used for the
    # initial load (no offset) and as the HTTP polling fallback (with offset).
    def tail
      # Clamped: a negative offset reaches IO#seek and raises Errno::EINVAL,
      # which surfaced as a 500 on a param the client fully controls.
      offset = params[:offset].present? ? [params[:offset].to_i, 0].max : nil
      result = LogTailService.new(log_path).read_since(offset)
      render json: result
    end

    private

    def log_path
      Rails.root.join("log", "#{Rails.env}.log")
    end
  end
end
