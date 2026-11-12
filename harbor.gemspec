require_relative "lib/harbor/version"

Gem::Specification.new do |spec|
  spec.name        = "harbor"
  spec.version     = Harbor::VERSION
  spec.authors     = [ "Hardcover" ]
  spec.summary     = "Runs agent work: workflows, runs, runtimes, agents and models."
  spec.homepage    = "https://github.com/hardcoverapp/harbor-engine"
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.3"

  # Not published yet. Guards against an accidental `gem push`.
  spec.metadata["allowed_push_host"] = "https://rubygems.invalid"

  spec.files = Dir.chdir(__dir__) { Dir["{app,config,db,lib}/**/*", "LICENSE", "README.md"] }

  spec.add_dependency "rails", ">= 8.1"
end
