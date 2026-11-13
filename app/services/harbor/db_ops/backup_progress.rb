module Harbor
  module DbOps
    # Live progress for one dump, kept on the Run (runs.progress) so the Run and
    # Database pages can show "3.0 GB / ~5.0 GB · 60% · ~12 min left".
    #
    # Greenmask doesn't know how big a dump will be, so the estimate is the
    # previous backup of the same database and kind (backups are regular, so it's
    # close). With no previous backup there is no percentage; the source's
    # uncompressed table size is shown as a rough reference instead.
    class BackupProgress
      LOG_EVERY = 60 # seconds between progress lines in the Run log

      attr_reader :expected_bytes

      def initialize(run:, label:, step:, steps:, expected_bytes:, reference_bytes: nil, logger: nil, clock: -> { Time.current })
        @run, @label, @step, @steps, @logger, @clock = run, label, step, steps, logger, clock
        @expected_bytes = expected_bytes.to_i.positive? ? expected_bytes.to_i : nil
        @reference_bytes = reference_bytes
        @started_at = clock.call
        @logged_at = nil
      end

      # Called by Greenmask.dump with the bytes written so far.
      def call(bytes)
        now = @clock.call
        data = snapshot(bytes, now)
        @run.update_columns(progress: data, updated_at: now)
        if @logged_at.nil? || now - @logged_at >= LOG_EVERY
          @logged_at = now
          @logger&.call("[progress] #{self.class.summary(data)}")
        end
        data
      end

      def snapshot(bytes, now = @clock.call)
        elapsed = [ now - @started_at, 1 ].max
        rate = bytes / elapsed
        data = { "label" => @label, "step" => @step, "steps" => @steps, "bytes" => bytes,
                 "bytes_per_second" => rate.round, "started_at" => @started_at.iso8601, "updated_at" => now.iso8601 }
        if @expected_bytes
          data["expected_bytes"] = @expected_bytes
          # Never claim done while the dump is still running.
          data["percent"] = [ (bytes * 100.0 / @expected_bytes).floor, 99 ].min
          remaining = @expected_bytes - bytes
          data["eta_seconds"] = (remaining / rate).round if remaining.positive? && rate.positive?
        elsif @reference_bytes
          data["reference_bytes"] = @reference_bytes
        end
        data
      end

      # "Shop · cleaned (2 of 6): 3.0 GB / ~5.0 GB · 60% · ~12 min left"
      def self.summary(data)
        size = ->(n) { ActiveSupport::NumberHelper.number_to_human_size(n.to_i) }
        text = "#{data['label']}"
        text += " (#{data['step']} of #{data['steps']})" if data["steps"].to_i > 1
        text += ": #{size.(data['bytes'])}"
        if data["expected_bytes"]
          text += " / ~#{size.(data['expected_bytes'])} · #{data['percent']}%"
          text += " · ~#{eta(data['eta_seconds'])} left" if data["eta_seconds"]
        elsif data["reference_bytes"]
          text += " written · source tables #{size.(data['reference_bytes'])} uncompressed"
        else
          text += " written"
        end
        text
      end

      def self.eta(seconds)
        seconds = seconds.to_i
        return "#{(seconds / 60.0).ceil} min" if seconds < 3600
        "#{seconds / 3600} h #{(seconds % 3600) / 60} min"
      end
    end
  end
end
