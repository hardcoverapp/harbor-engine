require "shellwords"

module Harbor
  module AgentSession
    # A session's prompt given as a slash command: a prompt kept as a file in
    # the repository the agent works in, with arguments.
    #
    #   command = SlashCommand.new("/tidy:shelf 12 --fast", ref: "origin/main")
    #   command.name        # "tidy:shelf"
    #   command.path        # ".claude/commands/tidy/shelf.md"
    #   command.arguments   # ["12", "--fast"]
    #
    # The repository is on the machine the session runs on, so the file is
    # read there: `shell` is the step of the agent command that turns it into
    # $HARBOR_RUN_DIR/prompt before the CLI starts. The CLI's own slash
    # commands are not used: it is given the finished text as its prompt.
    #
    # The rule, which a prompt written for it can rely on:
    #
    #   - the file is read from the worktree as checked out, or with `git show
    #     <ref>:<path>` when a ref is given;
    #   - when it starts with `---`, everything up to and including the next
    #     `---` that starts a line is dropped (YAML frontmatter), then the
    #     whitespace that follows;
    #   - `$ARGUMENTS` becomes the arguments joined by one space, then `$9`
    #     down to `$1` become the arguments by position (nothing, for one that
    #     wasn't given). There is no `$10`: it reads as `$1` followed by a 0.
    #
    # Arguments are split on whitespace and nothing else, so quotes don't
    # group words. The file's text and the arguments are only ever text: the
    # arguments reach the step in a file of the run's (`arguments`, one to a
    # line), not on a command line.
    class SlashCommand
      FOLDER = ".claude/commands".freeze
      # One part of a name: `ns:name` is the file name.md in the folder ns.
      SEGMENT = /\A[a-zA-Z0-9._-]+\z/
      REF = /\A[a-zA-Z0-9._\/][a-zA-Z0-9._\/-]*\z/
      # What separates arguments: every character JavaScript's \s matches,
      # which is more than Ruby's.
      SPACE = "[ \\t\\n\\v\\f\\r   -     　﻿]".freeze
      SPACES = /#{SPACE}+/
      # The exit status of a command whose file could not be read.
      MISSING = 66

      # Reads the file (stdin, with a line holding one "x" added after it so
      # that its last newline, or lack of one, survives) and prints the
      # prompt. Strings are compared and cut, never used as patterns, so no
      # character in the file or in an argument means anything.
      EXPAND = <<~'AWK'.freeze
        function swap(text, find, with,    out, at) {
          out = ""
          while ((at = index(text, find)) > 0) {
            out = out substr(text, 1, at - 1) with
            text = substr(text, at + length(find))
          }
          return out text
        }
        function trimmed(text,    i, cut) {
          do {
            cut = 0
            if (text != "" && index(" \t\n\v\f\r", substr(text, 1, 1)) > 0) cut = 1
            for (i = 1; cut == 0 && i <= wide; i++) if (substr(text, 1, length(space[i])) == space[i]) cut = length(space[i])
            text = substr(text, cut + 1)
          } while (cut > 0)
          return text
        }
        BEGIN {
          file = ENVIRON["HARBOR_RUN_DIR"] "/arguments"
          while ((getline line < file) > 0) {
            given[++count] = line
            all = (count == 1 ? "" : all " ") line
          }
          wider = "\302\240,\341\232\200,\342\200\250,\342\200\251,\342\200\257,\342\201\237,\343\200\200,\357\273\277"
          wider = wider ",\342\200\200,\342\200\201,\342\200\202,\342\200\203,\342\200\204,\342\200\205,\342\200\206,\342\200\207"
          wide = split(wider ",\342\200\210,\342\200\211,\342\200\212", space, ",")
        }
        { text = (NR == 1 ? "" : text "\n") $0 }
        END {
          text = substr(text, 1, length(text) - 1)
          if (substr(text, 1, 3) == "---") {
            at = index(substr(text, 4), "\n---")
            if (at > 0) text = trimmed(substr(text, at + 7))
          }
          text = swap(text, "$ARGUMENTS", all)
          for (i = 9; i >= 1; i--) text = swap(text, "$" i, given[i])
          ORS = ""
          print text
        }
      AWK

      # `path` is where the command's file is, in the repository.
      attr_reader :name, :arguments, :path, :ref

      # `spec` is the command as a person would type it, with or without the
      # leading slash. Raises ArgumentError for a name that is not plain
      # names joined by colons, or a ref that doesn't look like one.
      def initialize(spec, ref: nil)
        words = spec.to_s.split(SPACES).compact_blank
        raise ArgumentError, "a slash command can't contain a NUL character" if spec.to_s.include?("\0")

        @name = words.shift.to_s.delete_prefix("/")
        @arguments = words
        segments = @name.split(":", -1)
        unless segments.any? && segments.all? { |segment| segment.match?(SEGMENT) && segment != "." && segment != ".." }
          raise ArgumentError, "invalid slash command name #{@name.inspect}: a name is letters, digits, dots, dashes and " \
                               "underscores, with a colon between a folder and the name inside it"
        end
        @path = File.join(FOLDER, *segments[0..-2], "#{segments.last}.md")
        @ref = ref.presence&.to_s
        return if @ref.nil? || @ref.match?(REF)
        raise ArgumentError, "invalid command_ref #{ref.inspect}: a git ref such as origin/main"
      end

      # The command as typed: "/tidy:shelf 12 --fast".
      def to_s = [ "/#{name}", *arguments ].join(" ")

      # The run's `arguments` file: one argument to a line.
      def arguments_file = arguments.map { |argument| "#{argument}\n" }.join

      # The step that writes $HARBOR_RUN_DIR/prompt, or prints one line
      # starting ERROR: and exits MISSING when the file isn't there.
      def shell
        [ read, %({ cat "$HARBOR_RUN_DIR/command"; echo x; } | LC_ALL=C awk '#{EXPAND}' > "$HARBOR_RUN_DIR/prompt" || #{failed('could not be expanded')}) ].join("; ")
      end

      private

      def read
        copy = '"$HARBOR_RUN_DIR/command"'
        file = Shellwords.escape(path)
        return "{ [ -f #{file} ] && cat #{file} > #{copy}; } || #{failed("not found: no #{path}")}" if ref.nil?

        [ "git rev-parse --verify --quiet #{Shellwords.escape("#{ref}^{tree}")} >/dev/null 2>&1 || #{failed("not found: no ref #{ref} (for #{path})")}",
          "git show #{Shellwords.escape("#{ref}:#{path}")} > #{copy} 2>/dev/null || #{failed("not found: no #{path} at #{ref}")}" ].join("; ")
      end

      # Says what was looked for and where, and ends the command.
      def failed(what)
        %({ printf '%s %s\\n' #{Shellwords.escape("ERROR: slash command /#{name} #{what} in")} "$(pwd)"; exit #{MISSING}; })
      end
    end
  end
end
