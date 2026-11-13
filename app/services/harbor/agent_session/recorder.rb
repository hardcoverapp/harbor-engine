module Harbor
  module AgentSession
    # Takes an agent session's output as it arrives and puts it where it
    # belongs: the exact bytes in the run's raw stream file, and every
    # complete line of it, once, in the live log (as a readable line) and in
    # the run's events.
    #
    # `state` is the run's runner state, changed in place; the caller holds
    # the run's row lock and saves it. Three counters there say where things
    # stand: "received" (bytes of this attempt's output in the raw file),
    # "digested" (how far into them lines have been read) and "seq" (the last
    # event number used).
    class Recorder
      # Columns learnt from the stream that the caller saves with the state.
      attr_reader :columns

      def initialize(run, state)
        @run = run
        @state = state
        @columns = {}
      end

      # Adds bytes that follow what has been received, then reads whatever
      # complete lines there now are.
      def append(bytes)
        received = @state["received"].to_i
        write(bytes, at: received)
        @state["received"] = received + bytes.bytesize
        read_lines
      end

      # The command has ended: a last line with no newline is read too.
      def finish = read_lines(to_the_end: true)

      private

      def raw_file = @run.raw_log_path.present? ? Harbor::LiveLog.absolute(@run.raw_log_path) : nil

      # Where this attempt's output starts in the raw file: after an earlier
      # attempt's, when the run was started again.
      def base = @state["raw_base"].to_i

      # Written at its place in the file, not appended: if this request fails
      # after the write and is sent again, the bytes land where they were.
      def write(bytes, at:)
        return unless raw_file

        FileUtils.mkdir_p(File.dirname(raw_file))
        File.open(raw_file, File::WRONLY | File::CREAT, binmode: true) do |file|
          file.seek(base + at)
          file.write(bytes)
          file.truncate(file.pos)
        end
      end

      def pending
        return "".b unless raw_file && File.file?(raw_file)

        digested = @state["digested"].to_i
        File.open(raw_file, "rb") do |file|
          file.seek(base + digested)
          file.read(@state["received"].to_i - digested).to_s
        end
      end

      # A piece can end mid-line, and mid-character. Only whole lines are
      # read, and it is only here, on a whole line, that bytes are made valid
      # text: a character split across two pieces is whole again by now.
      def read_lines(to_the_end: false)
        bytes = pending
        cut = to_the_end ? bytes.bytesize : (bytes.rindex("\n")&.+(1) || 0)
        return if cut.zero?

        stream = Stream.new
        shown = []
        bytes.byteslice(0, cut).each_line do |line|
          text = line.chomp.force_encoding(Encoding::UTF_8).scrub("?")
          next if text.strip.empty?
          stream.feed(text)
          readable = Digest.line(text)
          shown << readable if readable
        end

        Harbor::LiveLog.append(@run.live_log_path, shown.map { |text| "#{text}\n" }.join)
        record(stream.events)
        @columns[:session_id] = stream.summary.session_id if stream.summary.session_id.present?
        @state["digested"] = @state["digested"].to_i + cut
      end

      # Events are added after the ones already there, numbered on from them.
      def record(events)
        return if events.empty?

        seq = @state["seq"].to_i
        now = Time.current
        rows = events.map.with_index(1) do |event, index|
          { run_id: @run.id, seq: seq + index, event_type: event.event_type, subtype: event.subtype,
            tool_name: event.tool_name, summary: event.summary.to_s.truncate(255), payload: event.payload || {},
            occurred_at: now }
        end
        Harbor::RunEvent.insert_all!(rows)
        @state["seq"] = seq + rows.size
      end
    end
  end
end
