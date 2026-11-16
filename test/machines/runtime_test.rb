require "test_helper"

# An "Orca (per workspace)" runtime on the pages: offered only to a site that
# has declared a recipe, added with a form and no JSON, shown in the list and
# on its own page with its machines, and what its backend says about
# readiness and health. Nothing here starts a machine.
class HarborMachinesRuntimeTest < ActionDispatch::IntegrationTest
  include HarborAgentSessions
  include HarborMachines

  Backend = Harbor::Runtimes::Backends::OrcaPerWorkspace

  setup { post "/login", params: { name: "Sam Settings" } }

  def kinds = css_select("input[name='runtime[type]']").map { |input| input["value"] }

  test "a site with no recipe isn't offered the kind, and the form says how to declare one" do
    declare_recipes({})
    get harbor.new_runtime_path
    assert_response :success
    assert_equal [ "orca", "orca:remote", "conductor_cloud" ], kinds
    assert_select "[data-unoffered]", text: /Orca \(per workspace\) starts a machine for each run and removes it afterwards\. To add one, declare a recipe under\s+environment_recipes in .*harbor\.yml/
    assert_not Backend.offered?

    post harbor.runtimes_path, params: { runtime: { name: "Sneaky", type: "orca_per_workspace", max_concurrent: 1, fields: { orca_per_workspace: { recipe: "sandbox" } } } }
    assert_response :unprocessable_entity
    assert_nil Harbor::Runtime.find_by(name: "Sneaky")
  end

  test "a config file that can't be read is said on the form, not hidden" do
    declare_recipes("environment_recipes:\n  box: { create: ./c.sh }\n")
    get harbor.new_runtime_path
    assert_select "[data-unoffered]", text: /Orca \(per workspace\) can't be added: .*environment_recipes\.box: needs destroy:/
    assert_equal "#{Harbor::ConfigFile.label}: environment_recipes.box: needs destroy:, the command that removes the machine (or destroy: none when nothing is to be removed)",
                 @sandbox.unavailable_reason
  end

  test "with a recipe declared the form offers Orca (per workspace) as a fourth kind: a recipe to choose, setup hooks, and no JSON" do
    declare_recipes("sandbox" => recipe, "bare" => recipe.except("name"))
    get harbor.new_runtime_path
    assert_equal [ "orca", "orca:remote", "conductor_cloud", "orca_per_workspace" ], kinds
    assert_select "[data-unoffered]", count: 0
    assert_select "[data-runtime-choice=orca_per_workspace]", text: /Orca \(per workspace\)\s+Each run gets a machine of its own, started by a recipe and removed when the run ends/
    assert_select "[data-choice=orca_per_workspace]" do
      assert_select "select[name='runtime[fields][orca_per_workspace][recipe]'][required] option", count: 3
      assert_select "option[value=sandbox]", text: "Test sandbox · sandbox"
      assert_select "option[value=bare]", text: "bare"
      assert_select "details select[name='runtime[fields][orca_per_workspace][setup]'] option[selected][value=skip]"
      assert_select "textarea", count: 0
      assert_select "input[type=text]", count: 0, message: "no command is ever typed into the form"
    end
  end

  test "a runtime is added from the form, and the list and its page show it like the others" do
    assert_difference("Harbor::Runtime.count", 1) do
      post harbor.runtimes_path, params: { runtime: { name: "AWS boxes", type: "orca_per_workspace", max_concurrent: 4, enabled: "1",
                                                      fields: { orca_per_workspace: { recipe: "sandbox", setup: "run" } } } }
    end
    added = Harbor::Runtime.find_by!(key: "aws-boxes")
    assert_equal [ "orca_per_workspace", 4, nil, { "recipe" => "sandbox", "setup" => "run" } ], [ added.backend, added.max_concurrent, added.host, added.config ]
    assert_equal [ Backend, "Orca (per workspace)", "Test sandbox" ], [ added.backend_class, added.adapter.label, added.adapter.place ]
    assert_nil added.unavailable_reason

    follow_redirect!
    assert_select "tr[data-runtime=aws-boxes][data-state=ok]" do
      assert_select "[data-status]", text: "Taking work"
      assert_select "p", text: "Orca (per workspace) · Test sandbox"
      assert_select "[data-busy]", text: "0 / 4"
    end

    get harbor.edit_runtime_path(added)
    assert_response :success
    assert_equal [ "orca_per_workspace" ], kinds
    assert_select "select[name='runtime[fields][orca_per_workspace][recipe]'] option[selected][value=sandbox]"
    assert_select "select[name='runtime[fields][orca_per_workspace][setup]'] option[selected][value=run]"
    assert_select "[data-machines]", text: /0 machines in use · none left behind/
    assert_select "form[action='#{harbor.sweep_runtime_path(added)}']"

    post harbor.runtimes_path, params: { runtime: { name: "Typo", type: "orca_per_workspace", max_concurrent: 1, fields: { orca_per_workspace: { recipe: "nope" } } } }
    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: /nope is not a recipe declared in/
    post harbor.runtimes_path, params: { runtime: { name: "Blank", type: "orca_per_workspace", max_concurrent: 1 } }
    assert_select "[role=alert]", text: /Choose the recipe that makes the machine/
  end

  test "readiness needs the recipe and a runner address, and warns when that address is this machine's own" do
    assert_nil @sandbox.unavailable_reason
    assert_empty @sandbox.adapter.warnings

    Harbor::Setting.set!(:runner_url, "http://localhost:3000")
    assert_equal [ "The runner address (http://localhost:3000) is this machine's own, which a machine made for a run can't reach. Set one it can reach on the Settings page." ],
                 @sandbox.adapter.warnings
    get harbor.edit_runtime_path(@sandbox)
    assert_select "[data-runtime-health]", text: /is this machine's own, which a machine made for a run can't reach/

    Harbor::Setting.where(key: "runner_url").delete_all
    assert_equal "no runner address set (Settings)", @sandbox.reload.unavailable_reason

    Harbor::Setting.set!(:runner_url, "https://harbor.example.com")
    declare_recipes("other" => recipe)
    assert_equal "the recipe sandbox is not declared in #{Harbor::ConfigFile.label} any more", @sandbox.unavailable_reason
    assert_equal "sandbox (not declared)", @sandbox.adapter.place
    get harbor.edit_runtime_path(@sandbox)
    assert_select "option[selected][value=sandbox]", text: "sandbox (not declared now)"
    @sandbox.update!(config: {})
    assert_equal "no recipe chosen", @sandbox.unavailable_reason
  end

  test "the health check finds the recipe and its scripts, and starts nothing" do
    post harbor.check_runtime_path(@sandbox)
    assert_equal "Sandbox is healthy.", flash[:notice]
    assert_empty recipe_calls
    assert_empty @orca.calls

    plain = File.join(@recipe_dir, "plain.sh")
    File.write(plain, "#!/bin/sh\n")
    declare_recipes("sandbox" => recipe.merge("create" => plain, "destroy" => "#{@recipe_dir}/missing.sh --now"))
    post harbor.check_runtime_path(@sandbox)
    assert_match "the recipe sandbox can't be run: create: #{plain} is not executable (chmod +x); destroy: #{@recipe_dir}/missing.sh is not there", flash[:alert]
    assert_match "Not taking new work: unhealthy", (get(harbor.runtimes_path) && response.body)

    declare_recipes("other" => recipe)
    assert_not @sandbox.reload.check_health!
    assert_match "the recipe \"sandbox\" is not declared", @sandbox.last_error
  end

  test "a run is placed there through a workspace like on any runtime, within its limit" do
    workspace = Harbor::WorkspaceProfile.create!(name: "Boxes", workspace_profile_runtimes_attributes: [ { runtime: @sandbox, position: 0 } ])
    @agent.update!(workspace_profile: workspace)
    run = Harbor::AgentSession.run!(agent: @agent, prompt: "Fix it.")
    assert_equal [ "running", @sandbox.id ], [ run.status, run.runtime_id ]
    assert_equal 1, @sandbox.busy
    provision!
    assert_equal "ready", run.reload.runner_state.dig("machine", "phase")
    assert Backend.enforces_tool_policy?
  end

  test "the runtime's page lists machines in use and the ones that could not be removed; the button sweeps and a person can forget one" do
    declare_recipes("sandbox" => recipe(destroy: "destroy-fail"))
    left = running_machine_session
    post_result(left, 0)
    destroy!
    in_use = running_machine_session
    stuck, busy = machine_of(left), machine_of(in_use)

    get harbor.edit_runtime_path(@sandbox)
    assert_select "[data-machines]", text: /1 machine in use · 1 machine left behind by finished runs/
    assert_select "[data-machines-left] [data-machine='#{stuck.instance_id}']", text: /#{stuck.instance_id} · Test sandbox · run ##{left.id}.*Could not be removed \(1 try, last .* ago\): destroy exited 1/m
    assert_select "[data-machines-in-use] [data-machine='#{busy.instance_id}']", text: /up for .* · run ##{in_use.id}/
    assert_no_match "SECRET", response.body

    clear_enqueued_jobs
    post harbor.sweep_runtime_path(@sandbox)
    assert_redirected_to harbor.edit_runtime_path(@sandbox)
    assert_enqueued_with(job: Harbor::Machines::SweepJob, args: [ @sandbox.id, true ])
    perform_enqueued_jobs(only: Harbor::Machines::SweepJob)
    assert_equal [ "created", 2 ], [ stuck.reload.status, stuck.destroy_attempts ], "tried again at once, and still listed"

    delete harbor.forget_machine_runtime_path(@sandbox, machine_id: busy.id)
    assert_match "is still going", flash[:alert]
    assert_equal "created", busy.reload.status

    delete harbor.forget_machine_runtime_path(@sandbox, machine_id: stuck.id)
    assert_equal "#{stuck.instance_id} forgotten.", flash[:notice]
    assert_equal [ "forgotten", nil ], [ stuck.reload.status, stuck.sealed_result ]
    assert_match "Marked as gone by Sam Settings", stuck.note
    get harbor.edit_runtime_path(@sandbox)
    assert_select "[data-machines-left]", count: 0
  end
end
