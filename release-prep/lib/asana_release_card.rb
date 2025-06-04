require "asana"
require_relative "./jira/issue"

class AsanaReleaseCard
  ASANA_LEGACY_LINK_REGEX = %r{https?://app\.asana\.com/\d+/\d+/\d+}.freeze
  ASANA_LINK_REGEX = %r{https?://app\.asana\.com/\d+/\d+/project/\d+/task/\d+}.freeze

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

    asana_pr_link_list_items = prs_by_asana_link.map do |group|
      asana_link, prs = group.values_at(:link, :prs)

      pr_links = prs.map do |pr|
        <<~HTML
          <li><a href="#{pr.html_url}">#{ERB::Util.html_escape(pr.title)}</a></li>
        HTML
      end.join
    
      <<~HTML
        <li><a href="#{asana_link}">#{asana_link}</a><ol>#{pr_links}</ol></li>
      HTML
    end.join

    jira_pr_link_list_items = prs_by_jira_issue.map do |group|
      jira_issue, prs = group.values_at(:issue, :prs)

      pr_links = prs.map do |pr|
        <<~HTML
          <li><a href="#{pr.html_url}">#{ERB::Util.html_escape(pr.title)}</a></li>
        HTML
      end.join

      <<~HTML
        <li><a href="#{jira_issue.url}">#{jira_issue.summary}</a><ol>#{pr_links}</ol></li>
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
      <strong>Github Compare: </strong> <a href="#{release.github_assets.compare.html_url}">#{release.github_assets.compare.base_ref}...#{release.github_assets.compare.head_ref}</a>
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

    release_task = asana_client.tasks.create(
      projects: [ENV.fetch("ASANA_PROJECT_ID")],
      memberships: [
        {
          project: ENV.fetch("ASANA_PROJECT_ID"),
          section: ENV.fetch("ASANA_SECTION_ID"),
        },
      ],
      name: "#{ENV.fetch("GITHUB_REPO")} #{release.version.name}",
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

  def prs_by_asana_link
    release.github_assets.pull_requests.map(&:body).map do |body|
      [
        *body&.scan(ASANA_LINK_REGEX),
        *body&.scan(ASANA_LEGACY_LINK_REGEX)
      ]
    end.flatten.uniq.map do |link|
      { 
        link:,
        prs: release.github_assets.pull_requests.select { |pr| pr.body&.include?(link) },
      }
    end
  end

  def prs_by_jira_issue
    release.jira_assets.issues.map do |issue|
      {
        issue: issue,
        prs: release.github_assets.pull_requests.select do |pr|
          commit_messages = release.github_assets.commits_by_pull_request.find do |group| 
            group[:pull_request] == pr 
          end[:commits].map(&:commit).map(&:message).join("\n")

          [
            commit_messages.match?(issue.key),
            pr.title.match?(issue.key),
            pr.body&.match?(issue.key),
          ].any?
        end
      }
    end
  end

  def dependency_prs
    release.github_assets.pull_requests.select do |pr|
      pr.user.login.match?("dependabot")
    end
  end

  def flagged_prs
    accounted_for = [
      *prs_by_asana_link.map { |group| group[:prs] }.flatten.uniq,
      *prs_by_jira_issue.map { |group| group[:prs] }.flatten.uniq,
      *dependency_prs,
    ].flatten.uniq

    release.github_assets.pull_requests.select do |pr|
      !accounted_for.include?(pr)
    end
  end
end