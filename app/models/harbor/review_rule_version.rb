module Harbor
  # One saved definition of a review rule. Never edited: a change is the next
  # number. `created_by_user_id` is the host's user who saved it; a host whose
  # users are records subclasses this (`config.review_rule_version_class`),
  # declares the association and says how the author reads.
  class ReviewRuleVersion < ApplicationRecord
    self.table_name = "review_rule_versions"

    belongs_to :review_rule, class_name: Harbor.class_name_for(:review_rule_class)

    # Who saved this version, as the rule's page shows it. nil: not shown.
    def author_label = nil
  end
end
