require "octokit"
require_relative "environment_feature_flag"
require_relative "octokit_helper"
require_relative "pull_request"

class Compare
  def initialize(base_ref:, head_ref:)
    @base_ref = base_ref
    @head_ref = head_ref
  end

  attr_reader :base_ref, :head_ref

  def environment_feature_flags
    @environment_feature_flags ||= EnvironmentFeatureFlag.detect(changes:)
  end

  def jira_projects
    @jira_projects ||= pull_requests.flat_map(&:jira_projects).uniq
  end

  def pull_requests
    @pull_requests ||= PullRequest.detect(commits:)
  end

  def github_url
    @github_url ||= compare.html_url
  end

  private

  def changes
    @changes ||= compare.files.filter_map(&:patch).flat_map do |patch|
      patch.split("\n").select do |line|
        line.start_with?("+", "-")
      end
    end
  end

  def compare
    @compare ||= OctokitHelper.client.compare(
      OctokitHelper.repository.id,
      @base_ref,
      @head_ref
    )
  end

  def commits
    @commits ||= compare.commits
  end
end
