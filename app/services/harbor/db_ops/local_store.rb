require "digest"

module Harbor
  module DbOps
    # The backup folder (`config.backup_root`). Greenmask writes each dump as a
    # directory named by its dump id (a millisecond timestamp), under one
    # folder per database and kind:
    #
    #   <backup root>/
    #     shop/
    #       full/1731182400000/       toc.dat, metadata.json, one .dat.gz per table
    #       cleaned/1731182400000/
    #     shop_cache/
    #       ...
    #
    # Greenmask (`greenmask restore latest`) and pg_restore both read these
    # folders directly.
    class LocalStore
      Error = Class.new(StandardError)

      def self.root = Harbor::Databases.setting(:backup_root).to_s

      attr_reader :root

      def initialize(root: self.class.root)
        @root = File.expand_path(root)
      end

      def absolute(relative)
        path = File.expand_path(relative, @root)
        raise Error, "Invalid backup path" unless path.start_with?("#{@root}/")
        path
      end

      # One digest for a whole dump directory: every file's relative path and
      # SHA-256, in order. Also accepts a single-file archive.
      def self.digest(path)
        return Digest::SHA256.file(path).hexdigest if File.file?(path)
        lines = Dir.glob("**/*", base: path).sort.filter_map do |name|
          file = File.join(path, name)
          "#{name} #{Digest::SHA256.file(file).hexdigest}" if File.file?(file)
        end
        Digest::SHA256.hexdigest(lines.join("\n"))
      end

      # Keep the newest `keep` dump folders (13-digit dump ids) in dir and delete
      # the rest. For dumps Greenmask doesn't manage (MySQL). Returns deleted ids.
      def self.prune_dumps(dir, keep:, logger: nil)
        keep = keep.to_i
        raise Error, "refusing to prune with keep=#{keep}; that would delete every backup" if keep < 1
        ids = Greenmask.dump_ids(dir).sort
        stale = ids[0...-keep] || []
        stale.each do |id|
          logger&.call("[backup] pruning #{File.join(File.basename(File.dirname(dir)), File.basename(dir), id)}")
          FileUtils.rm_rf(File.join(dir, id))
        end
        stale
      end

      def self.size(path)
        return File.size(path) if File.file?(path)
        Dir.glob("**/*", base: path).sum { |name| File.file?(file = File.join(path, name)) ? File.size(file) : 0 }
      end
    end
  end
end
