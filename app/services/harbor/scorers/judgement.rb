module Harbor
  module Scorers
    # One scorer judging one run: what the host's judge (`config.scorer_judge`)
    # is handed, and how its answer is recorded.
    #
    #   c.scorer_judge = ->(judgement) do
    #     text = MyModel.read(judgement.transcript_file, prompt: judgement.prompt)
    #     text            # Harbor reads the verdict from it
    #   end
    #
    # The judge is recorded as `judge`, a child run of the run it grades: put
    # its model, command, cost and tokens there like any run's. A judge that
    # can't run says why with `fail!`; one that answers later (it started
    # something that reports back) returns nothing and calls `answer!` or
    # `fail!` when it has, on `Judgement.for(judge_run)`. Until then the
    # verdict shows as pending, and after `config.scorer_judge_wait` the run
    # can be judged again.
    class Judgement
      # Raised by a judge that can only take so many at once and is full:
      # the judgement is tried again later, a bounded number of times.
      class Busy < StandardError; end

      attr_reader :scorer, :run, :judge, :result, :attempt

      # The judgement a judge run belongs to, or nil when its verdict has
      # since been claimed by another.
      def self.for(judge)
        result = Harbor::ScorerResult.find_by(judge_run_id: judge.id)
        result && new(scorer: result.scorer, run: result.run, judge:, result:)
      end

      # attempt: how many times this judgement has been put off as busy.
      def initialize(scorer:, run:, judge:, result:, attempt: 0)
        @scorer, @run, @judge, @result, @attempt = scorer, run, judge, result, attempt
        @settled = false
      end

      # What the judge is asked. `transcript` is the transcript's file name as
      # the judge will find it in the directory it runs in.
      def prompt(transcript: "transcript.ndjson") = Prompt.build(scorer, run, transcript:)

      # The graded run's transcript on this machine, or nil when it kept none.
      def transcript_file = run.raw_log_file

      # A line in the judge run's live log, opened when first written to.
      def log(line)
        unless @log_opened
          @log_opened = true
          @log = Harbor::LiveLog.open(judge.live_log_path)
        end
        @log&.call(line)
      end

      def close_log
        Harbor::LiveLog.close(@log) if @log
        @log = nil
      end

      # Whether the judgement has been answered or has failed.
      def settled? = @settled

      # The judge's final text. The verdict in it is recorded on the result
      # and the judge run finishes ok; with no usable verdict both are
      # errors. `output` is added to what the judge run keeps as its output.
      def answer!(text, output: {})
        text = text.to_s
        verdict = Verdict.parse(text, labels: scorer.labels)
        if verdict.nil?
          return fail!("the judge gave no verdict matching #{scorer.labels.join('/')}", output: output.merge(text: text.last(2000)))
        end

        score = scorer.score_for(verdict.classification)
        result.update!(status: "ok", classification: verdict.classification, score:, passed: score >= scorer.pass_threshold.to_f,
                       reasoning: verdict.reasoning, error: nil, scored_at: Time.current,
                       # A new verdict is a new fact: whatever a proposal did
                       # with the old one, this one hasn't been looked at.
                       reviewed_at: nil, proposal_id: nil, claimed_at: nil)
        judge.finish!(status: "ok", output: output.merge(classification: verdict.classification, score:,
                                                         passed: result.passed, text: text.last(2000)))
        @settled = true
        log("[scorer] #{verdict.classification} (#{score}) — #{result.passed ? 'pass' : 'fail'}")
        nil
      end

      # The judge couldn't give a verdict. `status` is how the judge run ends
      # ("error", or "skipped", "timeout", "canceled"); the result is an error
      # either way, with the message.
      def fail!(message, status: "error", output: nil)
        @settled = true
        judge&.finish!(status:, error: message, output:)
        result&.update!(status: "error", error: message, scored_at: nil)
        nil
      end
    end
  end
end
