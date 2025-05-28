require "octokit"
require_relative "pull_request"

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
          puts "PR: #{pr_data.title}"
          PullRequest.new(pr_data, commit_messages: commit_messages)
        end
      end
    end.uniq(&:number)
  end

  def changes
    @changes ||= compare.files.filter_map(&:patch).flat_map do |patch|
      patch.split("\n").select do |line|
        line.start_with?("+", "-")
      end
    end
  end

  def features
    feature_module_regex = /(Feature(::[\w]+)+)/
    underscore_regex = /(?<=[a-z])(?=[A-Z])|::/
    features = []
    changes.compact.flatten.each_with_index do |change, index|
      puts "Scraping change: #{index + 1} of #{changes.count}"

      # Infer and collect usages of environment feature flags
      feature_module = change.match(feature_module_regex)&.to_s
      if feature_module
        feature = feature_module
          .gsub(underscore_regex, "_")
          .upcase
          .gsub("FEATURE_", "") + "_ENABLED"

        unless features.include?(feature)
          puts "Environment feature flag usage detected: #{feature}"
          features << feature
        end
      end
    end
    features
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
end
