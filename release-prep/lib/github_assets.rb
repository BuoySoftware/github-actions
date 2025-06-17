require "octokit"

require_relative "github/client"
require_relative "github/pull_request"

class GithubAssets
  include Github::Client

  def initialize(base_ref:, head_ref:)
    @base_ref = base_ref
    @head_ref = head_ref
  end

  attr_reader :base_ref, :head_ref

  def changes
    @changes ||= compare.files.filter_map(&:patch).flat_map do |patch|
      patch.split("\n").select do |line|
        line.start_with?("+", "-")
      end
    end
  end

  def compare
    @compare ||= client.compare(repository.id, base_ref, head_ref)
  end

  def commit_messages
    @commit_messages ||= commits.map { |c| c.commit.message }
  end

  def commits
    @commits ||= compare.commits
  end

  def compare_url
    @compare_url ||= compare.html_url
  end

  def pull_requests
    @pull_requests ||= commits.flat_map.with_index do |commit, index|
      puts "Processing commit #{index + 1} of #{commits.size}: #{commit.sha}"
      client.commit_pulls(repository.id, commit.sha).map do |pull_request|
        Github::PullRequest.new(pull_request)
      end
    end.uniq(&:number)
  end

  def commits_by_pull_request
    @commits_by_pull_request ||= pull_requests.map do |pull_request|
      {
        pull_request:,
        commits: client.pull_request_commits(repository.id, pull_request.number),
      }
    end
  end
end
