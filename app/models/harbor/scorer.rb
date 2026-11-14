module Harbor
  # A scorer is a judge that classifies finished agent runs against one
  # question you write ("Did the agent run the tests before opening a PR?").
  # Each classification carries a score from 0 to 1; a run passes when its
  # classification's score reaches the threshold. A share of finished runs
  # (sample_rate %) is judged automatically; any run can be judged by hand.
  #
  # Keep a scorer to one observable failure mode: its failures are what
  # proposals are drafted from, and a vague rubric makes vague proposals.
  #
  # A host extends it in a subclass named by `config.scorer_class`, as with
  # runs: the task types it offers, what a new one starts with.
  class Scorer < ApplicationRecord
    self.table_name = "scorers"

    DEFAULT_CLASSIFICATIONS = [ { "label" => "pass", "score" => 1.0 }, { "label" => "fail", "score" => 0.0 } ].freeze
    # The skill of the run a judge runs as: a child of the run it grades.
    JUDGE_SKILL = "scorer".freeze

    belongs_to :model_alias, class_name: Harbor.class_name_for(:model_alias_class), optional: false
    has_many :scorer_results, class_name: "Harbor::ScorerResult", foreign_key: :scorer_id, dependent: :destroy, inverse_of: :scorer

    validates :name, presence: true, uniqueness: true
    validates :judge_instructions, presence: true
    validates :pass_threshold, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
    validates :sample_rate, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
    validates :improvement_min_failures, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 50 }
    validates :improvement_max_age_days, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 90 }
    validate :validate_classifications

    scope :enabled, -> { where(enabled: true) }
    scope :ordered, -> { order(:position, :name) }

    # The task types a scorer can be narrowed to: the declared ones. A host
    # whose runs carry others adds them in its subclass.
    def self.task_types = Harbor::TaskTypes.keys

    # What the New scorer form starts with. A host with a model alias it
    # judges with by default sets it in its subclass.
    def self.draft = new(classifications: DEFAULT_CLASSIFICATIONS, sample_rate: 0, pass_threshold: 1.0)

    # The enabled scorers whose filters match this run (the Score now list
    # and the POST agree because both ask here).
    def self.applicable_to(run) = enabled.ordered.select { |s| s.applies_to?(run) }

    def labels = classifications.map { |c| c["label"].to_s }

    def score_for(label)
      classifications.find { |c| c["label"].to_s.casecmp?(label.to_s) }&.dig("score")&.to_f
    end

    # Does this scorer judge runs like this one? Empty lists mean "any".
    def applies_to?(run)
      (agent_keys.blank? || agent_keys.include?(run.agent_key)) &&
        (task_types.blank? || task_types.include?(run.task_type))
    end

    def sampled?(rng: Kernel) = sample_rate.positive? && rng.rand(100) < sample_rate

    def scored_results = scorer_results.where(status: "ok")

    # Share of judged runs that passed, over the range; nil with nothing judged.
    def pass_rate(since:)
      rows = scored_results.where("scored_at >= ?", since)
      total = rows.count
      return nil if total.zero?
      (100.0 * rows.where(passed: true).count / total).round
    end

    # [[week_start_date, pass %]] for the weeks in range (0 where nothing judged).
    def weekly_pass_series(since:, now: Time.current)
      rows   = scored_results.where("scored_at >= ?", since)
      total  = rows.group(Arel.sql("DATE_TRUNC('week', scored_at)")).count.transform_keys(&:to_date)
      passed = rows.where(passed: true).group(Arel.sql("DATE_TRUNC('week', scored_at)")).count.transform_keys(&:to_date)
      first = since.to_date.beginning_of_week
      last  = now.to_date.beginning_of_week
      (0..).lazy.map { |i| first + (7 * i) }.take_while { |d| d <= last }
           .map { |w| [ w, total[w].to_i.zero? ? 0 : (100.0 * passed[w].to_i / total[w]).round ] }.to_a
    end

    # "label=score" lines from the form → classifications.
    def self.parse_classifications(text)
      rows = text.to_s.lines.map(&:strip).reject(&:empty?).map do |line|
        label, score = line.split("=", 2).map(&:strip)
        raise ArgumentError, "#{line.inspect} isn't label=score" if label.blank? || score.blank?
        { "label" => label, "score" => Float(score) }
      end
      raise ArgumentError, "Give at least one classification (label=score per line)." if rows.empty?
      rows
    rescue ArgumentError => e
      raise ArgumentError, e.message.start_with?("invalid value") ? "Scores must be numbers between 0 and 1." : e.message
    end

    def classifications_text = classifications.map { |c| "#{c['label']}=#{c['score']}" }.join("\n")

    private

    def validate_classifications
      unless classifications.is_a?(Array) && classifications.any? && classifications.all? { |c| c.is_a?(Hash) && c["label"].present? }
        return errors.add(:classifications, "need at least one label with a score")
      end
      scores = classifications.map { |c| c["score"] }
      errors.add(:classifications, "scores must be between 0 and 1") unless scores.all? { |s| s.is_a?(Numeric) && s.between?(0, 1) }
      errors.add(:classifications, "labels must be unique") if labels.map(&:downcase).uniq.size != labels.size
    end
  end
end
