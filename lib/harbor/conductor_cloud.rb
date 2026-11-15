require "harbor/conductor_cloud/client"
require "harbor/conductor_cloud/models"

module Harbor
  # Conductor Cloud (https://www.conductor.build) runs an agent in a cloud
  # workspace it makes from a repository. Harbor reaches it through its REST
  # API (Client); a runtime of this kind is
  # Harbor::Runtimes::Backends::ConductorCloud, and an agent session there is
  # followed by asking (Harbor::ConductorCloud::SessionPoll).
  module ConductorCloud
    class << self
      # What sends a request for a client that isn't given a transport of its
      # own: something taking a Net::HTTP request and returning [status code,
      # body text]. nil: a real HTTPS request. Tests set a stand-in, so code
      # that builds its own client never reaches the real service.
      attr_accessor :transport
    end
  end
end
