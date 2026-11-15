require "active_support"
require "active_support/core_ext/integer/time"
require "active_support/core_ext/numeric/time"

module Harbor
  # Overview: the section's front page. What is set up and how it has been
  # doing, read from the records each time it is drawn, so it can't fall
  # behind them: the numbers at a glance, who does each kind of work, what
  # runs it, how long it takes and what it costs, and what changed lately.
  # Only the short note on each stage is written by hand (Harbor::StageNote).
  #
  # With nothing declared a site has one stage holding everything. A site
  # that knows the order its work moves in declares its stages, and anything
  # else below, in an initializer. All of it is optional:
  #
  #   # config/initializers/harbor.rb
  #   Harbor::Overview.stage "triage", title: "Triage", summary: "A ticket is read and given to someone.",
  #     task_types: %w[ticket_triage], automations: %w[ticket-sweep], claims: %w[triage],
  #     starts_on: ->(trigger) { trigger["kind"] == "ticket" }
  #
  #   Harbor::Overview.part(:checks, "Checks") { |stage, snapshot| [ Harbor::Overview::Item.new(label: "Spelling") ] }
  #   Harbor::Overview.way_in "desk", title: "The help desk", body: "A ticket opened there.", stage: "triage"
  #   Harbor::Overview.steer "hold", want: "Pause it", action: "add the `hold` label", result: "work stops", stage: "triage"
  #   Harbor::Overview.change_source(:prices, "Price list") { |since:, limit:| [ Harbor::Overview::Change.new(…) ] }
  #   Harbor::Overview.tile(:tickets, label: "Tickets", after: :runs) { |since| { value: 12, note: "open" } }
  #   Harbor::Overview.section :costs, partial: "overview/costs", after: :lifecycle
  #   Harbor::Overview.hide_section :summary
  #
  # stage          a step work passes through, in the order declared. It
  #                holds the task types named, the automations named (by
  #                key), the workflows that claim one of `claims`, the
  #                workflows and automations one of whose triggers
  #                `starts_on` says yes to, and the workflows whose first
  #                agent step does one of its task types.
  # part           more lines under a stage's "What it runs": the block is
  #                given (stage, snapshot) and returns Items.
  # way_in         a way work arrives, in the "Ways in" section.
  # steer          something a person can do and what it causes: a row of
  #                "How to steer", and of its stage's "Where people come in".
  # change_source  another source for "What changed"; naming one of Harbor's
  #                replaces it where it is.
  # tile           another number in "At a glance".
  # section        a section of the host's own: a partial, placed before or
  #                after one of the page's. hide_section leaves one of
  #                Harbor's out.
  module Overview
    # How far back "At a glance" and each stage's timings look.
    WINDOW = 30.days

    Stage = Struct.new(:key, :title, :summary, :task_types, :claims, :automations, :starts_on, :everything, keyword_init: true) do
      def anchor = "stage-#{key}"

      # Whether something started by this trigger (a workflow's trigger, or
      # what an automation says starts it) belongs here.
      def starts_on?(trigger) = starts_on ? !!starts_on.call(trigger) : false
    end

    # One line under "What it runs": a thing, where it is edited and its state.
    Item = Struct.new(:label, :detail, :mode, :url, keyword_init: true)
    Part = Struct.new(:name, :title, :block, keyword_init: true)
    Steer = Struct.new(:key, :want, :action, :result, :stage, keyword_init: true)
    WayIn = Struct.new(:key, :title, :body, :stage, :task_type, keyword_init: true)
    Change = Struct.new(:at, :source, :title, :detail, :who, :url, keyword_init: true)
    Source = Struct.new(:name, :label, :block, keyword_init: true)
    Tile = Struct.new(:key, :label, :value, :note, :url, :after, :block, keyword_init: true)
    Section = Struct.new(:key, :partial, keyword_init: true)

    # The stage of a site that declared none: all of it, in one place.
    EVERYTHING = Stage.new(key: "work", title: "Work", everything: true, task_types: [], claims: [], automations: [],
                           summary: "Every kind of work set up here, who does it, what runs it and how it has been going.").freeze

    # Harbor's sections, in the order they are drawn.
    SECTIONS = %w[summary ways_in lifecycle steering changes].freeze

    class << self
      def stage(key, title:, summary: nil, task_types: [], claims: [], automations: [], starts_on: nil)
        declared[key.to_s] = Stage.new(key: key.to_s, title:, summary:, task_types: Array(task_types).map(&:to_s),
                                       claims: Array(claims).map(&:to_s), automations: Array(automations).map(&:to_s),
                                       starts_on:, everything: false)
      end

      # The declared stages, in order; the one that holds everything when
      # none is declared.
      def stages = declared.empty? ? [ EVERYTHING ] : declared.values

      def stages_declared? = declared.any?

      def find_stage(key) = stages.find { |stage| stage.key == key.to_s }

      # The stage that lists a task type.
      def stage_for_task(task_type)
        stages.find { |stage| stage.everything || stage.task_types.include?(task_type.to_s) }
      end

      def part(name, title = name.to_s.humanize, &block)
        part_list[name.to_sym] = Part.new(name: name.to_sym, title:, block:)
      end

      def parts = part_list.values

      def remove_part(name) = part_list.delete(name.to_sym)

      def steer(key, want:, action:, result:, stage:)
        steer_list[key.to_s] = Steer.new(key: key.to_s, want:, action:, result:, stage: stage.to_s)
      end

      def steering = steer_list.values

      def steering_for(stage_key) = steering.select { |row| row.stage == stage_key.to_s }

      def remove_steer(key) = steer_list.delete(key.to_s)

      def way_in(key, title:, body:, stage:, task_type: nil)
        way_in_list[key.to_s] = WayIn.new(key: key.to_s, title:, body:, stage: stage.to_s, task_type: task_type&.to_s)
      end

      def ways_in = way_in_list.values

      def change_source(name, label = name.to_s.humanize, &block)
        source_list[name.to_sym] = Source.new(name: name.to_sym, label:, block:)
      end

      def change_sources = source_list.dup

      def remove_change_source(name) = source_list.delete(name.to_sym)

      # The block is given the time "At a glance" looks back to and returns
      # { value:, note:, url: } (note and url optional).
      def tile(key, label:, after: nil, &block)
        tile_list[key.to_sym] = Tile.new(key: key.to_sym, label:, after: after&.to_sym, block:)
      end

      def tiles = tile_list.values

      def section(key, partial:, before: nil, after: nil)
        raise ArgumentError, "give before: or after:, not both" if before && after
        anchor = (before || after)&.to_s
        list = section_list
        list.reject! { |section| section.key == key.to_s }
        index = anchor && (list.index { |section| section.key == anchor } or raise ArgumentError, "no Overview section named #{anchor}")
        list.insert(index ? (after ? index + 1 : index) : list.size, Section.new(key: key.to_s, partial:))
      end

      def hide_section(key) = section_list.reject! { |section| section.key == key.to_s }

      def sections = section_list.dup

      # Tests only: what is declared, to put back afterwards.
      def snapshot
        { declared: declared.dup, part_list: part_list.dup, steer_list: steer_list.dup, way_in_list: way_in_list.dup,
          source_list: source_list.dup, tile_list: tile_list.dup, section_list: section_list.dup }
      end

      def restore!(snapshot) = snapshot.each { |name, value| instance_variable_set(:"@#{name}", value.dup) }

      # Tests only: forget everything declared.
      def reset!
        %i[declared part_list steer_list way_in_list source_list tile_list section_list].each { |name| instance_variable_set(:"@#{name}", nil) }
      end

      private
        def declared = @declared ||= {}
        def part_list = @part_list ||= {}
        def steer_list = @steer_list ||= {}
        def way_in_list = @way_in_list ||= {}
        def source_list = @source_list ||= {}
        def tile_list = @tile_list ||= {}
        def section_list = @section_list ||= SECTIONS.map { |key| Section.new(key:, partial: "harbor/overview/#{key}") }
    end
  end
end
