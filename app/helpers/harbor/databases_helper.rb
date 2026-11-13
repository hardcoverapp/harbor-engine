module Harbor
  module DatabasesHelper
    # What each kind of backup is for, with the icon and colour it carries on
    # the Databases page so the three are told apart at a glance.
    BACKUP_KINDS = {
      "full" => { label: "Full", tone: "bg-pale-blue text-ink-blue",
                  about: "Everything, for disaster recovery. Restored only where the config file names it; never given to developers.",
                  # a shield
                  icon: '<path d="M12 3 5 6v5c0 4.5 3 8.3 7 10 4-1.7 7-5.5 7-10V6l-7-3z"/><path d="m9 12 2 2 4-4"/>' },
      "cleaned" => { label: "Cleaned", tone: "bg-pale-green text-ink-green",
                     about: "Masked, for developers' laptops.",
                     # sparkles
                     icon: '<path d="M12 3v4M12 17v4M3 12h4M17 12h4M6 6l2.5 2.5M15.5 15.5 18 18M18 6l-2.5 2.5M8.5 15.5 6 18"/>' },
      "staging" => { label: "Staging", tone: "bg-pale-purple text-ink-purple",
                     about: "Masked with the staging rules, which may keep more than cleaned does. Refreshes staging.",
                     # a flask
                     icon: '<path d="M9 3h6M10 3v6l-5 9a2 2 0 0 0 1.8 3h10.4a2 2 0 0 0 1.8-3l-5-9V3"/><path d="M7.5 15h9"/>' }
    }.freeze

    # A site's masking rules decide what a kind really holds, so it may word
    # the purpose itself (`config.backup_kind_notes`).
    def backup_kind(kind)
      info = BACKUP_KINDS.fetch(kind.to_s) { { label: kind.to_s.titleize, tone: "bg-bone text-soft", about: "", icon: "" } }
      note = Harbor.config.backup_kind_notes.to_h.stringify_keys[kind.to_s]
      note.present? ? info.merge(about: note) : info
    end

    # The kind as a chip: icon and name, its purpose on hover.
    def backup_kind_chip(kind)
      info = backup_kind(kind)
      svg = content_tag(:svg, info[:icon].html_safe, viewBox: "0 0 24 24", width: 14, height: 14, fill: "none", stroke: "currentColor",
                              "stroke-width": 2, "stroke-linecap": "round", "stroke-linejoin": "round", "aria-hidden": true)
      content_tag(:span, svg + info[:label], title: info[:about], data: { backup_kind: kind },
                         class: "inline-flex items-center gap-1.5 rounded-full px-2 py-0.5 text-xs font-medium whitespace-nowrap #{info[:tone]}")
    end

    # Whether a backup has a copy somewhere: ✅ there, ❌ expected and missing,
    # a dash when that kind is not kept there at all.
    def backup_copy_mark(state, where:, name:)
      emoji, label = case state
      when :present then [ "✅", "On #{name}" ]
      when :missing then [ "❌", "Missing from #{name}" ]
      else [ "–", "Not kept on #{name}" ]
      end
      content_tag(:span, emoji, role: "img", title: label, aria: { label: label }, data: { copy: where, state: state },
                                class: (state == :none ? "text-faint" : "text-xs"))
    end

    # Where a backup stands off the drive: in a bucket, expected in one and not
    # there, or of a kind no bucket is configured for.
    def backup_cloud_state(backup, bucket_configured:)
      return :present if backup.copies.except(Harbor::DatabaseBackup::LOCAL).any?
      bucket_configured ? :missing : :none
    end

    # Why a backup's row offers no restore, for the dash's hover text.
    def restore_never_title(backup, entries)
      return "No restore environment takes this database" if entries.empty?
      where = entries.map { |entry| entry.environment.key }.to_sentence
      backup.masked? ? "#{backup.variant.upcase_first} backups are not what #{where} restores" : "Full backups are never restored to #{where}"
    end

    # A restore's target as the page may show it: user@host:port/database,
    # never the password; and why the restore would be refused, if it would.
    def restore_target_shown(entry)
      return {} unless entry.configured?
      { target: entry.target.redacted, refusal: entry.refusal }
    rescue Harbor::DbOps::Target::Error => error
      { refusal: Harbor::DbOps::Target.scrub(error.message) }
    end

    # When a scheduled operation next runs, as the page shows it.
    def backup_schedule_time(time) = time ? time.in_time_zone.strftime("%b %-d, %-I:%M %p %Z") : "Not scheduled"
  end
end
