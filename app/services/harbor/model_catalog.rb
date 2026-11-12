require "net/http"

module Harbor
  # The models each provider offers, for picking one by name. Read from a
  # public catalog (the `model_catalog_url` setting; models.dev by default),
  # so it needs no API key, lists what is generally available whoever's
  # account runs the work, and picks up new models as they are released.
  #
  #   Harbor::ModelCatalog.fetch(provider)   # => [["Claude Sonnet 5.5 (claude-sonnet-5-5)", "claude-sonnet-5-5"], …]
  #
  # Newest first. Only models that can run an agent are listed: text out, with
  # tool calls.
  class ModelCatalog
    class Unavailable < StandardError; end

    CACHE_KEY = "harbor/model_catalog/v1".freeze
    FRESH_FOR = 12.hours
    MAX_BYTES = 32.megabytes

    class << self
      # What fetches the catalog: called with the address, returns the body or
      # raises Unavailable. nil for the built-in HTTPS download.
      attr_writer :http

      # [[label, id], …] for a provider (a Harbor::ModelProvider or its key).
      # Raises Unavailable when the catalog can't be read and there is no
      # earlier copy to fall back on.
      def fetch(provider)
        key = provider.respond_to?(:key) ? provider.key : provider.to_s
        all.fetch(key, [])
      end

      # Every provider's list, by provider key. A copy older than FRESH_FOR is
      # read again; when that fails the old copy is kept.
      def all
        url = Harbor::Setting.get(:model_catalog_url).to_s.strip
        cached = Rails.cache.read(CACHE_KEY)
        cached = nil unless cached.is_a?(Hash) && cached[:url] == url
        return cached[:models] if cached && cached[:at] > FRESH_FOR.ago

        models = parse((@http || method(:download)).call(url))
        Rails.cache.write(CACHE_KEY, { url: url, at: Time.current, models: models })
        models
      rescue Unavailable
        raise unless cached
        cached[:models]
      end

      def clear = Rails.cache.delete(CACHE_KEY)

      # The catalog's JSON as {provider key => [[label, id], …]}.
      def parse(body)
        catalog = JSON.parse(body)
        raise Unavailable, "The model catalog is not in the expected format." unless catalog.is_a?(Hash)

        Harbor::ModelProvider::KEYS.index_with do |key|
          entries = catalog.dig(key, "models")
          entries = entries.values if entries.is_a?(Hash)
          Array(entries).select { |model| runs_agents?(model) }
                        .sort_by { |model| [ model["release_date"].to_s, model["id"].to_s ] }.reverse
                        .map { |model| [ label(model), model["id"] ] }.uniq(&:last)
        end
      rescue JSON::ParserError
        raise Unavailable, "The model catalog is not valid JSON."
      end

      private

      def runs_agents?(model)
        return false unless model.is_a?(Hash) && model["id"].present?
        return false if model["status"].to_s == "deprecated"
        return false if model["tool_call"] == false
        outputs = model.dig("modalities", "output")
        outputs.nil? || Array(outputs).include?("text")
      end

      def label(model)
        name = model["name"].presence
        name && name != model["id"] ? "#{name} (#{model['id']})" : model["id"]
      end

      def download(url, redirects: 3)
        uri = URI.parse(url)
        raise Unavailable, "Set the model catalog address on the Settings page to an https URL." unless uri.is_a?(URI::HTTPS)

        request = Net::HTTP::Get.new(uri)
        request["User-Agent"] = "harbor-engine"
        request["Accept"] = "application/json"
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 20) { |http| http.request(request) }
        if response.is_a?(Net::HTTPRedirection) && redirects.positive? && response["location"].present?
          return download(URI.join(url, response["location"]).to_s, redirects: redirects - 1)
        end
        raise Unavailable, "The model catalog returned HTTP #{response.code}." unless response.is_a?(Net::HTTPSuccess)
        raise Unavailable, "The model catalog is larger than expected." if response.body.to_s.bytesize > MAX_BYTES

        response.body
      rescue URI::InvalidURIError
        raise Unavailable, "The model catalog address on the Settings page is not a valid URL."
      rescue Timeout::Error, SocketError, SystemCallError, IOError, Net::HTTPBadResponse, OpenSSL::SSL::SSLError
        raise Unavailable, "Could not reach the model catalog."
      end
    end
  end
end
