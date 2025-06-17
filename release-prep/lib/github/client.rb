module Github
  module Client
    private

    def client
      @client ||= Octokit::Client.new(access_token: ENV.fetch("GITHUB_PAT"))
    end

    def repository
      @repository ||= client.repository("#{ENV.fetch('GITHUB_ORG')}/#{ENV.fetch('GITHUB_REPO')}")
    end
  end
end
