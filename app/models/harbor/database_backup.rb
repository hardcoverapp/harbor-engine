module Harbor
  # Catalog of database dumps (see DbOps::LocalStore for the folder layout).
  # `path` is relative to the backup folder and doubles as the object key in
  # buckets: <database>/<kind>/<greenmask dump id>.
  #
  # `copies` records where the dump is stored, keyed by location:
  #   "local" => { "path" => ..., "at" => ... }                  the backup folder
  #   "r2"    => { "bucket" => ..., "key" => ..., "at" => ... }  a bucket provider
  # Retention removes a location's entry when it deletes that copy; the row goes
  # once no copy is left.
  class DatabaseBackup < ApplicationRecord
    self.table_name = "database_backups"

    LOCAL = "local".freeze
    LOCATION_LABELS = { LOCAL => "Backup drive", "r2" => "Cloudflare R2", "spaces" => "DigitalOcean Spaces",
                        "gcs" => "Google Cloud Storage", "s3" => "S3" }.freeze

    belongs_to :run, class_name: Harbor.class_name_for(:run_class), optional: true
    validates :database_key, :variant, :path, :bytes, :sha256, presence: true
    validates :variant, inclusion: { in: DbOps::Database::VARIANTS }
    scope :recent, -> { order(created_at: :desc) }

    def self.location_label(name) = LOCATION_LABELS.fetch(name, name.to_s.titleize)

    def folder = DbOps::LocalStore.new.absolute(path)

    # The Greenmask dump directory, or the single .dump file older backups used.
    # pg_restore reads either. MySQL dumps are a .sql.gz inside the folder.
    def archive_path
      legacy = File.join(folder, "#{database_key}.dump")
      File.file?(legacy) ? legacy : folder
    end

    def on_disk?
      [ "toc.dat", "#{database_key}.dump", DbOps::Mysql.dump_name(database_key) ].any? { |name| File.file?(File.join(folder, name)) }
    end
    def cleaned? = variant == "cleaned"
    # Made with masking rules: what a restore that names no kind may use.
    def masked? = DbOps::Database::MASKED.include?(variant)
    def dump_id = File.basename(path)

    # Location name => present?, local first. The folder is checked live, since
    # a dump can be deleted by hand; bucket copies are as recorded.
    def locations
      names = [ LOCAL, *(copies.keys - [ LOCAL ]).sort ]
      names.index_with { |name| name == LOCAL ? on_disk? : copies.key?(name) }
    end

    def record_copy!(location, **info)
      update!(copies: copies.merge(location => info.stringify_keys.merge("at" => Time.current.iso8601)))
    end

    # Forget a deleted copy; returns true when the row was removed with it.
    def forget_copy!(location)
      remaining = copies.except(location)
      remaining = remaining.except(LOCAL) unless on_disk?
      return destroy! && true if remaining.empty?
      update!(copies: remaining)
      false
    end
  end
end
