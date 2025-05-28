require "octokit"

class OctokitHelper
  def self.client
    @octokit_client ||= Octokit::Client.new(access_token: ENV.fetch("GITHUB_PAT"))
  end

  def self.repository
    @repository ||= client.repository(
      "#{ENV.fetch('GITHUB_ORG')}/#{ENV.fetch('GITHUB_REPO')}"
    )
  end
end