module Harbor
  # What the Automations pages need to draw the places a host can fill.
  module AutomationsHelper
    # Whether the host has a partial of its own for a place on these pages
    # (app/views/harbor/automations/_<name>.html.erb in the host).
    def harbor_automations_partial?(name) = lookup_context.exists?("harbor/automations/#{name}", [], true)

    # The words under one of the form's fields: the host's, when its `_hint`
    # partial has any for that field, else Harbor's (the block).
    def harbor_automation_hint(field, automation, &default)
      if harbor_automations_partial?("hint")
        words = render("harbor/automations/hint", field: field, automation: automation)
        return words if words.present?
      end
      capture(&default)
    end

    # The triggers the host declared that the form offers this automation.
    def harbor_automation_triggers(automation)
      Harbor::Automations.triggers.select { |trigger| trigger.kinds.include?(automation.kind) }
    end

    # The zone crons are read in ("America/Denver"), or nil when it can't be named.
    def harbor_schedule_zone = Harbor.automation_class.schedule_zone
  end
end
