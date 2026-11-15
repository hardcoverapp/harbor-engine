require "net/http"
require "json"
require "openssl"

module Harbor
  module ConductorCloud
    # A thin client for Conductor's REST API
    # (https://www.conductor.build/docs/api). Everything Harbor asks of
    # Conductor goes through here.
    #
    # The API key is a secret: whoever builds a client reads it from the
    # environment and passes it in. It is never a setting and never part of a
    # runtime's config, which only names the variable.
    class Client
      class Error < StandardError; end
      # No API key was given. `key_name` says where one was looked for.
      class MissingKey < Error; end
      # Conductor's API, not the session, is having trouble: a 5xx, or no
      # answer at all. Worth asking again; a cloud session keeps going
      # meanwhile.
      class Unavailable < Error; end
      # Conductor has nothing by that id (a 404): a workspace deleted there.
      class NotFound < Error; end

      NETWORK_ERRORS = [ Net::OpenTimeout, Net::ReadTimeout, EOFError, SocketError, OpenSSL::SSL::SSLError,
                         Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ETIMEDOUT ].freeze
      DEFAULT_URL = "https://api.conductor.build".freeze
      DEFAULT_KEY_NAME = "CONDUCTOR_API_KEY".freeze

      # The API refuses some libraries' default user agents, so one is always
      # sent. This one names Harbor and not the site; a host sets its own with
      # `config.conductor_cloud_user_agent`.
      def self.default_user_agent = "harbor-engine/#{Harbor::VERSION}"

      # `key_name` is only what an error calls the missing key. `transport`
      # takes a Net::HTTP request and returns [status code, body text]; tests
      # pass their own, or set Harbor::ConductorCloud.transport.
      def initialize(api_key:, base_url: DEFAULT_URL, key_name: DEFAULT_KEY_NAME, user_agent: nil, transport: nil)
        @api_key = api_key
        @base_url = (base_url.presence || DEFAULT_URL).chomp("/")
        @key_name = key_name
        @user_agent = user_agent.presence || Harbor.config.conductor_cloud_user_agent.presence || self.class.default_user_agent
        @transport = transport || Harbor::ConductorCloud.transport || method(:send_request)
      end

      def configured? = @api_key.present?

      # Creates the workspace and its first session, which starts on `message`.
      # `agent` is "claude" or "codex"; `model` one of Conductor's own ids.
      # With no `branch` the workspace starts from the repository's default.
      # => { "workspaceId", "sessionId", "deepLink", "initialMessage" => {...} }
      def create_workspace(repository_url:, name:, model:, message:, branch: nil, agent: "claude", effort: nil, env: {})
        post("/v0/workspaces", { repositoryUrl: repository_url, branch:, name:, agent:, model:, effort:, message:, env: }.compact)
      end

      # `name` and `repo` are substring searches.
      # => { "data" => [ { "id", "name", "repoUrl", "state", ... } ], "hasMore" }
      def workspaces(name:, repo:, offset: 0, limit: 100)
        get("/v0/workspaces", { name:, repo:, offset:, limit: })
      end

      def create_session(workspace_id:, model:, agent: "claude", effort: nil, message: nil)
        post("/v0/sessions", { workspaceId: workspace_id, agent:, model:, effort:, message: }.compact)
      end

      def rename_workspace(workspace_id, name:) = post("/v0/workspaces/#{workspace_id}/rename", { name: })

      def sections(offset: 0, limit: 100) = get("/v0/sections", { offset:, limit: })

      def create_section(name:) = post("/v0/sections", { name: })

      def move_workspace(workspace_id, section_id:)
        request(Net::HTTP::Put.new(URI("#{@base_url}/v0/workspaces/#{workspace_id}/section")), { sectionId: section_id })
      end

      # => { "status" => "idle" | "working" | "error", "errorMessage", "lastError", ... }
      def session_status(session_id) = get("/v0/sessions/#{session_id}/status")

      # One page of transcript messages after `after` (a message id).
      # => { "data" => [ { "id", "type", "content", ... } ], "hasMore" }
      def messages(session_id, after: nil, limit: 100)
        get("/v0/sessions/#{session_id}/messages", { after:, limit: }.compact)
      end

      # A prompt into an existing session (a new turn, or steered into the
      # running one). => { "messageId", "state" => "queued" | "sent" }
      def send_message(session_id, message) = post("/v0/sessions/#{session_id}/messages", { message: })

      # Stops the session's current turn and drops what was queued for it.
      def cancel_session(session_id) = post("/v0/sessions/#{session_id}/cancel", {})

      # => { "status" => "initializing" | "ready" | "sleeping" | "archived" | "deleted" | ..., "lifecycleStep", "errorMessage" }
      def workspace_status(workspace_id) = get("/v0/workspaces/#{workspace_id}/status")

      def archive_workspace(workspace_id) = post("/v0/workspaces/#{workspace_id}/archive", {})

      private

      def get(path, query = {})
        uri = URI("#{@base_url}#{path}")
        uri.query = URI.encode_www_form(query) if query.any?
        request(Net::HTTP::Get.new(uri))
      end

      def post(path, body) = request(Net::HTTP::Post.new(URI("#{@base_url}#{path}")), body)

      def request(req, body = nil)
        raise MissingKey, "#{@key_name} not set" unless configured?
        unless body.nil?
          req["Content-Type"] = "application/json"
          req.body = JSON.generate(body)
        end
        req["Authorization"] = "Bearer #{@api_key}"
        req["User-Agent"] = @user_agent
        what = "Conductor #{req.method} #{req.uri.path}"
        code, text = @transport.call(req)
        code = code.to_i
        failure = code >= 500 ? Unavailable : (code == 404 ? NotFound : Error)
        begin
          answer = text.to_s.empty? ? {} : JSON.parse(text)
        rescue JSON::ParserError
          raise failure, "#{what} returned unparseable JSON (#{code})"
        end
        return answer if code.between?(200, 299)
        raise failure, "#{what} → #{code}: #{(answer['userMessage'] if answer.is_a?(Hash)) || text.to_s[0, 300]}"
      rescue *NETWORK_ERRORS => e
        raise Unavailable, "#{what} unreachable: #{e.class} #{e.message}"
      end

      def send_request(req)
        res = Net::HTTP.start(req.uri.host, req.uri.port, use_ssl: req.uri.scheme == "https",
                              open_timeout: 10, read_timeout: 60) { |http| http.request(req) }
        [ res.code, res.body ]
      end
    end
  end
end
