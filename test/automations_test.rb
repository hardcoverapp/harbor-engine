require "test_helper"

# Jobs of a site's own, for job automations.
class HarborAutomationLoaderJob < Harbor::TrackedJob
  self.loader_slug = "nightly-load"

  def load(logger:) = { "loaded" => 3 }
end

class HarborAutomationOwnRunJob < ActiveJob::Base
  cattr_accessor :skip_reason

  def self.automation_dispatch!(trigger_source:, triggered_by_user_id:) = perform_later(trigger_source:, triggered_by_user_id:)

  def self.automation_skip_reason(trigger_source:) = (skip_reason unless trigger_source == "manual")

  def perform(**) = nil
end

# The automation record, what a site declares about it, starting one
# (Dispatch), the tick, and an agent automation run as an agent session.
class HarborAutomationsTest < ActionDispatch::IntegrationTest
  include HarborAgentSessions
  include SingletonStub

  Dispatch = Harbor::Automations::Dispatch
  Tick = Harbor::Automations::Tick
  AgentRunJob = Harbor::Automations::AgentRunJob
  CONFIG = %i[automation_class automation_agent_run].freeze

  # A host's automation class: a trigger of its own, said in its own words.
  class HostAutomation < Harbor::Automation
    def trigger_summary = trigger_kind == "parcel" ? "When a parcel arrives" : super

    def self.identity_refusal = "has no key to the building"
  end

  setup do
    Harbor::Automations.reset!
    HarborAutomationOwnRunJob.skip_reason = nil
    @automation_config = CONFIG.index_with { |name| Harbor.config.public_send(name) }
  end

  teardown do
    Harbor::Automations.reset!
    @automation_config.each { |name, value| Harbor.config.public_send("#{name}=", value) }
    clear_enqueued_jobs
  end

  def build(**attrs)
    Harbor::Automation.new({ key: "tidy-#{SecureRandom.hex(3)}", name: "Tidy", kind: "agent", agent_key: "writer",
                             prompt: "Tidy the shelf.", trigger_kind: "manual" }.merge(attrs))
  end

  def agent_automation(**attrs) = build(**attrs).tap(&:save!)

  def job_automation(**attrs)
    Harbor::Automation.create!({ key: "load-#{SecureRandom.hex(3)}", name: "Load", kind: "job", job_class: "HarborAutomationLoaderJob",
                                 job_dispatch: "loader", trigger_kind: "manual" }.merge(attrs))
  end

  def at(hour, minute, second = 0) = Time.zone.local(2026, 11, 16, hour, minute, second)

  # --- what a site declares ---

  test "a site that declares nothing has no categories, folders or identities, and Harbor's two triggers" do
    assert_equal [ [], [], [], [] ], [ Harbor::Automations.categories, Harbor::Automations.working_folders,
                                       Harbor::Automations.identities, Harbor::Automations.triggers ]
    assert_equal %w[schedule manual], Harbor::Automations.trigger_kinds
    assert_equal [ "Working directory", "Runs as" ], [ Harbor::Automations.label(:cwd_key), Harbor::Automations.label(:run_as) ]
  end

  test "what a site declares is kept in the order declared, and can't be declared twice" do
    Harbor::Automations.category "data", label: "Data"
    Harbor::Automations.category "upkeep"
    Harbor::Automations.working_folder "app", label: "The app", path: -> { "/srv/app" }
    Harbor::Automations.working_folder "notes", label: "Notes", path: "/srv/notes"
    Harbor::Automations.identity "release-bot", label: "@release-bot"
    Harbor::Automations.trigger "parcel", label: "When a parcel arrives", kinds: %w[agent]
    Harbor::Automations.label :run_as, "Badge"

    assert_equal [ %w[data Data], %w[upkeep Upkeep] ], Harbor::Automations.categories.map { |c| [ c.key, c.label ] }
    assert_equal [ "/srv/app", "/srv/notes" ], Harbor::Automations.working_folders.map(&:location)
    assert_equal "@release-bot", Harbor::Automations.find_identity("release-bot").label
    assert_equal %w[schedule manual parcel], Harbor::Automations.trigger_kinds
    assert_equal %w[agent], Harbor::Automations.find_trigger("parcel").kinds
    assert_equal "Badge", Harbor::Automations.label(:run_as)

    assert_raises(ArgumentError) { Harbor::Automations.category "data" }
    assert_raises(ArgumentError) { Harbor::Automations.identity "release-bot" }
    assert_raises(ArgumentError) { Harbor::Automations.trigger "manual", label: "By hand" }
    assert_raises(ArgumentError) { Harbor::Automations.label :colour, "Blue" }
  end

  # --- the record ---

  test "an agent automation needs a key, a name, an agent and exactly one of instructions or a slash command" do
    assert build.valid?
    assert_not build(key: "Not A Key").valid?
    assert_not build(name: nil).valid?
    assert_not build(agent_key: nil).valid?
    assert_not build(prompt: nil).valid?
    assert_not build(slash_command: "tidy").valid?, "both given"
    assert build(prompt: nil, slash_command: "tidy").valid?
    assert_not build(timeout_ms: 0).valid?

    taken = agent_automation
    assert_not build(key: taken.key).valid?
  end

  test "a schedule needs a cron that parses, and a trigger must be Harbor's or one the site declared" do
    assert_not build(trigger_kind: "schedule", cron: "every tuesday").valid?
    assert_not build(trigger_kind: "schedule", cron: nil).valid?
    assert build(trigger_kind: "schedule", cron: "0 8 * * *").valid?

    assert_not build(trigger_kind: "parcel").valid?
    Harbor::Automations.trigger "parcel", label: "When a parcel arrives"
    assert build(trigger_kind: "parcel").valid?
  end

  test "with nothing declared a category, folder and identity are not asked for; declared, they must be one of them" do
    assert build(category: nil, cwd_key: nil, run_as: nil).valid?

    Harbor::Automations.category "data"
    assert_not build(category: nil).valid?
    assert_not build(category: "other").valid?
    assert build(category: "data").valid?

    Harbor::Automations.working_folder "app", label: "The app", path: "/srv/app"
    assert_not build(category: "data").valid?, "an agent automation names a folder once any is declared"
    assert_not build(category: "data", cwd_key: "elsewhere").valid?
    folder = build(category: "data", cwd_key: "app")
    assert folder.valid?
    assert_equal [ "/srv/app", "The app" ], [ folder.cwd, folder.cwd_label ]
    assert job_automation(category: "data").valid?, "a job automation needn't name one"

    Harbor::Automations.identity "release-bot", label: "@release-bot"
    stranger = build(category: "data", cwd_key: "app", run_as: "somebody")
    assert_not stranger.valid?
    assert_equal [ "is not an identity this site declared" ], stranger.errors[:run_as]
    known = build(category: "data", cwd_key: "app", run_as: "release-bot")
    assert known.valid?
    assert_equal "@release-bot", known.run_as_label
  end

  test "a job automation needs a job class that exists" do
    assert_not build(kind: "job", job_class: nil).valid?
    assert_not build(kind: "job", job_class: "No::SuchJob").valid?
    assert_not build(kind: "job", job_class: "HarborAutomationLoaderJob", job_dispatch: "magic").valid?
    assert build(kind: "job", job_class: "HarborAutomationLoaderJob", agent_key: nil, prompt: nil).valid?
  end

  test "next_run_at follows the cron and due_at is the tick it last became due for" do
    automation = build(trigger_kind: "schedule", cron: "*/15 * * * *")
    travel_to at(10, 7) do
      assert_equal at(10, 15), automation.next_run_at
      assert_equal at(10, 0), automation.due_at
    end
    assert_equal at(9, 45), automation.due_at(at(9, 59))
    assert_nil build.next_run_at, "an automation started by hand has no next run"
    assert_nil build.due_at
  end

  test "a trigger reads as words" do
    { "20 8 * * *" => "daily at 08:20", "0 3 * * 6" => "weekly on Sat at 03:00", "*/15 * * * *" => "every 15 min",
      "20 */2 * * *" => "every 2 h at :20", "5 * * * *" => "hourly at :05", "0 8 1 * *" => "0 8 1 * *" }.each do |cron, words|
      assert_equal words, build(trigger_kind: "schedule", cron:).trigger_summary
    end
    assert_equal "manual", build.trigger_summary

    Harbor::Automations.trigger "parcel", label: "On a parcel"
    assert_equal "On a parcel", build(trigger_kind: "parcel").trigger_summary
    assert_equal "When a parcel arrives", HostAutomation.new(trigger_kind: "parcel").trigger_summary
    assert_equal "manual", HostAutomation.new(trigger_kind: "manual").trigger_summary
  end

  test "a schedule counts from when it was set, changed or switched back on, never from the cron's last occurrence" do
    travel_to at(10, 0) do
      made = agent_automation(trigger_kind: "schedule", cron: "0 8 * * *")
      assert_equal Time.current, made.last_scheduled_at

      switched = agent_automation
      assert_nil switched.last_scheduled_at
      switched.update!(trigger_kind: "schedule", cron: "0 8 * * *")
      assert_equal Time.current, switched.last_scheduled_at

      seeded = agent_automation(trigger_kind: "schedule", cron: "0 8 * * *", last_scheduled_at: 1.day.ago)
      assert_equal 1.day.ago, seeded.last_scheduled_at, "a marker given in code is kept"
      seeded.update!(enabled: false)
      travel 2.days
      seeded.update!(description: "words only")
      assert_equal 3.days.ago, seeded.last_scheduled_at
      seeded.update!(enabled: true)
      assert_equal Time.current, seeded.last_scheduled_at
      travel 1.hour
      seeded.update!(cron: "0 9 * * *")
      assert_equal Time.current, seeded.last_scheduled_at
    end
  end

  test "automations are listed by category in the order declared, then by position and name" do
    assert_equal %w[Alpha Beta], [ agent_automation(name: "Beta"), agent_automation(name: "Alpha") ].then { Harbor::Automation.ordered.map(&:name) }

    Harbor::Automation.delete_all
    Harbor::Automations.category "upkeep"
    Harbor::Automations.category "data"
    agent_automation(name: "Load", category: "data")
    agent_automation(name: "Sweep", category: "upkeep", position: 2)
    agent_automation(name: "Audit", category: "upkeep", position: 1)
    assert_equal %w[Audit Sweep Load], Harbor::Automation.ordered.map(&:name)
  end

  test "deleting an automation keeps its runs" do
    automation = job_automation
    run = Harbor::Run.create!(loader: automation.key, automation: automation, status: "ok")
    assert_equal [ run ], automation.runs.to_a
    assert_equal run, automation.last_run
    automation.destroy!
    assert_nil run.reload.automation_id
  end

  # --- starting one ---

  test "a loader job automation gets a run named by its key and its job enqueued with the run's id" do
    automation = job_automation(job_input: { "since" => "monday" })
    result = nil
    assert_enqueued_with(job: HarborAutomationLoaderJob) { result = Dispatch.call(automation, trigger_source: "cron", trigger_ref: "cron:x") }

    run = result.run
    assert_equal [ automation.key, nil, automation.id, "cron", "cron:x", "queued" ],
                 [ run.loader, run.skill, run.automation_id, run.trigger_source, run.trigger_ref, run.status ]
    assert_equal({ "since" => "monday", "loader" => automation.key }, run.input)
    assert_equal [ run.id ], enqueued_jobs.last[:args]

    perform_enqueued_jobs
    assert_equal [ "ok", { "loaded" => 3 } ], [ run.reload.status, run.output ]
  end

  test "a skill job automation gets a run named in the skill column, with the automation's input and the trigger's" do
    automation = job_automation(job_dispatch: "skill", job_input: { "folders" => %w[wiki] })
    run = Dispatch.call(automation, trigger_source: "manual", context: { "only" => "changed" }).run
    assert_equal [ automation.key, nil ], [ run.skill, run.loader ]
    assert_equal({ "folders" => %w[wiki], "only" => "changed" }, run.input)
  end

  test "a job that makes its own run is only asked to start" do
    automation = job_automation(job_class: "HarborAutomationOwnRunJob", job_dispatch: "self")
    result = nil
    assert_enqueued_with(job: HarborAutomationOwnRunJob, args: [ { trigger_source: "manual", triggered_by_user_id: nil } ]) do
      result = Dispatch.call(automation, trigger_source: "manual")
    end
    assert_nil result.run
    assert result.enqueued
    assert_not result.skipped?
    assert_equal 0, automation.runs.count
  end

  test "a job class may refuse a firing with a reason" do
    automation = job_automation(job_class: "HarborAutomationOwnRunJob", job_dispatch: "self")
    HarborAutomationOwnRunJob.skip_reason = "nothing to do"
    result = Dispatch.call(automation, trigger_source: "cron")
    assert result.skipped?
    assert_equal "nothing to do", result.note
    assert_no_enqueued_jobs
    assert_not Dispatch.call(automation, trigger_source: "manual").skipped?
  end

  test "a second firing while one is in flight returns that run, unless the automation allows more" do
    automation = job_automation
    first = Dispatch.call(automation, trigger_source: "cron").run
    again = Dispatch.call(automation, trigger_source: "cron")
    assert_equal first, again.run
    assert_equal "already queued — run ##{first.id}", again.note
    assert_equal 1, automation.runs.count

    automation.update!(allow_concurrent: true)
    assert_not_equal first, Dispatch.call(automation, trigger_source: "cron").run
  end

  test "an idempotency key makes a repeated firing a no-op" do
    automation = job_automation
    assert_not_nil Dispatch.call(automation, trigger_source: "cron", idempotency_key: "k-#{automation.id}").run
    automation.runs.update_all(status: "ok")
    again = Dispatch.call(automation, trigger_source: "cron", idempotency_key: "k-#{automation.id}")
    assert again.skipped?
    assert_equal 1, automation.runs.count
  end

  test "a disabled automation only runs by hand" do
    automation = job_automation(enabled: false)
    result = Dispatch.call(automation, trigger_source: "cron")
    assert result.skipped?
    assert_equal "disabled", result.note
    assert_not_nil Dispatch.call(automation, trigger_source: "manual").run
  end

  test "a job that can't be enqueued leaves a failed run and the occurrence free to fire again" do
    automation = job_automation
    with_stub(HarborAutomationLoaderJob, :perform_later, ->(*) { raise IOError, "the queue is down" }) do
      assert_raises(IOError) { Dispatch.call(automation, trigger_source: "cron", idempotency_key: "k-#{automation.id}") }
    end
    failed = automation.runs.sole
    assert_equal [ "error", nil ], [ failed.status, failed.idempotency_key ]
    assert_match "could not enqueue HarborAutomationLoaderJob: IOError: the queue is down", failed.error
    assert_not_nil Dispatch.call(automation, trigger_source: "cron", idempotency_key: "k-#{automation.id}").run
  end

  # --- an agent automation as an agent session ---

  test "an agent automation's firing is a queued run with its job behind it" do
    Harbor::Automations.identity "release-bot"
    automation = agent_automation(run_as: "release-bot", trigger_kind: "schedule", cron: "0 8 * * *")
    result = nil
    assert_enqueued_with(job: AgentRunJob) do
      result = Dispatch.call(automation, trigger_source: "cron", trigger_ref: "cron:x", context: { "thing" => "shelf", "subject_type" => "Shelf", "subject_id" => 4 })
    end

    run = result.run
    assert result.enqueued
    assert_equal [ "queued", "writer", automation.key, "automation", automation.id, "release-bot", "schedule", "cron", "cron:x", "Shelf", 4 ],
                 [ run.status, run.agent_key, run.skill, run.task_type, run.automation_id, run.acting_as, run.trigger, run.trigger_source,
                   run.trigger_ref, run.subject_type, run.subject_id ]
    assert_equal({ "thing" => "shelf", "subject_type" => "Shelf", "subject_id" => 4, "automation_id" => automation.id }, run.input)
    assert_equal [ run.id ], enqueued_jobs.last[:args]
    assert_empty @orca.calls, "nothing starts until the job runs"
  end

  test "the job starts the run as a session of the automation's agent, with its instructions filled in and its time limit" do
    automation = agent_automation(prompt: "Tidy the {{thing}}. Leave {{other}} alone.", timeout_ms: 600_000)
    run = travel_to(at(10, 0)) do
      Dispatch.call(automation, trigger_source: "manual", context: { "thing" => "shelf" }).run.tap { perform_enqueued_jobs(only: AgentRunJob) }
    end

    run.reload
    assert run.running?
    assert Harbor::AgentSession.session?(run)
    assert_equal [ "orca", @runtime.id, "claude-sonnet-5-5", "writer" ], [ run.executor, run.runtime_id, run.model, run.agent_key ]
    assert_equal "Tidy the shelf. Leave {{other}} alone.", run.input.dig("agent_session", "prompt")
    assert_equal at(10, 10), Time.zone.parse(run.runner_state["timeout_at"])
    assert_equal "#{automation.key}/run-#{run.id}.log", run.live_log_path
    assert_equal [ 1, 1 ], [ Harbor::Slots.busy(@agent), @runtime.busy ]
    assert_equal %w[worktree\ create terminal\ create], @orca.commands.first(2)
    assert_no_enqueued_jobs only: AgentRunJob

    post_output run, ndjson({ "type" => "result", "subtype" => "success", "result" => "Tidied.", "session_id" => "s-1" })
    post_result run, 0
    assert run.reload.ok?
    assert_equal run, automation.last_run
    assert_nil automation.in_flight
  end

  test "a slash-command automation's file is read from the ref the site set, or the worktree when it set none" do
    automation = agent_automation(prompt: nil, slash_command: "/tidy:shelf {{thing}} --fast")
    run = Dispatch.call(automation, trigger_source: "manual", context: { "thing" => "12" }).run
    perform_enqueued_jobs(only: AgentRunJob)
    assert_equal [ "/tidy:shelf 12 --fast", "origin/main" ], run.reload.input.dig("agent_session", "command").values_at("slash_command", "command_ref")
    assert_includes Shellwords.split(@orca.terminal_commands.last).last, "git show origin/main:.claude/commands/tidy/shelf.md"
    post_result run, 0

    Harbor::Setting.set!(:automation_command_ref, "")
    run = Dispatch.call(automation, trigger_source: "manual").run
    perform_enqueued_jobs(only: AgentRunJob)
    assert run.reload.running?
    assert_nil run.input.dig("agent_session", "command", "command_ref")
  end

  test "while the agent is full the run waits and the job looks again; with room it starts, once" do
    @agent.update!(max_agents: 1)
    automation = agent_automation(allow_concurrent: true)
    first = Dispatch.call(automation, trigger_source: "manual").run
    second = Dispatch.call(automation, trigger_source: "manual").run
    perform_enqueued_jobs(only: AgentRunJob)

    assert first.reload.running?
    assert second.reload.queued?
    assert_enqueued_with(job: AgentRunJob, args: [ second.id ])
    assert_equal 1, @orca.terminal_commands.size

    post_result first, 0
    perform_enqueued_jobs(only: AgentRunJob)
    assert second.reload.running?
    assert_no_enqueued_jobs only: AgentRunJob

    AgentRunJob.perform_now(second.id)
    assert_equal 2, @orca.terminal_commands.size, "a job run again finds the session and starts nothing more"
  end

  test "a run with nothing to start it as is finished, saying why" do
    automation = agent_automation
    gone = Dispatch.call(automation, trigger_source: "manual").run
    automation.destroy!
    AgentRunJob.perform_now(gone.id)
    assert_equal [ "skipped", "The automation this run was for no longer exists." ], [ gone.reload.status, gone.error ]

    automation = agent_automation(name: "Sweep")
    @agent.update!(enabled: false)
    off = Dispatch.call(automation, trigger_source: "manual").run
    AgentRunJob.perform_now(off.id)
    assert_equal [ "error", "Sweep has no agent that is switched on." ], [ off.reload.status, off.error ]
    @agent.update!(enabled: true)

    automation.update_columns(prompt: nil, slash_command: "/../../etc/passwd")
    bad = Dispatch.call(automation, trigger_source: "manual").run
    AgentRunJob.perform_now(bad.id)
    assert bad.reload.error?
    assert_match(/slash command/i, bad.error)

    automation.update_columns(prompt: nil, slash_command: nil)
    empty = Dispatch.call(automation, trigger_source: "manual").run
    AgentRunJob.perform_now(empty.id)
    assert_equal [ "error", "This automation has neither instructions nor a slash command." ], [ empty.reload.status, empty.error ]
    assert_empty @orca.calls

    stopped = Dispatch.call(agent_automation, trigger_source: "manual").run
    stopped.finish!(status: "canceled")
    AgentRunJob.perform_now(stopped.id)
    assert stopped.reload.canceled?
    assert_empty @orca.calls
  end

  test "an agent run that can't be enqueued is closed out, not left in flight" do
    automation = agent_automation
    with_stub(AgentRunJob, :perform_later, ->(*) { raise IOError, "the queue is down" }) do
      assert_raises(IOError) { Dispatch.call(automation, trigger_source: "cron", idempotency_key: "k-#{automation.id}") }
    end
    failed = automation.runs.sole
    assert_equal [ "error", nil ], [ failed.status, failed.idempotency_key ]
    assert_match "could not enqueue Harbor::Automations::AgentRunJob: IOError: the queue is down", failed.error
    assert_nil automation.in_flight
  end

  test "a host that runs agent automations its own way is handed the firing instead" do
    automation = agent_automation
    firings = []
    Harbor.config.automation_agent_run = lambda do |fired, **trigger|
      firings << [ fired, trigger ]
      trigger[:trigger_ref] == "twice" ? nil : Harbor::Run.create!(automation_id: fired.id, status: "queued", skill: "the-hosts")
    end

    result = Dispatch.call(automation, trigger_source: "webhook", trigger_ref: "gh:1", webhook_event: :an_event, context: { "n" => 1 })
    assert_equal "the-hosts", result.run.skill
    assert result.enqueued
    assert_equal [ [ automation, { trigger_source: "webhook", triggered_by_user: nil, trigger_ref: "gh:1", webhook_event: :an_event,
                                   context: { "n" => 1 }, idempotency_key: nil } ] ], firings
    assert_no_enqueued_jobs

    automation.update!(allow_concurrent: true)
    duplicate = Dispatch.call(automation, trigger_source: "webhook", trigger_ref: "twice")
    assert duplicate.skipped?
    assert_match "duplicate delivery", duplicate.note
  end

  # --- the tick ---

  def scheduled(cron = "*/5 * * * *", **attrs)
    job_automation(**{ trigger_kind: "schedule", cron:, last_scheduled_at: at(0, 0) }.merge(attrs))
  end

  test "the tick starts a due automation exactly once" do
    automation = scheduled
    Tick.call(at(10, 5, 30))

    run = automation.runs.sole
    assert_equal [ "cron", "queued", "automation-#{automation.id}-#{at(10, 5).to_i}" ], [ run.trigger_source, run.status, run.idempotency_key ]
    assert_equal at(10, 5), Time.zone.parse(run.trigger_ref.delete_prefix("cron:"))
    assert_equal at(10, 5), automation.reload.last_scheduled_at
    assert_enqueued_jobs 1, only: HarborAutomationLoaderJob

    Tick.call(at(10, 5, 50))
    Harbor::Automations::TickJob.perform_now(at(10, 6, 10))
    assert_equal 1, automation.runs.count, "the same due time never fires twice"

    run.update!(status: "ok")
    Harbor::Automations::TickJob.perform_now(at(10, 10, 2))
    assert_equal 2, automation.runs.count, "the next due time fires"
  end

  test "the tick leaves alone an automation that isn't due, is switched off, or isn't on a schedule" do
    not_due = scheduled(last_scheduled_at: at(10, 5))
    off = scheduled(enabled: false)
    by_hand = job_automation
    Tick.call(at(10, 7))

    assert_equal [ 0, 0, 0 ], [ not_due, off, by_hand ].map { |automation| automation.runs.count }
    assert_equal [ at(10, 5), at(0, 0), nil ], [ not_due, off, by_hand ].map { |automation| automation.reload.last_scheduled_at }
    assert_no_enqueued_jobs

    Tick.call(at(10, 10, 1))
    assert_equal [ 1, 0, 0 ], [ not_due, off, by_hand ].map { |automation| automation.runs.count }
  end

  test "after an outage an automation fires once, for the latest time it missed" do
    automation = scheduled("* * * * *", last_scheduled_at: at(8, 0))
    Tick.call(at(9, 0, 10))
    assert_equal 1, automation.runs.count
    assert_equal at(9, 0), automation.reload.last_scheduled_at
  end

  test "a run still in flight holds the next firing back, and the due time is still used up" do
    automation = scheduled("* * * * *", last_scheduled_at: at(8, 0))
    Tick.call(at(8, 1, 5))
    Tick.call(at(8, 2, 5))
    assert_equal 1, automation.runs.count
    assert_equal at(8, 2), automation.reload.last_scheduled_at
  end

  test "a start that raises hands the due time back, so the next tick tries again; other automations still fire" do
    broken = scheduled("* * * * *", last_scheduled_at: at(8, 0), name: "A broken one")
    fine = scheduled("* * * * *", last_scheduled_at: at(8, 0), job_dispatch: "skill")
    with_stub(HarborAutomationLoaderJob, :perform_later, ->(id) { Harbor::Run.find(id).loader ? raise(IOError, "the queue is down") : nil }) do
      Tick.call(at(8, 1, 5))
    end
    assert_equal at(8, 0), broken.reload.last_scheduled_at, "the marker is put back"
    assert_equal "error", broken.runs.sole.status, "the failure is still a run"
    assert_equal [ at(8, 1), 1 ], [ fine.reload.last_scheduled_at, fine.runs.count ]

    Tick.call(at(8, 2, 5))
    assert_equal 2, broken.runs.count
    assert_equal at(8, 2), broken.reload.last_scheduled_at
  end

  test "two ticks at the same moment claim a due time once" do
    automation = scheduled
    due = automation.due_at(at(10, 5, 30))
    claim = -> { Harbor::Automation.where(id: automation.id).where("last_scheduled_at IS NULL OR last_scheduled_at < ?", due).update_all(last_scheduled_at: due) }
    assert_equal [ 1, 0 ], [ claim.call, claim.call ]
    Tick.call(at(10, 5, 30))
    assert_equal 0, automation.runs.count, "a tick that lost the claim starts nothing"
  end

  test "a scheduled agent automation, in a site with no code of its own, runs as a session when its time comes" do
    automation = travel_to(at(9, 58)) { agent_automation(trigger_kind: "schedule", cron: "0 * * * *") }
    Tick.call(at(9, 59))
    assert_equal 0, automation.runs.count

    travel_to(at(10, 0, 20)) do
      Harbor::Automations::TickJob.perform_now
      perform_enqueued_jobs(only: AgentRunJob)
    end
    run = automation.runs.sole
    assert run.running?
    assert_equal [ "cron", "Tidy the shelf." ], [ run.trigger_source, run.input.dig("agent_session", "prompt") ]

    travel_to(at(10, 0, 50)) { Harbor::Automations::TickJob.perform_now }
    assert_equal 1, automation.runs.count
  end

  test "the tick finds automations through the host's class" do
    Harbor.config.automation_class = "HarborAutomationsTest::HostAutomation"
    automation = scheduled
    Tick.call(at(10, 5, 30))
    assert_equal 1, automation.runs.count
    assert_instance_of HostAutomation, Harbor.automation_class.find(automation.id)
  end
end
