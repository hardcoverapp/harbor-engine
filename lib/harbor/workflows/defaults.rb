# The step types, trigger and data that are Harbor's own: what a site with no
# code of its own builds workflows from. A host adds its own beside them, and
# may register one of these ids again to replace it (Harbor::Workflows).
module Harbor
  module Workflows
    # On every step that does work: what the run does when it fails.
    ON_ERROR = { name: "on_error", label: "If it fails", kind: "select",
                 options: [ [ "", "Stop the run" ], [ "continue", "Carry on" ] ] }.freeze

    # The longest a loop may be told to run.
    MAX_LOOP = 20

    PURPLE_PILL = "bg-pale-purple text-ink-purple".freeze
    YELLOW_PILL = "bg-pale-yellow text-ink-yellow".freeze

    # What an agent step's form edits, and what it gives later steps. A host
    # with its own way of running agents builds its fields from these.
    AGENT_FIELDS = [
      { name: "agent", label: "Agent", kind: "agent", required: true,
        help: "An agent, or “agent for <task>” to follow whoever that task is given to." },
      { name: "slash_command", label: "Slash command", kind: "template", placeholder: "review {{input.branch}}",
        help: "Either a slash command or a prompt." },
      { name: "prompt", label: "Prompt", kind: "textarea", placeholder: "Look at {{input.branch}} and…" },
      { name: "session", label: "Session", kind: "select",
        options: [ [ "", "New session" ], [ "continue", "Continue this step's last session" ] ] },
      { name: "timeout_minutes", label: "Timeout (minutes)", kind: "number", placeholder: "60" }
    ].freeze
    AGENT_OUTPUTS = [ [ "text", "string", "the agent's last message" ], [ "run_id", "number", "its Run" ],
                      [ "cost_usd", "number", "what it cost" ], [ "exit_code", "number", "0 when it finished cleanly" ] ].freeze
    AGENT_OUTPUT_FIELD = { name: "outputs", label: "Values it returns", kind: "multi", placeholder: "pr_number",
                           help: "Asked for as a JSON block at the end; each becomes steps.<key>.<value>." }.freeze
    VERDICTS_FIELD = { name: "verdicts", label: "Verdicts", kind: "multi", required: true, placeholder: "approve, changes" }.freeze
    VERIFIER_OUTPUTS = [ [ "verdict", "string", "one of the verdicts" ],
                         [ "feedback", "string", "what must change, or why it passes" ] ].freeze

    # What is wrong with an agent or verifier step, whoever runs it.
    def self.agent_step_errors(step, label)
      errors = []
      errors << "#{label}: name an agent" if step["agent"].blank?
      errors << "#{label}: give either a prompt or a slash command" if step["prompt"].blank? == step["slash_command"].blank?
      if step["type"] == "verifier" && Array(step["verdicts"]).size < 2
        errors << "#{label}: a verifier lists at least two verdicts"
      end
      errors
    end

    def self.agent_step_summary(step, *extra)
      what = step["slash_command"].present? ? "/#{step['slash_command']}" : step["prompt"].to_s.truncate(80)
      bits = [ what, *extra, step["agent"].to_s.sub("task:", "agent for ") ]
      bits << "verdicts: #{Array(step['verdicts']).join(' / ')}" if step["type"] == "verifier"
      bits.join(" · ")
    end
  end
end

Harbor::Workflows.register_trigger "manual",
  label: "Run by hand", group: "Harbor", icon: "play", color: "#4F46E5",
  description: "Started from the workflow page or by another workflow's Run workflow step.",
  summary: ->(_trigger) { "Run by hand" }

Harbor::Workflows.register_data :trigger, "kind", "string", "manual or workflow"
Harbor::Workflows.register_data :trigger, "sender", "string", "who started it"
Harbor::Workflows.register_data :run, "id", "number", "this workflow run"
Harbor::Workflows.register_data :run, "url", "string", "the run page (live view)"

# ── Agents: each runs as an agent session, a tracked Run ──────────────────
Harbor::Workflows.register_step "agent",
  label: "Run an agent", group: "Agents", icon: "bot", color: "#7C5CFC",
  description: "Runs Claude or Codex as a tracked Run. It can return named values for later steps.",
  fields: Harbor::Workflows::AGENT_FIELDS + [ Harbor::Workflows::AGENT_OUTPUT_FIELD, Harbor::Workflows::ON_ERROR ],
  outputs: Harbor::Workflows::AGENT_OUTPUTS, dynamic_outputs: "outputs",
  defaults: { "prompt" => "" },
  runner: "Harbor::Workflows::Steps::Agent", working: true,
  validate: ->(step, label) { Harbor::Workflows.agent_step_errors(step, label) },
  summary: ->(step) { Harbor::Workflows.agent_step_summary(step) },
  short: "Agent", pill: Harbor::Workflows::PURPLE_PILL

Harbor::Workflows.register_step "verifier",
  label: "Review / verify", group: "Agents", icon: "shield", color: "#5B3FA6",
  description: "An agent that must return one verdict from a fixed list, plus feedback.",
  fields: Harbor::Workflows::AGENT_FIELDS + [ Harbor::Workflows::VERDICTS_FIELD, Harbor::Workflows::ON_ERROR ],
  outputs: Harbor::Workflows::VERIFIER_OUTPUTS + Harbor::Workflows::AGENT_OUTPUTS,
  defaults: { "verdicts" => %w[approve changes], "prompt" => "" },
  runner: "Harbor::Workflows::Steps::Agent", working: true,
  validate: ->(step, label) { Harbor::Workflows.agent_step_errors(step, label) },
  summary: ->(step) { Harbor::Workflows.agent_step_summary(step) },
  short: "Verifier", pill: Harbor::Workflows::PURPLE_PILL

# ── Actions: fixed, prompt-free steps ─────────────────────────────────────
Harbor::Workflows.register_step "action", action: "note",
  label: "Note", group: "Harbor", icon: "bell", color: "#4F46E5",
  description: "Writes a line to the app's log.",
  fields: [ { name: "message", label: "Message", kind: "textarea", required: true }, Harbor::Workflows::ON_ERROR ],
  outputs: [ [ "message", "string", "" ] ], defaults: { "message" => "" },
  runner: "Harbor::Workflows::Steps::Note",
  summary: ->(step) { [ step["action"], step["message"].presence&.truncate(60) ].compact.join(" · ") },
  short: "Action", pill: "bg-pale-blue text-ink-blue"

# ── Flow control: the engine walks the first three itself ─────────────────
Harbor::Workflows.register_step "filter",
  label: "Filter", group: "Flow control", icon: "funnel", color: "#16A34A", gate: true,
  gate_note: { where: "a step on the path", reads: "anything before it",
               does: "If it doesn't pass, the run stops there (cleanup still runs)." },
  description: "Continue only if the condition passes; otherwise the run stops here (cleanup still runs).",
  fields: [ { name: "when", label: "Continue only if", kind: "condition", required: true } ],
  outputs: [ [ "passed", "bool", "" ] ], defaults: { "when" => { "path" => "", "op" => "eq", "value" => "" } },
  structural: true, side_effect: false,
  validate: lambda { |step, label|
    next [ "#{label}: a filter needs a condition" ] if step["when"].blank?
    Harbor::Workflows::Condition.validate(step["when"]).map { |error| "#{label}: #{error}" }
  },
  summary: ->(step) { "continue only if #{Harbor::Workflows::Condition.describe(step['when'])}" },
  short: "Filter"

Harbor::Workflows.register_step "choice",
  label: "Router", group: "Flow control", icon: "router", color: "#16A34A", gate: true,
  gate_note: { where: "splits the path", reads: "anything before it",
               does: "Takes the first route whose filter passes, or the fallback route. The routes join again afterwards." },
  description: "Splits into routes. The first route whose filter passes runs, or the fallback. Routes join afterwards.",
  outputs: [ [ "branch", "string", "the route that ran" ] ],
  defaults: { "branches" => [ { "name" => "Route 1", "when" => { "path" => "", "op" => "eq", "value" => "" }, "steps" => [] } ], "otherwise" => [] },
  structural: true, side_effect: false,
  validate: lambda { |step, label|
    branches = Array(step["branches"])
    errors = []
    errors << "#{label}: a choice needs at least one branch" if branches.empty?
    branches.each_with_index do |branch, i|
      errors << "#{label}: branch #{i + 1} has no condition" if branch["when"].blank?
      next if branch["when"].blank?
      errors.concat(Harbor::Workflows::Condition.validate(branch["when"]).map { |error| "#{label} branch #{i + 1}: #{error}" })
    end
    errors
  },
  short: "Router"

Harbor::Workflows.register_step "loop",
  label: "Repeat until", group: "Flow control", icon: "repeat", color: "#16A34A", gate: true,
  gate_note: { where: "wraps steps", reads: "anything, including steps inside it",
               does: "Runs its steps again until the filter passes, at most N times. Result: converged, exhausted or completed." },
  description: "Runs the steps inside again until the filter passes, at most N times.",
  fields: [ { name: "max_iterations", label: "At most (times)", kind: "number", required: true, min: 1, max: Harbor::Workflows::MAX_LOOP },
            { name: "until", label: "Stop repeating when", kind: "condition", scope: "inside" } ],
  outputs: [ [ "result", "string", "converged, exhausted or completed" ], [ "iterations", "number", "passes run" ] ],
  defaults: { "max_iterations" => 3, "steps" => [] },
  structural: true, side_effect: false,
  validate: lambda { |step, label|
    errors = []
    max = step["max_iterations"]
    unless max.is_a?(Integer) && max.between?(1, Harbor::Workflows::MAX_LOOP)
      errors << "#{label}: a loop needs max_iterations between 1 and #{Harbor::Workflows::MAX_LOOP}"
    end
    errors << "#{label}: a loop needs steps" if Array(step["steps"]).empty?
    errors.concat(Harbor::Workflows::Condition.validate(step["until"]).map { |error| "#{label} until: #{error}" }) if step["until"]
    errors
  },
  summary: lambda { |step|
    "up to #{step['max_iterations']}×#{" until #{Harbor::Workflows::Condition.describe(step['until'])}" if step['until']}"
  },
  short: "Repeat"

Harbor::Workflows.register_step "approval",
  label: "Approval", group: "Flow control", icon: "hand", color: "#EA580C", gate: true,
  gate_note: { where: "a step on the path", reads: "—",
               does: "Pauses until a person approves or rejects on the run page. decision is approved or rejected." },
  description: "Pauses until a person approves or rejects on the run page.",
  fields: [ { name: "prompt", label: "Question", kind: "template", placeholder: "Ship it?" } ],
  outputs: [ [ "decision", "string", "approved or rejected" ], [ "by", "string", "who decided" ], [ "note", "string", "" ] ],
  defaults: { "prompt" => "Approve to continue?" },
  runner: "Harbor::Workflows::Steps::Approval",
  summary: ->(step) { step["prompt"].presence || "a person approves or rejects" },
  short: "Approval", pill: Harbor::Workflows::YELLOW_PILL

Harbor::Workflows.register_step "call",
  label: "Run workflow", group: "Flow control", icon: "workflow", color: "#0D9488",
  description: "Runs another workflow and waits for it. Its input becomes input.* there.",
  fields: [ { name: "workflow", label: "Workflow", kind: "workflow", required: true },
            { name: "input", label: "Input", kind: "kv", help: "Values the called workflow reads as input.<name>." },
            Harbor::Workflows::ON_ERROR ],
  outputs: [ [ "result", "string", "succeeded, failed or canceled" ], [ "child_run_id", "number", "" ], [ "steps", "object", "its steps' outputs" ] ],
  defaults: { "input" => {} },
  runner: "Harbor::Workflows::Steps::Call", inside_loop: false,
  validate: ->(step, label) { step["workflow"].blank? ? [ "#{label}: name the workflow to call" ] : [] },
  summary: ->(step) { "runs #{step['workflow']}" },
  short: "Workflow", pill: "bg-pale-green text-ink-green"
