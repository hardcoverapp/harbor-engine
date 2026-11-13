module Harbor
  # The databases a site backs up, and refreshes staging copies of. Connection
  # strings are secrets, so they stay in ENV: a declaration names the ENV keys,
  # never the URLs.
  #
  #   Harbor::Databases.declare "shop",
  #     source_env: "SHOP_DATABASE_URL",            # what is backed up (read only)
  #     staging_env: "SHOP_STAGING_DATABASE_URL",   # what a staging refresh replaces
  #     variants_env: "SHOP_BACKUP_VARIANTS",       # optional: ENV listing the kinds to make
  #     freshness: { "orders" => "created_at" }     # optional: tables that prove it is live
  #
  #   Harbor::Databases.declare "app", own: true    # the app's own database
  #
  # `own: true` is the database Rails itself is connected to: read from Rails's
  # connection, backed up in full only, and never a restore target.
  #
  # A site whose list isn't known until it is asked for (it reads it from ENV,
  # say) declares it in a block, which is run every time the list is read:
  #
  #   Harbor::Databases.declare_each_time do |list|
  #     ENV.fetch("BACKUP_DATABASES", "").split(",").each do |key|
  #       list.declare key, source_env: "#{key.upcase}_DATABASE_URL"
  #     end
  #   end
  #
  # Nothing here needs Greenmask or any database client; those are only run by
  # a backup or a restore (Harbor::DbOps).
  module Databases
    Error = Class.new(StandardError)

    Definition = Struct.new(:key, :label, :source_env, :staging_env, :variants_env, :own, :owner, :freshness, keyword_init: true)

    # Collects declarations, refusing a name that couldn't be a folder or a
    # second database of the same name.
    class List
      KEY = /\A[a-z][a-z0-9_]*\z/

      def initialize
        @definitions = {}
      end

      def declare(key, source_env: nil, staging_env: nil, variants_env: nil, own: false, owner: nil, freshness: nil, label: nil)
        key = key.to_s
        raise Error, "Database names must use lowercase letters, numbers and underscores" unless key.match?(KEY)
        raise Error, "Database #{key} is declared twice" if @definitions.key?(key)
        raise Error, "Database #{key} needs source_env:, the ENV key holding its URL" unless own || source_env.present?

        @definitions[key] = Definition.new(key:, label: label.presence, source_env: source_env&.to_s, staging_env: staging_env&.to_s,
                                           variants_env: variants_env&.to_s, own: own ? true : false, owner: owner.presence,
                                           freshness: (freshness || {}).to_h.transform_keys(&:to_s).transform_values(&:to_s).freeze)
      end

      def declared?(key) = @definitions.key?(key.to_s)

      def definitions = @definitions.values

      def merge!(other)
        other.definitions.each do |definition|
          raise Error, "Database #{definition.key} is declared twice" if declared?(definition.key)
          @definitions[definition.key] = definition
        end
        self
      end
    end

    class << self
      def declare(key, **options) = fixed.declare(key, **options)

      def declare_each_time(&block)
        raise ArgumentError, "declare_each_time needs a block" unless block
        blocks << block
      end

      # Every declared database, in the order declared. Raises Error when a
      # declaration is invalid.
      def definitions
        return fixed.definitions if blocks.empty?

        list = List.new.merge!(fixed)
        blocks.each { |block| block.call(list) }
        list.definitions
      end

      def any? = definitions.any?

      # What the app that owns the `own: true` database is called in messages.
      def app_name
        definitions.find(&:own)&.owner || "this app"
      rescue Error
        "this app"
      end

      # A `Harbor.config` value that may be given as a callable, which is then
      # read each time it is needed.
      def setting(name)
        value = Harbor.config.public_send(name)
        value.respond_to?(:call) ? value.call : value
      end

      # Tests only.
      def reset!
        @fixed = nil
        @blocks = nil
      end

      private
        def fixed = (@fixed ||= List.new)
        def blocks = (@blocks ||= [])
    end
  end
end
