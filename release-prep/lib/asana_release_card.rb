require "asana"
require_relative "jira/issue"

class AsanaReleaseCard
  ASANA_LEGACY_LINK_REGEX = %r{https?://app\.asana\.com/\d+/\d+/\d+}
  ASANA_LINK_REGEX = %r{https?://app\.asana\.com/\d+/\d+/project/\d+/task/\d+}

  def self.create(release:)
    new(release:).create
  end

  def initialize(release:)
    @release = release
  end

  attr_reader :release

  def create
    puts "Preparing Asana task"

    release_task = create_release_task
    create_subtasks(release_task)
    release_task
  end

  private

  def create_release_task
    client.tasks.create(
      projects: [ENV.fetch("ASANA_PROJECT_ID")],
      memberships: asana_memberships,
      name: "#{ENV.fetch('GITHUB_REPO')} #{release.version.name}",
      html_notes: generate_html_notes
    )
  end

  def client
    @client ||= Asana::Client.new do |c|
      c.authentication :access_token, ENV.fetch("ASANA_PAT")
    end
  end

  def asana_memberships
    [
      {
        project: ENV.fetch("ASANA_PROJECT_ID"),
        section: ENV.fetch("ASANA_SECTION_ID"),
      },
    ]
  end

  def create_subtasks(release_task)
    subtask_pairs.each do |subtask|
      puts "Creating subtask: #{subtask[0]}"
      release_task.add_subtask(
        name: subtask[0],
        assignee: subtask[1]
      )
    end
    release_task.add_subtask(
      name: "Release Prep",
      is_rendered_as_separator: true
    )
  end

  def subtask_pairs
    ENV.fetch("ASANA_RELEASE_SUBTASKS", "").split(",").each_slice(2)
  end

  def generate_html_notes
    <<~HTML.strip
      <body>
      <strong>Github Compare: </strong> <a href="#{release.github_assets.compare_url}">#{release.github_assets.base_ref}...#{release.github_assets.head_ref}</a>
        #{generate_feature_flags_table}
        #{generate_pr_sections}
      </body>
    HTML
  end

  def generate_feature_flags_table
    <<~HTML
      <table>
        <tr>
          <td>Feature Flag</td>
          <td>JP</td>
          <td>CSL</td>
        </tr>
        #{feature_flag_rows}
      </table>
    HTML
  end

  def feature_flag_rows
    release.environment_feature_flags.map { |feature| feature_flag_row(feature) }.join
  end

  def feature_flag_row(feature)
    <<~HTML
      <tr><td>#{feature}</td><td></td><td></td></tr>
    HTML
  end

  def generate_pr_sections
    [
      generate_section("PRs with Asana tasks:", generate_asana_pr_links),
      generate_section("PRs with Jira issues:", generate_jira_pr_links),
      generate_section("PRs without Asana tasks:", generate_flagged_pr_links),
      generate_section("Dependency updates:", generate_dependency_pr_links),
    ].join("\n")
  end

  def generate_section(title, content)
    <<~HTML
      <strong>#{title}</strong>
      <ol>#{content}</ol>
    HTML
  end

  def generate_asana_pr_links
    prs_by_asana_link.map do |group|
      asana_link, prs = group.values_at(:link, :prs)
      pr_links = generate_pr_links(prs)

      <<~HTML
        <li><a href="#{asana_link}">#{asana_link}</a><ol>#{pr_links}</ol></li>
      HTML
    end.join
  end

  def generate_jira_pr_links
    prs_by_jira_issue.map do |group|
      jira_issue, prs = group.values_at(:issue, :prs)
      pr_links = generate_pr_links(prs)

      <<~HTML
        <li><a href="#{jira_issue.url}">#{jira_issue.summary}</a><ol>#{pr_links}</ol></li>
      HTML
    end.join
  end

  def generate_flagged_pr_links
    generate_pr_links(flagged_prs)
  end

  def generate_dependency_pr_links
    generate_pr_links(dependency_prs)
  end

  def generate_pr_links(prs)
    prs.map do |pr|
      <<~HTML
        <li><a href="#{pr.html_url}">#{ERB::Util.html_escape(pr.title)}</a></li>
      HTML
    end.join
  end

  def prs_by_asana_link
    links = asana_links_from_pull_requests
    links.map { |link| asana_link_group(link) }
  end

  def asana_links_from_pull_requests
    release.github_assets.pull_requests.map(&:body).flat_map do |body|
      [
        *body&.scan(ASANA_LINK_REGEX),
        *body&.scan(ASANA_LEGACY_LINK_REGEX),
      ]
    end.uniq
  end

  def asana_link_group(link)
    {
      link: link,
      prs: release.github_assets.pull_requests.select { |pr| pr.body&.include?(link) },
    }
  end

  def prs_by_jira_issue
    release.jira_assets.issues.map do |issue|
      {
        issue: issue,
        prs: prs_related_to_jira_issue(issue),
      }
    end
  end

  def prs_related_to_jira_issue(issue)
    release.github_assets.pull_requests.select do |pr|
      commit_messages = commit_messages_for_pr(pr)
      [
        commit_messages.match?(issue.key),
        pr.title.match?(issue.key),
        pr.body&.match?(issue.key),
      ].any?
    end
  end

  def commit_messages_for_pr(pull_request)
    group = release.github_assets.commits_by_pull_request.detect { |g|
      g[:pull_request] == pull_request
    }
    group[:commits].map(&:commit).map(&:message).join("\n")
  end

  def dependency_prs
    release.github_assets.pull_requests.select do |pr|
      pr.user.login.match?("dependabot")
    end
  end

  def flagged_prs
    accounted_for = collected_accounted_prs
    release.github_assets.pull_requests.reject { |pr| accounted_for.include?(pr) }
  end

  def collected_accounted_prs
    [
      *prs_by_asana_link.flat_map { |group| group[:prs] },
      *prs_by_jira_issue.flat_map { |group| group[:prs] },
      *dependency_prs,
    ].uniq
  end
end
