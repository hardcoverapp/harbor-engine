module Harbor
  module Machines
    # What a recipe's `create` printed, read to Orca's contract: exactly one
    # JSON object on stdout, with a `pairingCode` and an absolute
    # `projectRoot` (Orca-server mode). Anything else is refused, and the
    # refusal never repeats what was printed: it may hold a pairing code.
    module RecipeResult
      # `result` is the object that was printed, when it was one: it is still
      # handed to `destroy`, which may need what it says.
      class Invalid < StandardError
        attr_reader :result

        def initialize(message, result: nil)
          super(message)
          @result = result
        end
      end

      module_function

      def parse(stdout, overflowed: false)
        text = stdout.to_s.strip
        raise Invalid, "create printed nothing on stdout: it must print one JSON object there (pairingCode, projectRoot)" if text.empty?
        raise Invalid, "create printed more than #{Script::CAPTURE / 1.megabyte} MB on stdout: only its one JSON object belongs there, and progress goes to stderr" if overflowed
        result = begin
          JSON.parse(text)
        rescue JSON::ParserError
          raise Invalid, "create printed something other than one JSON object on stdout (#{text.lines.size} #{'line'.pluralize(text.lines.size)}): " \
                         "progress and errors go to stderr, and a stray echo on stdout spoils the result"
        end
        raise Invalid, "create printed JSON that is not an object on stdout" unless result.is_a?(Hash)

        if result.key?("connection")
          raise Invalid.new("the recipe returned an SSH connection, which isn't supported yet: Harbor only runs recipes that start an Orca server " \
                            "and return its pairingCode and projectRoot", result:)
        end
        version = result["schemaVersion"]
        raise Invalid.new("the recipe's result has schemaVersion #{version.inspect}; only 1 is supported", result:) unless version.nil? || version == 1
        raise Invalid.new("the recipe's result has no pairingCode", result:) unless result["pairingCode"].is_a?(String) && result["pairingCode"].present?
        root = result["projectRoot"]
        raise Invalid.new("the recipe's result has no projectRoot", result:) unless root.is_a?(String) && root.present?
        raise Invalid.new("the recipe's projectRoot must be an absolute path on the machine", result:) unless root.start_with?("/")
        raise Invalid.new("the recipe's userData must be an object", result:) unless result["userData"].nil? || result["userData"].is_a?(Hash)
        result
      end
    end
  end
end
