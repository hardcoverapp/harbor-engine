# Tries "Orca (per workspace)" on one machine against a REAL headless Orca
# server, with no agent and no cloud: the example recipe's create starts
# `orca serve` in a profile of its own, Harbor reaches it with the pairing
# code, adds the repository, makes a worktree and runs a harmless command in a
# terminal there, then destroy stops the server. It prints what it found.
#
# Run it from a checkout of this repository (it uses the test app in
# test/dummy), against a throwaway Postgres and Redis, from a plain terminal:
#
#   DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432 REDIS_URL=redis://127.0.0.1:6379/1 \
#     PROOF_REPO=/path/to/a/scratch/git/clone \
#     bundle exec ruby examples/environment-recipes/try-with-a-local-orca.rb
#
# The runner address it sets answers nothing, so the command's output is not
# posted back: that half, with an agent, is a real site's to try.
#
# PROOF_STANDIN=1 swaps the orca command for stand-ins: a dry run of this
# script, which proves nothing about Orca.
ENV["RAILS_ENV"] ||= "test"
require File.expand_path("test/dummy/config/environment", Dir.pwd)
require "tmpdir"
require "redis-client"

repo = ENV.fetch("PROOF_REPO") { abort "Set PROOF_REPO to a git clone the Orca server can work in (a scratch clone is best)." }
abort "#{repo} is not a git repository" unless File.directory?(File.join(repo, ".git"))
examples = File.expand_path("examples/environment-recipes", Dir.pwd)
work = Dir.mktmpdir("harbor-proof")
ENV["LOCAL_ORCA_PROJECT_ROOT"] = repo
ENV["LOCAL_ORCA_STATE_DIR"] = File.join(work, "state")

standin = ENV["PROOF_STANDIN"] == "1"
if standin
  fake = File.join(work, "orca")
  File.write(fake, "#!/bin/sh\nprintf '{\"schemaVersion\":1,\"pairingCode\":\"orca://pair?standin\",\"projectRoot\":\"#{repo}\"}\\n'\nexec sleep 600\n")
  File.chmod(0o755, fake)
  ENV["LOCAL_ORCA_BIN"] = fake
  Harbor::Orca.runner = lambda do |argv, timeout:|
    result = case argv[1, 2].join(" ")
    when "status --json" then { "runtime" => { "appVersion" => "stand-in", "state" => "ready" } }
    when "worktree create" then { "worktree" => { "id" => "r::#{repo}/wt", "path" => "#{repo}/wt", "branch" => "b" } }
    when "terminal create" then { "terminal" => { "handle" => "term-1", "worktreeId" => "r::#{repo}/wt" } }
    when "terminal wait" then { "wait" => { "satisfied" => false, "status" => "running" } }
    else {}
    end
    [ JSON.generate("ok" => true, "result" => result), "", 0 ]
  end
end

redis = RedisClient.config(url: ENV.fetch("REDIS_URL")).new_pool(size: 2)
Harbor.config.redis = ->(&block) { redis.with(&block) }
Harbor.config.config_file = File.join(work, "harbor.yml")
Harbor.config.log_location = ->(path) { File.join(work, "logs", path) }
File.write(Harbor.config.config_file, { "environment_recipes" => { "local-orca" => {
  "name" => "Local Orca server", "create" => File.join(examples, "local-orca-create.sh"), "destroy" => File.join(examples, "local-orca-destroy.sh"),
  "timeout_seconds" => { "create" => 120, "destroy" => 60 } } } }.to_yaml)
Harbor::ConfigFile.reload!
ActiveJob::Base.queue_adapter = :inline   # create and destroy run right here
# Nothing answers here: the runner script in the terminal keeps its command
# running and keeps trying. The full path, with an agent and the app
# reachable, is a real site's.
Harbor::Setting.set!(:runner_url, "http://127.0.0.1:9")

def say(text) = puts("\n== #{text}")

runtime = Harbor::Runtime.create!(name: "Proof #{SecureRandom.hex(2)}", backend: "orca_per_workspace", max_concurrent: 1, config: { "recipe" => "local-orca" })
say "health check (starts nothing): #{runtime.check_health! ? 'healthy' : runtime.last_error}"
run = Harbor::Run.create!(status: "running", started_at: Time.current, agent_key: "proof", skill: "proof", runtime_id: runtime.id,
                          runner_state: { "cli" => "claude", "attempt" => 1 })
machine = nil
begin
  say "starting: create runs now (a real `orca serve`), then worktree and terminal"
  runtime.adapter.start(run:, command: "echo made-by-harbor > harbor-proof.txt; sleep 30", attempt: 1)
  run.reload
  machine = Harbor::Machine.find_by!(run_id: run.id)
  puts "run status:      #{run.status}#{" (#{run.error})" if run.error}"
  puts "machine:         #{machine.instance_id} · #{machine.status}"
  puts "session:         #{run.runner_state['session'].inspect}"
  puts "pairing code:    #{machine.pairing_code ? 'held, encrypted, on the machine row only' : 'none'}"
  puts "in run columns?  #{run.attributes.to_json.include?('orca://') ? 'YES (a bug)' : 'no'}"
  puts "in the run log?  #{File.read(Harbor::LiveLog.absolute(run.live_log_path)).include?(machine.pairing_code.to_s.presence || 'orca://pair') ? 'YES (a bug)' : 'no'}"
  if (held = Harbor::AgentSession.session_of(run))
    sleep 3
    proof = File.join(held.worktree_path.to_s, "harbor-proof.txt")
    puts "command ran?     #{File.exist?(proof) ? "yes: #{proof} says #{File.read(proof).strip}" : "no file at #{proof}"}" unless standin
    puts "terminal busy?   #{runtime.adapter.exited?(held) ? 'no (exited)' : 'yes'}"
    say "stopping the terminal on the machine"
    puts "closed:          #{runtime.adapter.stop(held)}"
  end
ensure
  say "the run is over: destroy runs now"
  run.reload.finish!(status: "canceled") unless run.finished?
  Harbor::Machines.release(run)
  machine ||= Harbor::Machine.find_by(run_id: run.id)
  if machine
    machine.reload
    puts "machine:         #{machine.status}#{" · #{machine.destroy_error}" if machine.destroy_error}"
    puts "pairing code:    #{machine.sealed_result.nil? ? 'gone' : 'STILL HELD'}"
    puts "server files:    #{Dir.exist?(File.join(ENV['LOCAL_ORCA_STATE_DIR'], machine.instance_id)) ? 'STILL THERE' : 'removed'}"
  end
  say "the run's log"
  puts File.read(Harbor::LiveLog.absolute(run.live_log_path)) rescue puts "(none)"
  Harbor::Machine.where(run_id: run.id).delete_all
  run.destroy
  runtime.destroy
  FileUtils.remove_entry(work) if machine.nil? || machine.done?
end
