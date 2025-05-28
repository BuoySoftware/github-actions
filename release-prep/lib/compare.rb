require "octokit"
require_relative "pull_request"
require_relative "environment_feature_flag"

class Compare
  attr_reader :base_ref, :head_ref

  def initialize(base_ref:, head_ref:)
    @base_ref = base_ref
    @head_ref = head_ref
  end

  def prs
    @prs ||= compare.commits.flat_map do |commit|
      prs = octokit_client.commit_pulls(repository.id, commit.sha)
      if prs.empty?
        puts "No PRs found for commit: #{commit.sha}"
        []
      else
        prs.map do |pr_data|
          pr_commits = octokit_client.pull_request_commits(repository.id, pr_data.number)
          commit_messages = pr_commits.map { |c| c.commit.message }
          PullRequest.new(pr_data, commit_messages: commit_messages)
        end
      end
    end.uniq(&:number)
  end

  def environment_feature_flags
    @environment_feature_flags ||= EnvironmentFeatureFlag.detect(changes:)
  end

  private

  def compare
    @compare ||= octokit_client.compare(
      repository.id,
      @base_ref,
      @head_ref
    )
  end

  def octokit_client
    @octokit_client ||= Octokit::Client.new(access_token: ENV.fetch("GITHUB_PAT"))
  end

  def repository
    @repository ||= octokit_client.repository(
      "#{ENV.fetch('GITHUB_ORG')}/#{ENV.fetch('GITHUB_REPO')}"
    )
  end

  def changes
    @changes ||= compare.files.filter_map(&:patch).flat_map do |patch|
      patch.split("\n").select do |line|
        line.start_with?("+", "-")
      end
    end
  end
end
