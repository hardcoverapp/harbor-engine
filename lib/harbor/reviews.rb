module Harbor
  # Review policy: the rules a site reviews pull requests by (Harbor::ReviewRule)
  # and the record of each review (Harbor::ReviewRound and its checks). Harbor
  # keeps the records, checks what a rule says and serves the pages. It does not
  # run reviews: the site's own code decides which rules a pull request owes,
  # runs the checks and records the round.
  #
  # What a site declares, all of it optional:
  #
  #   # config/initializers/harbor.rb
  #   Harbor::Reviews.detector "risk: migration"
  #   Harbor::Reviews.finding_category "caching"
  #
  # detector          a way of spotting a risk that is the site's own code. A
  #                   risk rule may name it (`"detector": { "builtin": name }`)
  #                   instead of giving patterns; one that names a detector
  #                   the site didn't declare is refused.
  # finding_category  a kind of review finding the site records feedback
  #                   under (Harbor::ReviewFeedback, subject_kind "finding").
  #                   The dashboard lists these; with none declared it lists
  #                   every kind that has feedback.
  module Reviews
    # How a check's status reads at a glance, on the pages and wherever a
    # site prints a round.
    STATUS_ICONS = { "queued" => "⏳", "running" => "⏳", "passed" => "✅", "failed" => "❌", "errored" => "⚠️",
                     "reused" => "♻️", "skipped" => "➖", "cancelled" => "➖" }.freeze

    class << self
      def detector(name)
        detector_names << name.to_s unless detector?(name)
      end

      def detectors = detector_names.dup

      def detector?(name) = detector_names.include?(name.to_s)

      def finding_category(key)
        category_keys << key.to_s unless category_keys.include?(key.to_s)
      end

      def finding_categories = category_keys.dup

      # Tests only: forget everything declared.
      def reset!
        @detector_names = nil
        @category_keys = nil
      end

      private
        def detector_names = @detector_names ||= []
        def category_keys = @category_keys ||= []
    end
  end
end
