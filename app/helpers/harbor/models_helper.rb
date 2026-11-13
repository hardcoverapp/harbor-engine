module Harbor
  module ModelsHelper
    # When a usage window resets, or that it already has and the reading is old.
    def harbor_usage_reset_label(time)
      return "Reset time unavailable" unless time
      at = time.strftime("%b %-d at %-I:%M %p %Z")
      time <= Time.current ? "Previous window ended #{at} · refresh needed" : "Resets #{at} (in #{distance_of_time_in_words(Time.current, time)})"
    end

    # A model id as a person reads it (`config.model_name`).
    def harbor_model_name(model) = Harbor.config.model_name.call(model.to_s)
  end
end
