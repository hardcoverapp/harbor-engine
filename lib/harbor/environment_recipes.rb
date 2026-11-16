require "shellwords"

module Harbor
  # The recipes that make a machine for one run and remove it afterwards,
  # declared in the host's config file (Harbor::ConfigFile):
  #
  #   environment_recipes:
  #     aws-sandbox:
  #       name: AWS sandbox
  #       create: ./scripts/orca-vm/aws-create.sh
  #       destroy: ./scripts/orca-vm/aws-destroy.sh
  #       timeout_seconds: { create: 1800, destroy: 120 }
  #
  # A recipe is Orca's own "per-workspace environment recipe" (the
  # `environmentRecipes` of a repository's `orca.yaml`): the same keys with
  # the same meanings, and scripts written to Orca's contract, so one recipe
  # serves both. Harbor runs the scripts itself (Harbor::Machines), because
  # Orca's command line can't be asked to. What differs from `orca.yaml`:
  #
  #   - recipes are a mapping keyed by id, not a list with `id:` (the config
  #     file refuses a key that appears twice);
  #   - `timeout_seconds`, though `timeoutSeconds` is read too;
  #   - a mistake is an error that stops the recipe being used, where Orca
  #     reports a bad timeout and carries on without one;
  #   - a step with no timeout of its own gets one from Settings, where Orca
  #     lets it run for ever;
  #   - `suspend` and `resume` are read and checked but not run yet, and
  #     `checkoutMode: provisioned-root` is refused (it needs SSH mode).
  #
  # Commands are run by `sh -c` from the host app's root, as Orca runs them
  # from the repository's. They are only ever read from the file: nothing on a
  # page can change what is run.
  module EnvironmentRecipes
    Error = Class.new(StandardError)

    SECTION = "environment_recipes".freeze
    STEPS = %w[create suspend resume destroy].freeze
    KEYS = %w[name create suspend resume destroy timeout_seconds timeoutSeconds command cleanup checkout_mode checkoutMode].freeze
    ID = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
    # `destroy: none` says the recipe makes nothing that needs removing.
    NONE = "none".freeze
    TIMEOUTS = (1..86_400)

    Recipe = Struct.new(:id, :name, :create, :suspend, :resume, :destroy, :timeouts, keyword_init: true) do
      # Nothing is run to remove what `create` made (`destroy: none`).
      def destroy_disabled? = destroy.nil?

      def command(step) = public_send(step)

      # The step's own time limit in seconds, or nil when the recipe gives none.
      def timeout(step) = timeouts[step.to_s]

      # What is wrong with the recipe's scripts as they are on disk now: a
      # command whose first word is a path must be a file that can be run.
      def script_problems(root: EnvironmentRecipes.root)
        STEPS.filter_map do |step|
          line = command(step) or next
          word = (Shellwords.split(line).first rescue nil)
          next "#{step}: #{line.inspect} can't be read as a command" if word.blank?
          next unless word.include?("/")
          file = File.expand_path(word, root)
          if !File.file?(file) then "#{step}: #{word} is not there"
          elsif !File.executable?(file) then "#{step}: #{word} is not executable (chmod +x)"
          end
        end
      end
    end

    class << self
      # Where commands run from, and what their paths are relative to.
      def root = Rails.root.to_s

      # Every declared recipe. Raises Error, naming the file and the entry,
      # when the section can't be used.
      def all
        sections = ConfigFile.sections
        cached = @cache
        return cached.last if cached && cached.first.equal?(sections)
        recipes = read(ConfigFile.section(SECTION))
        @cache = [ sections, recipes ]
        recipes
      rescue ConfigFile::Error => error
        raise Error, error.message
      end

      def find(id) = all.find { |recipe| recipe.id == id.to_s }

      def any? = all.any?

      # What is wrong with the declarations, as sentences ([] when nothing).
      def problems
        all
        []
      rescue Error => error
        [ error.message ]
      end

      # Tests only.
      def reset! = @cache = nil

      private

      def read(section)
        section.map do |id, options|
          id = id.to_s
          at(id) do
            raise Error, "a recipe's id uses letters, numbers, dots, dashes and underscores" unless id.match?(ID)
            raise Error, "must be a mapping (name, create, destroy…)" unless options.is_a?(Hash)
            options = options.transform_keys(&:to_s)
            unknown = options.keys - KEYS
            raise Error, "unknown key #{unknown.join(', ')} (expected #{(KEYS - %w[timeoutSeconds command cleanup checkout_mode checkoutMode]).join(', ')})" if unknown.any?
            recipe(id, options)
          end
        end.freeze
      end

      def recipe(id, options)
        create = one_of(options, "create", "command")
        destroy = one_of(options, "destroy", "cleanup")
        mode = one_of(options, "checkout_mode", "checkoutMode")
        raise Error, "checkoutMode: #{mode} is not supported: it needs a recipe that connects over SSH, and Harbor only runs recipes that start an Orca server" if mode.present?
        raise Error, "needs create:, the command that starts a machine" if create.blank?
        raise Error, "needs destroy:, the command that removes the machine (or destroy: none when nothing is to be removed)" if destroy.nil?
        commands = { "create" => create, "destroy" => destroy, "suspend" => options["suspend"], "resume" => options["resume"] }
        commands.each do |step, line|
          raise Error, "#{step} must be a command, like ./scripts/orca-vm/#{step}.sh" unless line.nil? || (line.is_a?(String) && line.strip.present?)
        end
        raise Error, "suspend and resume go together: give both or neither" if commands["suspend"].nil? != commands["resume"].nil?
        Recipe.new(id:, name: options["name"].to_s.strip.presence || id, create: create.strip,
                   destroy: (destroy.strip unless destroy.strip == NONE), suspend: commands["suspend"]&.strip, resume: commands["resume"]&.strip,
                   timeouts: timeouts(one_of(options, "timeout_seconds", "timeoutSeconds"))).freeze
      end

      # A key under either of its two spellings, never both.
      def one_of(options, name, other)
        raise Error, "give #{name} or #{other}, not both" if options.key?(name) && options.key?(other)
        options.key?(name) ? options[name] : options[other]
      end

      # One number for every step, or a map of step to seconds.
      def timeouts(value)
        return {}.freeze if value.nil?
        given = value.is_a?(Hash) ? value.transform_keys(&:to_s) : STEPS.index_with { value }
        unknown = given.keys - STEPS
        raise Error, "timeout_seconds: unknown step #{unknown.join(', ')} (expected #{STEPS.join(', ')})" if unknown.any?
        given.each do |step, seconds|
          next if seconds.is_a?(Integer) && TIMEOUTS.cover?(seconds)
          raise Error, "timeout_seconds for #{step} must be a whole number of seconds from #{TIMEOUTS.first} to #{TIMEOUTS.last}, not #{seconds.inspect}"
        end
        given.freeze
      end

      def at(id)
        yield
      rescue Error => error
        raise Error, "#{ConfigFile.label}: #{SECTION}.#{id}: #{error.message}"
      end
    end
  end
end
