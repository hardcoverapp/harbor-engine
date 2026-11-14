module Harbor
  # One review of a pull request at one head commit. At most one is unfinished
  # per pull request, enforced by a partial unique index. Its checks are
  # review_check_runs; Harbor::Reviews::Document turns the whole thing into
  # one document.
  #
  # Harbor keeps the record and shows it. The site's own code makes a round,
  # moves it through its phases and fills in `risks`, `gaps`, `gate`,
  # `signoffs` and `review` (see README "Review policy").
  class ReviewRound < ApplicationRecord
    self.table_name = "review_rounds"

    PHASES   = %w[triage evidence gate review signoffs published cancelled failed].freeze
    FINISHED = %w[published cancelled failed].freeze

    has_many :check_runs, -> { order(:id) }, class_name: "Harbor::ReviewCheckRun", foreign_key: :review_round_id,
                                             inverse_of: :review_round, dependent: :destroy
    belongs_to :run, class_name: Harbor.class_name_for(:run_class), optional: true
    belongs_to :parent_run, class_name: Harbor.class_name_for(:run_class), optional: true

    validates :phase, inclusion: { in: PHASES }
    validates :repo, :pr_number, :head_sha, presence: true

    scope :open_rounds, -> { where.not(phase: FINISHED) }
    scope :for_pr, ->(repo, pr) { where(repo:, pr_number: pr.to_i) }

    def finished? = FINISHED.include?(phase)
    def join_key = self.class.join_key(repo, pr_number, head_sha)
    def self.join_key(repo, pr, sha) = "review:#{repo}##{pr.to_i}@#{sha}"

    def previous_rounds = self.class.for_pr(repo, pr_number).where("id < ?", id).order(:id)

    def cancel!(reason:, superseded_by: nil)
      return if finished?
      check_runs.where.not(status: Harbor::ReviewCheckRun::DONE).find_each do |cr|
        cr.update!(status: "cancelled", finished_at: Time.current)
      end
      update!(phase: "cancelled", error: reason, superseded_by_sha: superseded_by, finished_at: Time.current)
    end
  end
end
