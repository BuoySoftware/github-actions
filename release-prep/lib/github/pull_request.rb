require_relative "client"

module Github
  class PullRequest < SimpleDelegator
    include Client

    def commit_messages
      @commit_messages ||= commits.map { |c| c.commit.message }
    end

    def commits
      @commits ||= client.pull_request_commits(repository.id, number)
    end

    def text
      @text ||= [
        title,
        body,
        commit_messages,
      ].join("\n")
    end

    private

    def client
      @client ||= Octokit::Client.new(access_token: ENV.fetch("GITHUB_PAT"))
    end

    def repository
      @repository ||= client.repository("#{ENV.fetch('GITHUB_ORG')}/#{ENV.fetch('GITHUB_REPO')}")
    end
  end
end
