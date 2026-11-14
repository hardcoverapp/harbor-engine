module Harbor
  # Workflows: site-defined trigger → step graphs. A workflow is a definition
  # with versions (Harbor::Workflow); a firing of one is a Harbor::WorkflowRun
  # that the engine (Harbor::Workflows::Engine) walks step by step, each step
  # that does work a tracked Run.
  #
  # Everything a workflow can be built from is registered here, once: the
  # step types (with the object that runs each), the triggers, the data a
  # step can read, the workflow settings and the flows a live workflow can
  # take over. The definition's validation, the engine, the builder's palette
  # and forms and the reference page all read this one list, so they cannot
  # drift. Harbor registers the types that need no host
  # (lib/harbor/workflows/defaults.rb); a host registers its own, and may
  # replace or remove Harbor's:
  #
  #   Harbor::Workflows.register_step "action", action: "chat.post",
  #     label: "Post to chat", group: "Chat", icon: "message", color: "#4A154B",
  #     description: "Posts a message to the team's channel.",
  #     fields: [ { name: "body", label: "Message", kind: "textarea", required: true } ],
  #     outputs: [ [ "url", "string", "link to the message" ] ],
  #     runner: "Chat::PostStep"
  #
  #   Harbor::Workflows.update_step "call", defaults: { "input" => { "ticket" => "{{trigger.ticket}}" } }
  #   Harbor::Workflows.remove_step "action:note"
  #
  # A runner answers `start(engine, step, step_run, input)`: it finishes the
  # step run and returns :done, or leaves it pending and returns :blocked,
  # and whatever finishes it later calls `Harbor::Workflows.advance_later`.
  # It is named as a string and looked up when used, so registering in an
  # initializer loads nothing early. For the same reason anything read from
  # the database or from the host's classes (a select's options, a default)
  # may be given as a callable, which is called each time it is needed.
  module Workflows
    class Unknown < KeyError; end

    # One step type. `id` is its type, or "action:<name>" for one of the
    # actions (steps of type "action" told apart by their `action`).
    StepType = Struct.new(:type, :action, :label, :group, :icon, :color, :description, :fields, :outputs, :defaults,
                          :runner, :gate, :gate_note, :dynamic_outputs, :structural, :side_effect, :working,
                          :dry_run_stop, :inside_loop, :makes_workspace, :validate, :summary, :short, :pill,
                          keyword_init: true) do
      def id = action ? "#{type}:#{action}" : type

      def runner_object
        raise ArgumentError, "the #{id} step has nothing that runs it" if runner.blank?
        runner.is_a?(String) ? runner.constantize : runner
      end

      # What the builder and the reference page are given.
      def to_module
        { type:, action:, label: Workflows.value(label), group:, icon:, color:, description: Workflows.value(description),
          fields: Workflows.value(fields), outputs: Workflows.value(outputs), defaults: Workflows.value(defaults),
          gate: (true if gate), dynamic_outputs:, inside_loop: (false unless inside_loop),
          makes_workspace: (true if makes_workspace) }.compact
      end
    end

    Trigger = Struct.new(:kind, :label, :group, :icon, :color, :description, :fields, :soon, :defaults, :summary_fields,
                         :summary_empty, :validate, :summary, :matches, keyword_init: true) do
      def id = kind

      def to_catalog
        { kind:, label:, group:, icon:, color:, description:, soon: (true if soon), fields: Workflows.value(fields),
          defaults: Workflows.value(defaults).presence, summary_fields:, summary_empty: }.compact
      end
    end

    DataField = Struct.new(:name, :type, :description) do
      def id = name
    end

    Setting = Struct.new(:name, :label, :kind, :options, :help, keyword_init: true) do
      def id = name

      def to_field = { name:, label:, kind:, options: Workflows.value(options), help: }.compact
    end

    class << self
      # --- step types ---

      #   type, action:     "agent"; or "action" with action: "chat.post"
      #   label, group, icon, color, description   how the builder shows it
      #   fields            what its form edits: [{ name:, label:, kind:, … }]
      #   outputs           what later steps can read: [[name, type, note]]
      #   defaults          what a new step of this type starts with
      #   runner            what runs it (see above); none for the structural
      #                     types the engine walks itself
      #   gate:, gate_note: it decides what runs; the note ({ where:, reads:,
      #                     does: }) is its row in the reference's Gates table
      #   dynamic_outputs:  the field naming outputs the step's author lists
      #   side_effect:      false for a step that acts on nothing outside the
      #                     run: it runs in a dry run too (default: recorded,
      #                     not run)
      #   working:          true when a run is "running", not "waiting", while
      #                     this step is pending
      #   dry_run_stop:     a dry run ends at this step; the text finishes
      #                     "Dry run: stopped at <step>, …"
      #   inside_loop:      false when it can't sit inside a loop
      #   makes_workspace:  true for a step later steps name in a field of
      #                     kind "workspace"
      #   validate:         ->(step, label) { [ "#{label}: what is wrong" ] }
      #   summary:          ->(step) { one line under its name in a step list }
      #   short:, pill:     its pill in a step list: the word and CSS classes
      #   before:, after:   the id of an entry to sit next to; else it goes
      #                     last. Registering an id again replaces that entry
      #                     where it is.
      def register_step(type, action: nil, before: nil, after: nil, **options)
        entry = StepType.new({ fields: [], outputs: [], defaults: {}, inside_loop: true, side_effect: true }
                             .merge(options).merge(type: type.to_s, action: action&.to_s))
        place(steps, entry, before:, after:)
      end

      # Change some of what an entry says, leaving the rest and its place:
      # update_step "call", defaults: { "input" => { "ticket" => "{{run.id}}" } }
      def update_step(id, **changes) = steps[steps.index(step(id))] = rewritten(step(id), changes)

      def remove_step(id) = steps.reject! { |entry| entry.id == id.to_s }

      def step_entries = steps.dup

      # The step types a definition may use, in the order registered.
      def step_types = steps.map(&:type).uniq

      def actions = steps.filter_map(&:action)

      # The entry for a step of a definition (by its type, and its action
      # when it is one), or nil.
      def step_for(step)
        type = step["type"].to_s
        steps.find { |entry| entry.type == type && (entry.action.nil? || entry.action == step["action"]) }
      end

      def step(id) = steps.find { |entry| entry.id == id.to_s } || raise(Unknown, "no workflow step registered as #{id}")

      def types_where(flag) = steps.select { |entry| entry.public_send(flag) }.map(&:type).uniq

      # --- triggers ---

      #   fields, defaults  as for a step
      #   soon:             offered, but can't be chosen yet
      #   summary_fields:, summary_empty:   what the builder writes under the
      #                     trigger's bubble: these fields' values, or the text
      #   validate:         ->(trigger, label) { [ errors ] }
      #   summary:          ->(trigger) { how a list says it }
      #   matches:          ->(trigger, event, data) { does a stored delivery,
      #                     with the trigger data made from it, start this? }
      def register_trigger(kind, before: nil, after: nil, **options)
        entry = Trigger.new({ fields: [], defaults: {} }.merge(options).merge(kind: kind.to_s))
        place(triggers, entry, before:, after:)
      end

      def update_trigger(kind, **changes)
        entry = trigger(kind) or raise Unknown, "no workflow trigger registered as #{kind}"
        triggers[triggers.index(entry)] = rewritten(entry, changes)
      end

      def remove_trigger(kind) = triggers.reject! { |entry| entry.kind == kind.to_s }

      def trigger_entries = triggers.dup

      def trigger_kinds = triggers.map(&:kind)

      def trigger(kind) = triggers.find { |entry| entry.kind == kind.to_s }

      # Whether a trigger of a definition matches a stored delivery, given
      # the trigger data made from it. False for a kind with no matcher.
      def trigger_matches?(trigger, event, data)
        self.trigger(trigger["kind"])&.matches&.call(trigger, event, data) ? true : false
      end

      # --- data a step can read ---

      # One field of `trigger.*` or `run.*`, for the builder's data picker
      # and the reference: register_data :trigger, "sender", "string", "who".
      def register_data(scope, name, type, description = "", before: nil, after: nil)
        list = data_lists.fetch(scope.to_sym) { raise ArgumentError, "data is registered for :trigger or :run, not #{scope.inspect}" }
        entry = DataField.new(name.to_s, type.to_s, description.to_s)
        place(list, entry, before:, after:)
      end

      def data(scope) = data_lists.fetch(scope.to_sym).map(&:to_a)

      # --- settings of a workflow, edited in the builder's settings panel ---

      def register_setting(name, before: nil, after: nil, **options)
        place(settings, Setting.new(options.merge(name: name.to_s)), before:, after:)
      end

      def setting_entries = settings.dup

      # --- checks of a whole definition ---

      # Called with a Harbor::Workflows::Definition; returns the messages of
      # what is wrong with it. For rules that span steps.
      def register_validator(callable = nil, &block) = validators << (callable || block)

      def validator_entries = validators.dup

      # --- flows a live workflow takes over ---

      # A flow the host runs in code that a live workflow can take over: the
      # workflow lists it in `claims`, and the host's code steps aside for
      # it. Harbor only records and shows the claim.
      def register_claim(key, label) = claims[key.to_s] = label.to_s

      def claimable = claims.dup

      # --- running ---

      # The master switch (the "Workflows" setting). Off: nothing starts on
      # its own, every run is a dry run, and the pages still work.
      def enabled? = Harbor::Setting.get(:workflows_enabled)

      # Start a run of `workflow` (Harbor::Workflows::Starter has the options).
      # Returns the run, or nil when it wasn't started.
      def start!(workflow, **options) = Harbor::Workflows::Starter.call(workflow, **options)

      # Move a run forward once whatever a step was waiting for has happened.
      def advance_later(workflow_run_id) = Harbor::Workflows::AdvanceJob.perform_later(workflow_run_id)

      # Parked steps past their expiry finish as timed out. A host with steps
      # that wait calls this on a schedule.
      def sweep_waits!(now = Time.current)
        return unless enabled?
        Harbor::WorkflowWait.expired(now).includes(:workflow_step_run).find_each do |wait|
          step_run = wait.workflow_step_run
          step_run.finish!(status: "ok", output: { "timed_out" => true }) if step_run.pending?
          wait.destroy!
          advance_later(wait.workflow_run_id)
        end
      end

      # A value, or what a callable gives now.
      def value(object) = object.respond_to?(:call) ? object.call : object

      # Tests only: what is registered, to put back with `restore!`.
      def snapshot
        { steps: steps.dup, triggers: triggers.dup, settings: settings.dup, validators: validators.dup, claims: claims.dup,
          data: data_lists.transform_values(&:dup) }
      end

      def restore!(snapshot)
        @steps, @triggers, @settings, @validators, @claims = snapshot.values_at(:steps, :triggers, :settings, :validators, :claims).map(&:dup)
        @data_lists = snapshot[:data].transform_values(&:dup)
      end

      private
        def steps = (@steps ||= [])
        def triggers = (@triggers ||= [])
        def settings = (@settings ||= [])
        def validators = (@validators ||= [])
        def claims = (@claims ||= {})
        def data_lists = (@data_lists ||= { trigger: [], run: [] })

        def rewritten(entry, changes) = entry.class.new(**entry.to_h.merge(changes))

        # Put an entry in a list: where the entry with its id already is, or
        # beside the one named, or last.
        def place(list, entry, before: nil, after: nil)
          raise ArgumentError, "give before: or after:, not both" if before && after

          existing = list.index { |other| other.id == entry.id }
          return list[existing] = entry if existing

          anchor = before || after
          return list << entry unless anchor

          index = list.index { |other| other.id == anchor.to_s } or raise Unknown, "nothing is registered as #{anchor}"
          list.insert(before ? index : index + 1, entry)
          entry
        end
    end
  end
end

require "harbor/workflows/defaults"
