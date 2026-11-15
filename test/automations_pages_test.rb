require "test_helper"

# A job of a site's own that makes its own run, for "Run now".
class HarborAutomationPagesOwnRunJob < ActiveJob::Base
  def self.automation_dispatch!(trigger_source:, triggered_by_user_id:) = perform_later(trigger_source:, triggered_by_user_id:)

  def self.automation_skip_reason(trigger_source:) = nil

  def perform(**) = nil
end

class HarborAutomationPagesLoaderJob < Harbor::TrackedJob
  self.loader_slug = "nightly-load"

  def load(logger:) = { "loaded" => 3 }
end

# The Automations pages: the list, the form that makes and edits one, the
# switch, "Run now" and Delete. What a site with no code of its own gets, and
# each place a host can add to.
class HarborAutomationsPagesTest < ActionDispatch::IntegrationTest
  include HarborAgentSessions

  AgentRunJob = Harbor::Automations::AgentRunJob
  HOST_VIEWS = File.expand_path("fixtures/host_views/extras", __dir__)
  CONFIG = %i[automation_class automation_agent_run automation_params automation_edited].freeze

  # A host's automation class: a name of its own for one of Harbor's columns,
  # only some agents offered, and a new automation that starts differently.
  class HostAutomation < Harbor::Automation
    alias_attribute :notes, :description

    def self.offered_agents = super.where("agents.key LIKE 'night-%'")

    def self.page_defaults = super.merge(timeout_ms: 120_000, name: "Untitled")
  end

  setup do
    Harbor::Automations.reset!
    @automation_config = CONFIG.index_with { |name| Harbor.config.public_send(name) }
    @view_paths = Harbor::AutomationsController.view_paths
    post "/login", params: { name: "Sam Settings" }
  end

  teardown do
    Harbor::Automations.reset!
    @automation_config.each { |name, value| Harbor.config.public_send("#{name}=", value) }
    Harbor::AutomationsController.view_paths = @view_paths
    clear_enqueued_jobs
  end

  # What a host does: a views folder of its own, looked in before Harbor's.
  def host_views = Harbor::AutomationsController.prepend_view_path(HOST_VIEWS)

  def agent_automation(**attrs)
    Harbor::Automation.create!({ key: "tidy", name: "Tidy the shelf", kind: "agent", agent_key: "writer", prompt: "Tidy the shelf.",
                                 trigger_kind: "manual", description: "Puts the books back." }.merge(attrs))
  end

  def job_automation(**attrs)
    Harbor::Automation.create!({ key: "nightly-load", name: "Nightly load", kind: "job", job_class: "HarborAutomationPagesLoaderJob",
                                 job_dispatch: "loader", trigger_kind: "schedule", cron: "0 8 * * *" }.merge(attrs))
  end

  def create_automation(**fields)
    post harbor.automations_path, params: { automation: { name: "Tidy the shelf", key: "tidy", agent_key: "writer", prompt: "Tidy the shelf.",
                                                          timeout_ms: 600_000, trigger_kind: "manual", enabled: "1" }.merge(fields) }
  end

  def field_names = css_select("form[action$='/automations'] [name^='automation['], form[action*='/automations/'] [name^='automation[']").map { |f| f["name"] }.uniq

  # --- a site with no code of its own ---

  test "with no automations the list says so and offers a new one" do
    get harbor.automations_path
    assert_response :success
    assert_select "h1", text: "Automations"
    assert_select "p", text: "No automations yet."
    assert_select "table", count: 0
    assert_select "a[href=?]", harbor.new_automation_path, text: "New automation"
  end

  test "the form for a new automation has Harbor's fields and nothing a site would have to declare" do
    get harbor.new_automation_path
    assert_response :success
    assert_select "h1", text: "New automation"
    assert_equal %w[automation[name] automation[key] automation[description] automation[agent_key] automation[timeout_ms] automation[prompt]
                    automation[slash_command] automation[trigger_kind] automation[cron] automation[enabled] automation[allow_concurrent]], field_names
    assert_select "select[name='automation[agent_key]'] option", text: "writer"
    assert_select "input[type=radio][name='automation[trigger_kind]']", count: 2
    assert_select "input[type=radio][name='automation[trigger_kind]'][value=manual][checked]"
    assert_select "input[name='automation[timeout_ms]'][value='900000']"
    assert_select "a[href=?]", harbor.agents_path, text: "Manage agents"
    assert_select "label[for=automation_cron]", text: /\ACron \(local time/
    assert_select "p", text: /read from\s+origin\/main/
    assert_select "form[action=?][method=post]", harbor.automations_path
  end

  test "an automation is made on the page, listed, and run by hand as a session of its agent" do
    assert_difference("Harbor::Automation.count", 1) { create_automation(key: "Tidy The Shelf", description: "Puts the books back.") }
    assert_redirected_to harbor.automations_path
    follow_redirect!
    assert_select "[data-notice]", text: /Tidy the shelf saved/

    automation = Harbor::Automation.find_by!(key: "tidy-the-shelf")
    assert_equal [ "agent", "writer", "Tidy the shelf.", 600_000, "manual", true, nil, nil, nil ],
                 [ automation.kind, automation.agent_key, automation.prompt, automation.timeout_ms, automation.trigger_kind, automation.enabled,
                   automation.category, automation.cwd_key, automation.run_as ]
    assert_select "h2", count: 0, text: /./
    assert_select "tr#automation-tidy-the-shelf" do
      assert_select "a[href=?]", harbor.edit_automation_path(automation), text: "Tidy the shelf"
      assert_select "span.pill", text: "writer"
      assert_select "p", text: "Puts the books back."
      assert_select "p.font-mono", text: "Tidy the shelf."
      assert_select "td:nth-child(2)", text: /manual/
      assert_select "td:nth-child(3)", text: /—/
      assert_select "form[action=?] button", harbor.toggle_automation_path(automation), text: "on"
      assert_select "form[action=?]", harbor.run_automation_path(automation)
    end

    post harbor.run_automation_path(automation)
    run = automation.runs.sole
    assert_redirected_to harbor.run_path(run)
    assert_equal [ "queued", "manual", "writer", "tidy-the-shelf" ], [ run.status, run.trigger_source, run.agent_key, run.skill ]
    follow_redirect!
    assert_select "[data-notice]", text: /Started Tidy the shelf/

    perform_enqueued_jobs(only: AgentRunJob)
    assert run.reload.running?
    assert_equal "Tidy the shelf.", run.input.dig("agent_session", "prompt")

    post harbor.run_automation_path(automation)
    assert_redirected_to harbor.run_path(run)
    follow_redirect!
    assert_select "[data-notice]", text: /Tidy the shelf is already running — run ##{run.id}/
    assert_equal 1, automation.runs.count

    get harbor.automations_path
    assert_select "tr#automation-tidy-the-shelf td:nth-child(3)" do
      assert_select "a[href=?]", harbor.run_path(run)
      assert_select "[data-status=running]"
    end
  end

  test "an automation made on the page with a schedule is started by the tick, once" do
    travel_to Time.zone.local(2026, 11, 16, 9, 58) do
      create_automation(trigger_kind: "schedule", cron: "0 * * * *")
    end
    automation = Harbor::Automation.find_by!(key: "tidy")
    assert_equal Time.zone.local(2026, 11, 16, 9, 58), automation.last_scheduled_at

    travel_to Time.zone.local(2026, 11, 16, 10, 0, 30) do
      get harbor.automations_path
      assert_select "tr#automation-tidy td:nth-child(2)", text: /hourly at :00\s+next in about 1 hour/
      Harbor::Automations::TickJob.perform_now
      Harbor::Automations::TickJob.perform_now
      perform_enqueued_jobs(only: AgentRunJob)
    end
    run = automation.runs.sole
    assert_equal [ "running", "cron" ], [ run.status, run.trigger_source ]
  end

  test "what is wrong with an automation is said on the form, with what was typed kept" do
    create_automation(name: "", cron: "every tuesday", trigger_kind: "schedule", slash_command: "tidy")
    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: /Name can't be blank/
    assert_select "[role=alert]", text: /Give either instructions or a slash command, not both/
    assert_select "[role=alert]", text: /Cron is not a valid cron expression/
    assert_select "input[name='automation[cron]'][value='every tuesday']"
    assert_select "input[name='automation[key]'][value=tidy]:not([readonly])"
    assert_equal 0, Harbor::Automation.count
  end

  test "an automation is edited; its key never changes" do
    automation = agent_automation
    get harbor.edit_automation_path(automation)
    assert_response :success
    assert_select "h1", text: "Tidy the shelf"
    assert_select "form[action=?]", harbor.automation_path(automation)
    assert_select "input[name='automation[key]'][value=tidy][readonly]"
    assert_select "textarea[name='automation[prompt]']", text: /Tidy the shelf\./

    patch harbor.automation_path(automation), params: { automation: { name: "Tidy every shelf", key: "other", prompt: "", slash_command: "tidy all",
                                                                      trigger_kind: "schedule", cron: "*/15 * * * *", allow_concurrent: "1" } }
    assert_redirected_to harbor.automations_path
    automation.reload
    assert_equal [ "Tidy every shelf", "tidy", "", "tidy all", "schedule", "*/15 * * * *", true ],
                 [ automation.name, automation.key, automation.prompt, automation.slash_command, automation.trigger_kind, automation.cron,
                   automation.allow_concurrent ]

    get harbor.automations_path
    assert_select "tr#automation-tidy p.font-mono", text: "/tidy all"
    assert_select "tr#automation-tidy td:nth-child(2)", text: /every 15 min/
  end

  test "an automation is switched off and on from the list" do
    automation = agent_automation
    patch harbor.toggle_automation_path(automation)
    assert_redirected_to harbor.automations_path
    assert_not automation.reload.enabled?
    follow_redirect!
    assert_select "[data-notice]", text: /Tidy the shelf disabled/
    assert_select "tr#automation-tidy.opacity-55 form[action=?] button[aria-label='Enable Tidy the shelf']", harbor.toggle_automation_path(automation), text: "off"

    patch harbor.toggle_automation_path(automation)
    assert automation.reload.enabled?
  end

  test "an automation made on the page is deleted from its own page, and its runs are kept" do
    automation = agent_automation
    run = Harbor::Run.create!(automation_id: automation.id, agent_key: "writer", status: "ok")
    get harbor.edit_automation_path(automation)
    assert_select "form[action=?] input[name=_method][value=delete]", harbor.automation_path(automation)

    delete harbor.automation_path(automation)
    assert_redirected_to harbor.automations_path
    follow_redirect!
    assert_select "[data-notice]", text: /Tidy the shelf deleted/
    assert_not Harbor::Automation.exists?(automation.id)
    assert_nil run.reload.automation_id
  end

  # --- job automations: made in code, edited here in part ---

  test "a job automation is listed with its schedule and last run, and its job is started by Run now" do
    automation = job_automation
    earlier = Harbor::Run.create!(loader: automation.key, automation_id: automation.id, trigger_source: "cron", status: "ok")
    get harbor.automations_path
    assert_select "tr#automation-nightly-load" do
      assert_select "span.pill.bg-pale-purple", count: 0
      assert_select "p.font-mono", count: 0
      assert_select "td:nth-child(2)", text: /daily at 08:00\s+next in/
      assert_select "a[href=?]", harbor.run_path(earlier)
      assert_select "[data-status=ok]"
    end

    assert_enqueued_with(job: HarborAutomationPagesLoaderJob) { post harbor.run_automation_path(automation) }
    run = automation.runs.order(:id).last
    assert_redirected_to harbor.run_path(run)
    assert_equal [ "nightly-load", "manual" ], [ run.loader, run.trigger_source ]
  end

  test "a job automation's page edits its words, schedule and switch, and nothing about its code" do
    automation = job_automation
    get harbor.edit_automation_path(automation)
    assert_response :success
    assert_select "p", text: /Backed by\s+HarborAutomationPagesLoaderJob/
    assert_equal %w[automation[name] automation[description] automation[trigger_kind] automation[cron] automation[enabled] automation[allow_concurrent]],
                 field_names
    assert_select "code", text: "nightly-load"
    assert_select "input[name=_method][value=delete]", count: 0

    patch harbor.automation_path(automation), params: { automation: { cron: "30 6 * * *", description: "Earlier.", job_class: "Kernel", key: "other",
                                                                      kind: "agent", job_dispatch: "self", agent_key: "writer", prompt: "x" } }
    assert_redirected_to harbor.automations_path
    automation.reload
    assert_equal [ "30 6 * * *", "Earlier.", "HarborAutomationPagesLoaderJob", "nightly-load", "job", "loader", nil, nil ],
                 [ automation.cron, automation.description, automation.job_class, automation.key, automation.kind, automation.job_dispatch,
                   automation.agent_key, automation.prompt ]

    patch harbor.automation_path(automation), params: { automation: { cron: "every tuesday" } }
    assert_response :unprocessable_entity
    assert_equal "30 6 * * *", automation.reload.cron

    delete harbor.automation_path(automation)
    assert_redirected_to harbor.automations_path
    follow_redirect!
    assert_select "[data-alert]", text: /made by this site's code/
    assert Harbor::Automation.exists?(automation.id)
  end

  test "the page can't make a job automation, whatever is posted" do
    create_automation(kind: "job", job_class: "Kernel", job_dispatch: "self", job_input: { "x" => 1 })
    assert_redirected_to harbor.automations_path
    made = Harbor::Automation.find_by!(key: "tidy")
    assert_equal [ "agent", nil, "loader", {} ], [ made.kind, made.job_class, made.job_dispatch, made.job_input ]
  end

  test "Run now on a job that makes its own run goes to the Runs list; one that didn't start says why" do
    own = job_automation(key: "own", name: "Audit", job_class: "HarborAutomationPagesOwnRunJob", job_dispatch: "self", trigger_kind: "manual", cron: nil)
    assert_enqueued_with(job: HarborAutomationPagesOwnRunJob) { post harbor.run_automation_path(own) }
    assert_redirected_to harbor.runs_path
    follow_redirect!
    assert_select "[data-notice]", text: /Audit queued — its Run appears in Runs momentarily/

    with_refusal = Class.new(HarborAutomationPagesOwnRunJob) { def self.automation_skip_reason(trigger_source:) = "there is nothing to audit" }
    self.class.const_set(:RefusingJob, with_refusal) unless self.class.const_defined?(:RefusingJob)
    own.update!(job_class: "HarborAutomationsPagesTest::RefusingJob")
    post harbor.run_automation_path(own)
    assert_redirected_to harbor.automations_path
    follow_redirect!
    assert_select "[data-alert]", text: /Audit didn't start: there is nothing to audit/
  end

  # --- what a host declares ---

  test "declared categories head the list in their order and are picked on the form" do
    Harbor::Automations.category "upkeep", label: "Upkeep"
    Harbor::Automations.category "data", label: "Data"
    Harbor::Automations.category "unused", label: "Unused"
    job_automation(category: "data")
    agent_automation(category: "upkeep")

    get harbor.automations_path
    assert_equal %w[Upkeep Data], css_select("h2").map { |h2| h2.text.strip }
    assert_equal %w[automation-tidy automation-nightly-load], css_select("tbody tr").map { |tr| tr["id"] }
    assert_select "table", count: 2

    get harbor.new_automation_path
    assert_equal [ %w[Upkeep upkeep], %w[Data data], %w[Unused unused] ],
                 css_select("select[name='automation[category]'] option").map { |o| [ o.text, o["value"] ] }
    assert_select "select[name='automation[category]'] option[selected]", text: "Upkeep"

    create_automation(key: "second", category: "nowhere")
    assert_response :unprocessable_entity
    create_automation(key: "second", category: "data")
    assert_equal "data", Harbor::Automation.find_by!(key: "second").category
  end

  test "declared folders and identities are picked on the form, under the host's labels, and shown in the list" do
    Harbor::Automations.working_folder "app", label: "The app's checkout", path: "/srv/app"
    Harbor::Automations.working_folder "notes", label: "The notes", path: "/srv/notes"
    Harbor::Automations.identity "release-bot", label: "@release-bot"
    Harbor::Automations.identity "review-bot", label: "@review-bot"
    Harbor::Automations.label :run_as, "GitHub identity"

    get harbor.new_automation_path
    assert_select "label[for=automation_cwd_key]", text: "Working directory"
    assert_select "label[for=automation_run_as]", text: "GitHub identity"
    assert_equal [ [ "The app's checkout", "app" ], [ "The notes", "notes" ] ],
                 css_select("select[name='automation[cwd_key]'] option").map { |o| [ o.text, o["value"] ] }
    assert_equal [ %w[@release-bot release-bot], %w[@review-bot review-bot] ],
                 css_select("select[name='automation[run_as]'] option").map { |o| [ o.text, o["value"] ] }
    names = field_names
    assert_equal %w[automation[agent_key] automation[cwd_key] automation[run_as] automation[timeout_ms]], names[names.index("automation[agent_key]"), 4]

    create_automation(cwd_key: "notes", run_as: "somebody")
    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: /Run as is not an identity this site declared/
    create_automation(cwd_key: "notes", run_as: "review-bot")
    assert_redirected_to harbor.automations_path
    follow_redirect!
    assert_select "tr#automation-tidy p.text-faint", text: "The notes · as @review-bot"

    post harbor.run_automation_path(Harbor::Automation.find_by!(key: "tidy"))
    assert_equal "review-bot", Harbor::Run.last.acting_as
  end

  test "a host's trigger is offered between Harbor's two, for the kinds it names, and saved" do
    Harbor::Automations.trigger "parcel", label: "When a parcel arrives", kinds: %w[agent]
    get harbor.new_automation_path
    assert_equal %w[schedule parcel manual], css_select("input[type=radio][name='automation[trigger_kind]']").map { |radio| radio["value"] }
    assert_select "label", text: "When a parcel arrives"

    create_automation(trigger_kind: "parcel")
    assert_equal "parcel", Harbor::Automation.find_by!(key: "tidy").trigger_kind
    get harbor.automations_path
    assert_select "tr#automation-tidy td:nth-child(2)", text: /When a parcel arrives/

    get harbor.edit_automation_path(job_automation)
    assert_equal %w[schedule manual], css_select("input[type=radio][name='automation[trigger_kind]']").map { |radio| radio["value"] }
  end

  # --- what a host adds through partials and config ---

  test "with no partials of the host's, the pages have only Harbor's own" do
    automation = agent_automation
    [ harbor.automations_path, harbor.new_automation_path, harbor.edit_automation_path(automation) ].each do |path|
      get path
      assert_response :success
      assert_select "[data-host-mark], [data-host-agent-field], [data-host-trigger-field], [data-host-hint]", count: 0
    end
  end

  test "a host's mark sits beside each automation's name" do
    host_views
    agent_automation
    job_automation
    get harbor.automations_path
    assert_response :success
    assert_select "tr#automation-tidy td:first-child div.flex [data-host-mark=tidy]", text: "agent"
    assert_select "tr#automation-nightly-load td:first-child div.flex [data-host-mark=nightly-load]", text: "job"
  end

  test "a host's fields join the form: after what runs, and after the schedule; a job automation gets only the trigger's" do
    host_views
    Harbor.config.automation_class = "HarborAutomationsPagesTest::HostAutomation"
    get harbor.edit_automation_path(agent_automation)
    assert_response :success
    names = field_names
    assert_equal %w[automation[slash_command] automation[notes] automation[trigger_kind] automation[cron] automation[parcel][carrier] automation[enabled]],
                 names[names.index("automation[slash_command]"), 6]
    assert_select "fieldset:first-of-type [data-host-agent-field=tidy] input[name='automation[notes]'][value='Puts the books back.']"
    assert_select "fieldset:last-of-type [data-host-trigger-field=agent]"

    get harbor.edit_automation_path(job_automation)
    assert_select "[data-host-agent-field]", count: 0
    assert_select "[data-host-trigger-field=job]", count: 1
  end

  test "a host's words replace Harbor's under the fields it speaks for, and only those" do
    host_views
    get harbor.new_automation_path
    assert_select "[data-host-hint=agent]", text: "Only the night shift's agents."
    assert_select "a", text: "Manage agents", count: 0
    assert_select "p", text: /unattended-run preamble are added automatically/
    assert_select "p", text: /Give instructions or a command, not both/
  end

  test "the form saves the host's own attributes only when the host names them" do
    Harbor.config.automation_class = "HarborAutomationsPagesTest::HostAutomation"
    automation = agent_automation
    patch harbor.automation_path(automation), params: { automation: { notes: "The host's words." } }
    assert_redirected_to harbor.automations_path
    assert_equal "Puts the books back.", automation.reload.description, "an attribute the host hasn't named is left out"

    Harbor.config.automation_params = %i[notes]
    patch harbor.automation_path(automation), params: { automation: { notes: "The host's words." } }
    assert_equal "The host's words.", automation.reload.description

    job = job_automation
    patch harbor.automation_path(job), params: { automation: { notes: "Not for jobs." } }
    assert_nil job.reload.description, "a job automation takes Harbor's few fields and no more"
  end

  test "a host is handed the form when an automation is saved from it, before it is checked, and at no other time" do
    saves = []
    Harbor.config.automation_edited = lambda do |automation, user, values|
      saves << [ automation.key, automation.name, user.name ]
      automation.job_input = { "carrier" => values.dig(:parcel, :carrier) }
    end
    create_automation(parcel: { carrier: "the 9:15" })
    assert_redirected_to harbor.automations_path
    automation = Harbor::Automation.find_by!(key: "tidy")
    assert_equal [ [ "tidy", "Tidy the shelf", "Sam Settings" ] ], saves
    assert_equal({ "carrier" => "the 9:15" }, automation.job_input, "what the host set is saved with the rest")

    patch harbor.automation_path(automation), params: { automation: { name: "", parcel: { carrier: "the 10:40" } } }
    assert_response :unprocessable_entity
    assert_equal 2, saves.size, "the host hears before the automation is checked"
    assert_equal({ "carrier" => "the 9:15" }, automation.reload.job_input)

    patch harbor.toggle_automation_path(automation)
    post harbor.run_automation_path(automation)
    automation.update!(name: "Renamed in code")
    assert_equal 2, saves.size, "only the form's saves are the host's to hear about"
  end

  test "a host's automation class is the one the pages build and find, and decides which agents are offered" do
    Harbor.config.automation_class = "HarborAutomationsPagesTest::HostAutomation"
    Harbor::Agent.create!(key: "night-owl", model_alias: @alias, workspace_profile: @workspace)
    get harbor.new_automation_path
    assert_equal [ "Choose an agent", "night-owl" ], css_select("select[name='automation[agent_key]'] option").map(&:text)
    assert_select "input[name='automation[timeout_ms]'][value='120000']"
    assert_select "input[name='automation[name]'][value=Untitled]"

    create_automation(agent_key: "night-owl")
    get harbor.edit_automation_path(Harbor::Automation.find_by!(key: "tidy"))
    assert_response :success
    assert_instance_of HostAutomation, controller.instance_variable_get(:@automation)
  end

  test "a host that runs agent automations its own way has Run now land on its run" do
    automation = agent_automation
    Harbor.config.automation_agent_run = lambda do |fired, triggered_by_user:, **|
      Harbor::Run.create!(automation_id: fired.id, status: "queued", skill: "by-#{triggered_by_user.name.parameterize}")
    end
    post harbor.run_automation_path(automation)
    run = automation.runs.sole
    assert_redirected_to harbor.run_path(run)
    assert_equal "by-sam-settings", run.skill
    assert_no_enqueued_jobs
  end

  # --- the section ---

  test "the pages can be switched off, and nothing scheduled stops" do
    automation = job_automation(cron: "* * * * *", last_scheduled_at: 1.hour.ago)
    Harbor::Setting.set!(:page_automations, "false")
    [ [ :get, harbor.automations_path ], [ :get, harbor.new_automation_path ], [ :get, harbor.edit_automation_path(automation) ],
      [ :post, harbor.automations_path ], [ :patch, harbor.automation_path(automation) ], [ :delete, harbor.automation_path(automation) ],
      [ :post, harbor.run_automation_path(automation) ], [ :patch, harbor.toggle_automation_path(automation) ] ].each do |verb, path|
      process(verb, path)
      assert_response :not_found, "#{verb.upcase} #{path} is still served"
    end
    get "/reports"
    assert_select "[data-harbor-menu] a", text: "Automations", count: 0

    Harbor::Automations::TickJob.perform_now
    assert_equal 1, automation.runs.count
  end

  test "the pages need a login" do
    automation = agent_automation
    delete "/logout"
    [ [ :get, harbor.automations_path ], [ :get, harbor.new_automation_path ], [ :post, harbor.automations_path ],
      [ :post, harbor.run_automation_path(automation) ], [ :delete, harbor.automation_path(automation) ] ].each do |verb, path|
      process(verb, path)
      assert_redirected_to "/login"
    end
    assert_equal 0, automation.runs.count
  end

  test "the pages live under Harbor's path, and the menu links to them" do
    assert_equal "/factory/automations", harbor.automations_path
    get harbor.automations_path
    assert_select "[data-harbor-menu] a.current[href='/factory/automations']", text: "Automations"
    get harbor.new_automation_path
    assert_select "[data-harbor-menu] a.current", text: "Automations"
  end

  test "an automation saved with no key is given one made from its name" do
    2.times do
      post harbor.automations_path, params: { automation: { name: "Morning check", key: "", agent_key: Harbor::Agent.first.key, prompt: "Say hello.",
                                                            trigger_kind: "manual", timeout_ms: 900_000 } }
      assert_redirected_to harbor.automations_path
    end
    assert_equal %w[morning-check morning-check-2], Harbor::Automation.where(name: "Morning check").order(:id).pluck(:key)
  end
end
