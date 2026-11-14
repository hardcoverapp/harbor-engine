module Harbor
  # The review policy at a glance: one row per risk, how it's detected, the
  # checks that mitigate it and the sign-offs it triggers, plus gaps and the
  # most recent rounds. Edited per rule on the rule's page.
  class ReviewsController < ApplicationController
    harbor_page :reviews
    helper Harbor::ReviewsHelper

    def index
      rules = Harbor.review_rule_class
      @risks    = rules.risks.order(:repo, :name)
      @checks   = rules.checks.includes(:current_version).order(:name)
      @signoffs = rules.signoffs.order(:name)
      @rounds   = Harbor::ReviewRound.order(id: :desc).limit(25)
      @every_pr = @checks.select { |c| Array(c.definition["mitigates"]).include?("*") }
    end
  end
end
