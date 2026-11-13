module Harbor
  module DbOps
    # Copies finished dumps to an S3-compatible bucket (Amazon S3, Cloudflare
    # R2, DigitalOcean Spaces, Google Cloud Storage's S3 endpoint…), keeping
    # the backup folder's layout:
    #
    #   <database>/<full|cleaned|staging>/<dump id>/toc.dat, metadata.json, *.dat.gz, heartbeat
    #
    # so developers can run `greenmask restore latest` with an s3 storage whose
    # prefix is <database>/cleaned.
    #
    # Cleaned and full dumps go to SEPARATE buckets: developers get a read-only
    # key for the cleaned bucket only. The full bucket is optional (offsite
    # disaster recovery); unset, full dumps stay in the backup folder. Staging
    # dumps may keep private data, so they share the private full bucket
    # (under <database>/staging/) and never reach developers.
    #
    # The bucket is described in ENV, under a prefix the host names
    # (`config.backup_bucket_env_prefix`): the keys are secrets, and where
    # dumps are sent is decided on the machine.
    #
    # Needs the aws-sdk-s3 gem, loaded only when a bucket is used.
    class BackupBucket
      Error = Class.new(StandardError)
      CREDENTIALS = %w[ENDPOINT ACCESS_KEY_ID SECRET_ACCESS_KEY].freeze
      # Which bucket each kind of dump goes to.
      BUCKETS = { "cleaned" => "CLEANED_BUCKET", "full" => "FULL_BUCKET", "staging" => "FULL_BUCKET" }.freeze
      # Greenmask decides a dump is complete from metadata.json and heartbeat, so
      # they go last: a half-uploaded dump never looks restorable.
      LAST = %w[metadata.json heartbeat].freeze
      # R2 rejects the streaming trailer checksums newer S3 clients send by default.
      CHECKSUM_OPTS = { request_checksum_calculation: "when_required", response_checksum_validation: "when_required" }.freeze

      attr_reader :bucket

      def location = self.class.location

      # The ENV key for one part of the bucket's description ("ENDPOINT").
      def self.env_key(name) = "#{Harbor.config.backup_bucket_env_prefix}_#{name}"

      def self.env(name) = ENV[env_key(name)]

      def self.credential_env = CREDENTIALS.map { |name| env_key(name) }

      def self.bucket_env(variant) = env_key(BUCKETS.fetch(variant))

      def self.bucket_for(variant) = ENV[bucket_env(variant)].to_s.strip.presence

      # Short provider name used as the backup's location ("r2", "spaces", …),
      # from <prefix>_LOCATION or guessed from the endpoint.
      def self.location
        env("LOCATION").presence || case env("ENDPOINT").to_s
                                    when /r2\.cloudflarestorage\.com/ then "r2"
                                    when /digitaloceanspaces\.com/ then "spaces"
                                    when /storage\.googleapis\.com/ then "gcs"
                                    else "s3"
                                    end
      end
      def self.missing_env = credential_env.reject { |key| ENV[key].to_s.strip.present? }

      # nil when no bucket is configured for this kind of dump.
      def self.for(variant)
        bucket = bucket_for(variant)
        return nil unless bucket
        raise Error, "#{bucket_env(variant)} is set but #{missing_env.join(', ')} is not" if missing_env.any?
        new(bucket:)
      end

      def self.load_sdk!
        require "aws-sdk-s3"
      rescue LoadError
        raise Error, "Copying backups to a bucket needs the aws-sdk-s3 gem; add it to the Gemfile"
      end

      def initialize(bucket:, client: nil)
        self.class.load_sdk!
        @bucket = bucket
        @client = client || Aws::S3::Client.new(
          endpoint: ENV.fetch(self.class.env_key("ENDPOINT")),
          region: self.class.env("REGION").presence || "auto",
          access_key_id: ENV.fetch(self.class.env_key("ACCESS_KEY_ID")),
          secret_access_key: ENV.fetch(self.class.env_key("SECRET_ACCESS_KEY")),
          force_path_style: true,
          **CHECKSUM_OPTS,
        )
      end

      # Upload every file in `dir` under `prefix` (<database>/<variant>/<id>).
      # `progress` (optional) is called with the bytes uploaded after each file.
      def upload_dump(dir, prefix:, logger: nil, progress: nil)
        files = Dir.children(dir).select { |name| File.file?(File.join(dir, name)) }
        files = files.sort_by { |name| [ LAST.index(name) || -1, name ] }
        logger&.call("[bucket] uploading #{files.size} files → s3://#{@bucket}/#{prefix}/")
        # TransferManager switches to multipart for large table files.
        transfer = Aws::S3::TransferManager.new(client: @client)
        uploaded = 0
        files.each do |name|
          path = File.join(dir, name)
          transfer.upload_file(path, bucket: @bucket, key: "#{prefix}/#{name}",
                               thread_count: Harbor::Setting.get(:database_upload_threads))
          uploaded += File.size(path)
          progress&.call(uploaded)
        end
        prefix
      end

      # Keep the newest `keep` dump ids under `prefix` (<database>/<variant>),
      # delete the rest. Returns the deleted ids.
      def prune(prefix, keep:, logger: nil)
        keep = keep.to_i
        raise Error, "refusing to prune #{prefix} with keep=#{keep}; that would delete every backup" if keep < 1
        ids = dump_ids(prefix)
        stale = ids.sort[0...-keep] || []
        stale.each do |id|
          logger&.call("[bucket] pruning #{prefix}/#{id}")
          keys("#{prefix}/#{id}/").each_slice(1000) do |batch|
            @client.delete_objects(bucket: @bucket, delete: { objects: batch.map { { key: _1 } } })
          end
        end
        stale
      end

      def dump_ids(prefix)
        ids = []
        token = nil
        loop do
          page = @client.list_objects_v2(bucket: @bucket, prefix: "#{prefix}/", delimiter: "/", continuation_token: token)
          ids.concat(page.common_prefixes.map { _1.prefix.delete_prefix("#{prefix}/").delete_suffix("/") })
          break unless page.is_truncated
          token = page.next_continuation_token
        end
        ids.grep(Greenmask::DUMP_ID)
      end

      def keys(prefix)
        keys = []
        token = nil
        loop do
          page = @client.list_objects_v2(bucket: @bucket, prefix:, continuation_token: token)
          keys.concat(page.contents.map(&:key))
          break unless page.is_truncated
          token = page.next_continuation_token
        end
        keys
      end
    end
  end
end
