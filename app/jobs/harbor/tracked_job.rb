module Harbor
  # A job whose whole life is one run: it starts the run, writes its live log,
  # and records how it ended. A subclass names itself with `loader_slug` and
  # implements `load(logger:)`, returning what to keep as the run's output.
  #
  # The run is the record of pass or fail. An error is written to it and not
  # raised again, so the queue never retries behind the page's back; a failed
  # run is run again by a person, as a new run.
  #
  # Harbor's default for `config.tracked_job`. A host with a base job of its
  # own for tracked work names that instead.
  class TrackedJob < ActiveJob::Base
    queue_as :default

    # Raised when the work can't run for an expected reason (switched off,
    # something else holds the lock). Recorded as a skipped run, with the
    # message as the reason.
    class Skipped < StandardError; end

    class_attribute :loader_slug, instance_writer: false

    def perform(run_id)
      run = Harbor.run_class.find(run_id)
      run.start!
      logger = Harbor::LiveLog.open(run.live_log_path)
      logger&.call("[#{loader_slug}] starting…")

      result = load(logger: logger)

      logger&.call("[#{loader_slug}] done: #{result.inspect}")
      run.finish!(status: "ok", output: result.is_a?(Hash) ? result : { result: result })
    rescue Skipped => e
      logger&.call("[#{loader_slug}] skipped: #{e.message}")
      run&.finish!(status: "skipped", error: e.message)
    rescue => e
      logger&.call("[#{loader_slug}] ERROR: #{e.class}: #{e.message}")
      Rails.logger.error("[#{loader_slug}] #{e.class}: #{e.message}\n#{e.backtrace&.first(8)&.join("\n")}")
      run&.finish!(status: "error", error: "#{e.class}: #{e.message}")
    ensure
      Harbor::LiveLog.close(logger)
    end

    def load(logger:)
      raise NotImplementedError, "#{self.class} must implement #load"
    end
  end
end
