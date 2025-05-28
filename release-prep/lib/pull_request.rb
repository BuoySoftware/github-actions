require_relative "octokit_helper"

class PullRequest
  ASANA_LEGACY_LINK_REGEX = %r{https?://app\.asana\.com/\d+/\d+/\d+}.freeze
  ASANA_LINK_REGEX = %r{https?://app\.asana\.com/\d+/\d+/project/\d+/task/\d+}.freeze
  JIRA_TICKET_REGEX = %r{[A-Z]+-\d+}.freeze

  def self.detect(compare:)
    compare.commits.flat_map do |commit|
      OctokitHelper.client.commit_pulls(OctokitHelper.repository.id, commit.sha)
    end.uniq(&:number).map do |pr_data|
      new(
        number: pr_data.number,
        title: pr_data.title,
        body: pr_data.body,
      )
    end
  end

  def initialize(body:, number:, title:)
    @body = body
    @number = number
    @title = title
  end

  attr_reader :body, :number, :title

  def asana_links
    @asana_links ||= [
      *body.scan(ASANA_LINK_REGEX),
      *body.scan(ASANA_LEGACY_LINK_REGEX)
    ].uniq
  end

  def jira_tickets
    @jira_tickets ||= [
      *title.scan(JIRA_TICKET_REGEX),
      *body.scan(JIRA_TICKET_REGEX),
      *commit_messages.map { |message| message.scan(JIRA_TICKET_REGEX) }.flatten
    ].uniq
  end

  private

  def commit_messages
    @commit_messages ||= commits.map { |c| c.commit.message }
  end

  def commits
    @commits ||= OctokitHelper.client.pull_request_commits(OctokitHelper.repository.id, number)
  end
end