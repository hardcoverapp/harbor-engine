module Harbor
  # The short hand-written "what happens here" paragraph for one stage of
  # Overview (Harbor::Overview.stage). Everything else on that page is read
  # from live configuration. Edited in place on the page; every save is also
  # handed to the host to keep outside the database (`config.export`).
  class StageNote < ApplicationRecord
    self.table_name = "factory_notes"

    EXPORT_DIR = "factory/notes".freeze

    # Who last saved it, when the host has told Harbor its user class.
    if Harbor.config.user_class
      belongs_to :updated_by_user, class_name: Harbor.class_name_for(:user_class), optional: true
    end

    validates :stage_key, presence: true, uniqueness: true
    validate :stage_is_known

    after_save_commit :export

    def self.for_stages = all.index_by(&:stage_key)

    # The host's user who last saved it, as the host names its users; nil
    # when there is no user class or nobody is recorded.
    def editor_label
      user = Harbor.config.user_class && updated_by_user
      user && Harbor.config.user_label.call(user)
    end

    def export_path = File.join(EXPORT_DIR, "#{stage_key}.md")

    # The note as a markdown file with what it is and who saved it on top.
    def export_body
      meta = { "stage" => stage_key, "updated_at" => updated_at&.iso8601, "updated_by" => editor_label }.compact
      "---\n#{YAML.dump(meta).sub(/\A---\s*\n/, '')}---\n\n#{body.to_s.strip}\n"
    end

    # A failure is logged and never fails the save.
    def export
      hook = Harbor.config.export or return
      hook.call(export_path, export_body)
    rescue => e
      Rails.logger.error("[harbor] export of the #{stage_key} stage note failed: #{e.class}: #{e.message}")
    end

    private
      def stage_is_known
        errors.add(:stage_key, "is not a stage of Overview") unless Harbor::Overview.find_stage(stage_key)
      end
  end
end
