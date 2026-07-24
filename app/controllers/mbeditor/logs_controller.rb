# frozen_string_literal: true

module Mbeditor
  class LogsController < ApplicationController
    # GET /logs/tail[?offset=N]
    # Reads the active environment's log file incrementally. Used for the
    # initial load (no offset) and as the HTTP polling fallback (with offset).
    def tail
      offset = params[:offset].present? ? params[:offset].to_i : nil
      result = LogTailService.new(log_path).read_since(offset)
      render json: result
    end

    private

    def log_path
      Rails.root.join("log", "#{Rails.env}.log")
    end
  end
end
