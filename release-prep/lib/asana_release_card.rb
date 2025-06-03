require "asana"
require_relative "jira_helper"

class AsanaReleaseCard
  def self.create(release:)
    new(release:).create
  end

  def initialize(release:)
    @release = release
  end

  attr_reader :release

  def create
    puts "Preparing Asana task"

    asana_client = Asana::Client.new do |c|
      c.authentication :access_token, ENV.fetch("ASANA_PAT")
    end

    feature_rows = release.environment_feature_flags.map do |feature|
      <<~HTML
        <tr><td>#{feature}</td><td></td><td></td></tr>
      HTML
    end

    asana_pr_link_list_items = asana_pr_link_map.map do |asana_link, prs|
      pr_links = prs.map do |pr|
        <<~HTML
          <li><a href="#{pr.html_url}">#{ERB::Util.html_escape(pr.title)}</a></li>
        HTML
      end.join
    
      <<~HTML
        <li><a href="#{asana_link}">#{asana_link}</a><ol>#{pr_links}</ol></li>
      HTML
    end.join

    jira_pr_link_list_items = jira_pr_link_map.map do |jira_issue, prs|
      pr_links = prs.map do |pr|
        <<~HTML
          <li><a href="#{pr.html_url}">#{ERB::Util.html_escape(pr.title)}</a></li>
        HTML
      end.join

      <<~HTML
        <li><a href="#{jira_issue_url(jira_issue)}">#{jira_issue.summary}</a><ol>#{pr_links}</ol></li>
      HTML
    end.join

    dependency_pr_list_items = dependency_prs.map do |pr|
      <<~HTML
        <li><a href="#{pr.html_url}">#{ERB::Util.html_escape(pr.title)}</a></li>
      HTML
    end.join

    flagged_pr_list_items = flagged_prs.map do |pr|
      <<~HTML
        <li><a href="#{pr.html_url}">#{ERB::Util.html_escape(pr.title)}</a></li>
      HTML
    end.join

    asana_task_html_notes = <<~HTML.strip
      <body>
      <strong>Github Compare: </strong> <a href="#{release.compare.github_url}">#{release.compare.base_ref}...#{release.compare.head_ref}</a>
        <table>
          <tr>
            <td>Feature Flag</td>
            <td>JP</td>
            <td>CSL</td>
          </tr>
          #{feature_rows}
        </table>
        <strong>PRs with Asana tasks:</strong>
        <ol>#{asana_pr_link_list_items}</ol>

        <strong>PRs with Jira issues:</strong>
        <ol>#{jira_pr_link_list_items}</ol>

        <strong>PRs without Asana tasks:</strong>
        <ol>#{flagged_pr_list_items}</ol>

        <strong>Dependency updates:</strong>
        <ol>#{dependency_pr_list_items}</ol>
      </body>
    HTML

    puts "Creating Release Task"
    release_task = asana_client.tasks.create(
      projects: [ENV.fetch("ASANA_PROJECT_ID")],
      memberships: [
        {
          project: ENV.fetch("ASANA_PROJECT_ID"),
          section: ENV.fetch("ASANA_SECTION_ID"),
        },
      ],
      name: "Wharf #{release.compare.head_ref}",
      html_notes: asana_task_html_notes
    )

    ENV.fetch("ASANA_RELEASE_SUBTASKS", "").split(",").each_slice(2) do |subtask|
      puts "Creating subtask: #{subtask[0]}"
      release_task.add_subtask(
        name: subtask[0],
        assignee: subtask[1],
      )
    end
    release_task.add_subtask(
      name: "Release Prep",
      is_rendered_as_separator: true
    )
  end

  private

  def asana_pr_link_map
    release.pull_requests.map(&:asana_links).flatten.uniq.map do |asana_link|
      [asana_link, release.pull_requests.select { |pr| pr.asana_links.include?(asana_link) }]
    end
  end

  def jira_pr_link_map
    release.pull_requests.map(&:jira_tickets).flatten.uniq.map do |jira_ticket|
      [JiraHelper.client.Issue.find(jira_ticket), release.pull_requests.select { |pr| pr.jira_tickets.include?(jira_ticket) }]
    end
  end

  def jira_issue_url(jira_issue)
    "#{ENV.fetch("ATLASSIAN_URL")}/browse/#{jira_issue.key}"
  end

  def dependency_prs
    release.pull_requests.select do |pr|
      pr.title.match?(/^Bump/i)
    end
  end

  def flagged_prs
    release.pull_requests.select do |pr|
      !pr.title.match?(/^Bump/i) && !pr.asana_links.any? && !pr.jira_tickets.any?
    end
  end
end