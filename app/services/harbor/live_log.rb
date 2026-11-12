module Harbor
  # A run's live log: a file the work appends to as it goes, and that the run's
  # page reads while it is still running.
  #
  #   log = Harbor::LiveLog.open(run.live_log_path)
  #   log.call("fetching posts…")
  #   Harbor::LiveLog.close(log)
  #
  # Paths are relative; `Harbor.config.log_location` says where they live (a
  # folder under storage/ unless the host says otherwise).
  module LiveLog
    DEFAULT_TAIL_BYTES = 64.kilobytes

    module_function

    def absolute(relative_path) = Harbor.config.log_location.call(relative_path.to_s.sub(%r{\A/+}, "")).to_s

    # Opens the log for appending and returns a callable that writes one line.
    # nil when the run has no log (no path).
    def open(relative_path)
      return nil if relative_path.blank?

      full = absolute(relative_path)
      FileUtils.mkdir_p(File.dirname(full))
      file = File.open(full, "a")
      file.sync = true
      file.write("\n<!-- run started at #{Time.current.iso8601} -->\n\n")

      lambda do |line|
        file.write("#{line}\n")
        Rails.logger.info("[LiveLog] #{line}")
      rescue IOError
        # The file was closed mid-run: drop the line.
      end.tap { |logger| logger.define_singleton_method(:__file) { file } }
    end

    def close(logger)
      return unless logger.respond_to?(:__file)

      file = logger.__file
      file.write("\n<!-- run finished at #{Time.current.iso8601} -->\n") rescue nil
      file.close unless file.closed?
    end

    def exist?(relative_path) = relative_path.present? && File.file?(absolute(relative_path))

    # The whole log, or nil when nothing has been written.
    def read(relative_path)
      return nil unless exist?(relative_path)

      File.read(absolute(relative_path))
    end

    # The end of the log: `{ body:, clipped: }`, or nil when nothing has been
    # written. A page that refreshes every few seconds reads this, not the
    # megabytes a long run writes. A clipped tail starts at a whole line.
    def tail(relative_path, bytes: DEFAULT_TAIL_BYTES)
      return nil unless exist?(relative_path)

      file = absolute(relative_path)
      size = File.size(file)
      body = File.open(file, "rb") do |io|
        io.seek([ size - bytes, 0 ].max)
        io.read.to_s.force_encoding(Encoding::UTF_8).scrub("")
      end
      clipped = size > bytes
      body = body.sub(/\A[^\n]*\n/, "") if clipped
      { body:, clipped: }
    end
  end
end
