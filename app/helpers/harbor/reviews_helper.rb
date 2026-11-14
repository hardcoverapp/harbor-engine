module Harbor
  # What the Review policy pages need to draw rules, checks and the places a
  # host can fill.
  module ReviewsHelper
    MODE_PILL = { "live" => "bg-pale-green text-ink-green", "shadow" => "bg-pale-purple text-ink-purple",
                  "off" => "bg-hairline text-soft" }.freeze

    # Whether the host has a partial of its own for a place on these pages
    # (app/views/harbor/reviews/_<name>.html.erb in the host).
    def harbor_reviews_partial?(name) = lookup_context.exists?("harbor/reviews/#{name}", [], true)

    def harbor_review_mode_pill(mode) = content_tag(:span, mode, class: "pill #{MODE_PILL.fetch(mode.to_s, 'bg-hairline text-soft')}")

    def harbor_review_status_icon(status) = Harbor::Reviews::STATUS_ICONS.fetch(status.to_s, "·")

    # A condition in words; a shortcut ("exit_zero") reads as itself.
    def harbor_review_condition(cond)
      return cond if cond.is_a?(String)
      Harbor::Reviews::Condition.describe(cond)
    end

    # A pull request by name, linked when the host says where pull requests
    # are (`config.review_pull_request_url`).
    def harbor_review_pull_request(label, repo, number, **options)
      url = Harbor.config.review_pull_request_url&.call(repo, number)
      url.present? ? link_to(label, url, **options) : label
    end

    # Whether this rule can be previewed: the host has a preview, and the
    # rule is one whose matching can be tried without running anything.
    def harbor_review_preview?(rule) = Harbor::ReviewRulesController.previewable?(rule)
  end
end
