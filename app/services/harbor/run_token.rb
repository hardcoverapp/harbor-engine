module Harbor
  # A token a runner proves itself with: signed by this app, good for one run
  # and a limited time. It lets its holder append to that run's log and report
  # its result, and nothing else.
  module RunToken
    PURPOSE = "harbor.run".freeze
    LIFETIME = 48.hours

    module_function

    def generate(run, expires_in: LIFETIME)
      verifier.generate(run.id, purpose: PURPOSE, expires_in: expires_in)
    end

    # Whether `token` was issued for the run with this id and is still good.
    def valid?(token, run_id)
      return false if token.blank?
      issued_for = verifier.verified(token, purpose: PURPOSE)
      issued_for.present? && issued_for.to_s == run_id.to_s
    end

    def verifier = Rails.application.message_verifier(PURPOSE)
  end
end
