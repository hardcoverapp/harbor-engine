module Harbor
  # A record whose key is how code and logs name it. Nobody has to think one
  # up: when it is created without one, the key is made from its name, with a
  # number added when that is taken ("cloud", "cloud-2").
  module KeyFromName
    extend ActiveSupport::Concern

    included { before_validation :generate_key, on: :create }

    private

    def generate_key
      return if key.present? || name.blank?
      base = name.parameterize.presence || self.class.model_name.element
      taken = self.class.unscoped.where("key = ? OR key LIKE ?", base, "#{self.class.sanitize_sql_like(base)}-%").pluck(:key)
      self.key = ([ base ] + (2..taken.size + 2).map { |n| "#{base}-#{n}" }).find { |candidate| taken.exclude?(candidate) }
    end
  end
end
