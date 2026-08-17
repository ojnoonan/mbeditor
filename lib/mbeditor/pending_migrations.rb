# frozen_string_literal: true

module Mbeditor
  # The last pending-migration message seen, so the editor can warn about it
  # without being blocked by it.
  #
  # Lives in lib/ (not autoloaded) for the same reason ExceptionLog does: a
  # Zeitwerk reload must not wipe it, and a pending migration is exactly the
  # state in which reloads are happening.
  module PendingMigrations
    MUTEX = Mutex.new
    private_constant :MUTEX

    module_function

    # message: the PendingMigrationError's message, or nil once it clears.
    def note(message)
      MUTEX.synchronize { @message = message && message.to_s.strip }
    end

    def clear
      MUTEX.synchronize { @message = nil }
    end

    def message
      MUTEX.synchronize { @message }
    end

    def pending?
      !message.nil?
    end
  end
end
