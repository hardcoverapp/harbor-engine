module Harbor
  # Every inbound webhook delivery, whether or not anything was started for it:
  # one place to see what came in, what was done with it, and the run that
  # resulted. A host extends it in a subclass named by
  # `config.webhook_event_class`, as with runs.
  class WebhookEvent < ApplicationRecord
    self.table_name = "webhook_events"

    STATUSES = %w[received dispatched ignored error].freeze

    belongs_to :run, class_name: Harbor.class_name_for(:run_class), optional: true

    validates :status, inclusion: { in: STATUSES }

    scope :recent, -> { order(received_at: :desc, id: :desc) }

    # What the Webhooks page lists. A host with more to show per delivery
    # overrides this to load it in the same query.
    def self.for_page = recent.includes(:run)

    # "pull_request.review_requested"
    def label = [ event, action ].compact_blank.join(".")

    # One line saying what the delivery was about, for the event shapes known
    # (GitHub's). nil for anything else.
    def subject
      case event
      when "pull_request"
        pr = payload["pull_request"] || {}
        "PR ##{pr['number']} · #{pr['title']}" if pr["number"]
      when "pull_request_review"
        pr = payload["pull_request"] || {}
        state = payload.dig("review", "state").to_s
        by = payload.dig("review", "user", "login").to_s
        "PR ##{pr['number']} · #{state.tr('_', ' ')} by #{by}" if pr["number"]
      when "check_suite"
        suite = payload["check_suite"] || {}
        number = Array(suite["pull_requests"]).first&.dig("number")
        conclusion = suite["conclusion"].to_s
        number.present? ? "PR ##{number} · CI #{conclusion}" : "CI #{conclusion} on #{suite['head_branch']}"
      when "issues"
        issue = payload["issue"] || {}
        "Issue ##{issue['number']} · #{issue['title']}" if issue["number"]
      when "push"
        sha = payload["after"].to_s.first(7)
        message = payload.dig("head_commit", "message").to_s.lines.first.to_s.strip
        [ "#{payload['ref'].to_s.delete_prefix('refs/heads/')} @ #{sha}", message.presence ].compact.join(" · ") if sha.present?
      end
    end

    # Where the thing the delivery was about lives, when the payload says.
    def external_url
      case event
      when "pull_request" then payload.dig("pull_request", "html_url")
      when "pull_request_review" then payload.dig("review", "html_url") || payload.dig("pull_request", "html_url")
      when "check_suite"
        suite = payload["check_suite"] || {}
        Array(suite["pull_requests"]).first&.dig("html_url") || suite["html_url"]
      when "issues" then payload.dig("issue", "html_url")
      when "push" then payload["compare"]
      end
    end
  end
end
