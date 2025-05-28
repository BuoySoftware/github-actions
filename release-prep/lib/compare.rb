require "octokit"
require_relative "environment_feature_flag"
require_relative "octokit_helper"
require_relative "pull_request"

class Compare
  attr_reader :base_ref, :head_ref

  def initialize(base_ref:, head_ref:)
    @base_ref = base_ref
    @head_ref = head_ref
  end

  def pull_requests
    @pull_requests ||= PullRequest.detect(compare:)
  end

  def environment_feature_flags
    @environment_feature_flags ||= EnvironmentFeatureFlag.detect(changes:)
  end

  private

  def compare
    @compare ||= OctokitHelper.client.compare(
      OctokitHelper.repository.id,
      @base_ref,
      @head_ref
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
