require_relative "jira/issue"

class JiraReleaseCard
  ASANA_LEGACY_LINK_REGEX = %r{https?://app\.asana\.com/\d+/\d+/\d+}
  ASANA_LINK_REGEX = %r{https?://app\.asana\.com/\d+/\d+/project/\d+/task/\d+}
  JIRA_TICKET_REGEX = /[A-Z]+-\d+/

  def self.create_or_update(release:)
    new(release:).create_or_update
  end

  def initialize(release:)
    @release = release
  end

  attr_reader :release

  def create_or_update
    if existing_release_card
      puts "Release card found: #{existing_release_card.attrs['key']}"
      existing_release_card.save(payload)
      existing_release_card
    else
      puts "Creating release card: #{summary}"
      Jira::Issue.create(payload)
    end
  end

  private

  def existing_release_card
    @existing_release_card ||= Jira::Issue.find_by_summary(summary)
  end

  def payload
    {
      "fields" => {
        "project" => { "key" => "VERSIONS" },
        "summary" => summary,
        "issuetype" => { "name" => "Version" },
        "description" => description,
        "customfield_10298" => release.version.number,
        "customfield_10297" => { "value" => ENV.fetch("GITHUB_REPO") },
        "customfield_10363" => release.jira_assets.release_note.url,
      },
    }
  end

  def summary
    "#{ENV.fetch('GITHUB_REPO')} #{release.version.name}"
  end

  def description
    [
      generate_header,
      generate_metadata_table,
      generate_issues_by_project,
      asana_tasks,
      generate_feature_flags_table,
      generate_pull_requests_section,
    ].join("\n\n")
  end

  def generate_header
    "h1. #{summary}"
  end

  def generate_metadata_table
    <<~MARKDOWN
      ||Version||#{release.version.name}|
      ||Base Ref||#{release.github_assets.base_ref}|
      ||Head Ref||#{release.github_assets.head_ref}|
      ||Github Compare||[#{release.github_assets.base_ref}...#{release.github_assets.head_ref}|#{release.github_assets.compare_url}]|
      ||Project Versions||#{project_versions}|
    MARKDOWN
  end

  def generate_issues_by_project
    <<~MARKDOWN
      h2. Issues By Project

      #{release.jira_assets.issues_by_project.map do |group|
        project, issues = group.values_at(:project, :issues)

        <<~MARKDOWN
          h3. #{project.name}
          #{issues.map do |issue|
            " - #{issue.key}"
          end.join("\n")}
        MARKDOWN
      end.join("\n\n")}
    MARKDOWN
  end

  def generate_feature_flags_table
    <<~MARKDOWN
      h2. Referenced Environment Feature Flags

      ||Environment Feature Flage||Enabled||
      #{release.environment_feature_flags.map do |feature|
        "|#{feature}|false|"
      end.join("\n")}
    MARKDOWN
  end

  def generate_pull_requests_section
    <<~MARKDOWN
      h2. Pull Requests

      #{pull_requests_by_group.map do |group|
        <<~MARKDOWN
          h3. #{group[:group]}
          #{group[:pull_requests].map do |pr|
            " - [##{pr.number}: #{pr.title}|#{pr.html_url}]"
          end.join("\n")}
        MARKDOWN
      end.join("\n\n")}
    MARKDOWN
  end

  def project_versions
    release.jira_assets.versions_by_project.map do |group|
      project, version = group.values_at(:project, :version)
      url = "#{ENV.fetch('ATLASSIAN_URL')}/projects/#{project.key}/versions/#{version.attrs['id']}"

      "[#{project.key}|#{url}]"
    end.join("\n")
  end

  def asana_tasks
    prs_by_asana_link = jira_asana_prs_by_link
    prs_by_asana_link.any? ? asana_tasks_markdown(prs_by_asana_link) : ""
  end

  def jira_asana_prs_by_link
    asana_links_from_pull_requests.map { |link| jira_asana_link_group(link) }
  end

  def asana_links_from_pull_requests
    release.github_assets.pull_requests.map(&:body).flat_map do |body|
      [
        *body&.scan(ASANA_LINK_REGEX),
        *body&.scan(ASANA_LEGACY_LINK_REGEX),
      ]
    end.uniq
  end

  def jira_asana_link_group(link)
    {
      link: link,
      prs: release.github_assets.pull_requests.select { |pr| pr.body&.include?(link) },
    }
  end

  def asana_tasks_markdown(prs_by_asana_link)
    <<~MARKDOWN
      ----

      h2. Asana Tasks

      #{prs_by_asana_link.map { |group| asana_task_group_markdown(group) }.join("\n")}
    MARKDOWN
  end

  def asana_task_group_markdown(group)
    [
      " # #{group[:link]}",
      *group[:prs].map { |pr| " *# [##{pr.number}: #{pr.title}|#{pr.html_url}]" },
    ].join("\n")
  end

  def pull_requests_by_group
    %w[Associated Asana Unassociated Dependencies].map do |group_name|
      pull_request_group_hash(group_name)
    end
  end

  def pull_request_group_hash(group_name)
    {
      group: group_name,
      pull_requests: pull_requests_by_group_name(group_name),
    }
  end

  def pull_requests_by_group_name(group_name)
    categorized = categorize_pull_requests
    case group_name
    when "Associated" then categorized[:associated]
    when "Asana" then categorized[:asana]
    when "Unassociated" then categorized[:unassociated]
    when "Dependencies" then categorized[:dependencies]
    else []
    end
  end

  def categorize_pull_requests
    categorized = empty_pull_request_categories
    release.github_assets.commits_by_pull_request.each do |group|
      pull_request, commits = group.values_at(:pull_request, :commits)
      commit_messages = commits.map(&:commit).map(&:message).join("\n")
      category = categorize_single_pull_request(pull_request, commit_messages)
      categorized[category] << pull_request
    end
    categorized
  end

  def empty_pull_request_categories
    {
      associated: [],
      asana: [],
      dependencies: [],
      unassociated: [],
    }
  end

  def categorize_single_pull_request(pull_request, commit_messages)
    if jira_reference?(pull_request, commit_messages)
      :associated
    elsif asana_reference?(pull_request, commit_messages)
      :asana
    elsif pull_request.user.login.match?("dependabot")
      :dependencies
    else
      :unassociated
    end
  end

  def jira_reference?(pull_request, commit_messages)
    [
      commit_messages.match?(JIRA_TICKET_REGEX),
      pull_request.title.match?(JIRA_TICKET_REGEX),
      pull_request.body&.match?(JIRA_TICKET_REGEX),
    ].any?
  end

  def asana_reference?(pull_request, commit_messages)
    [
      pull_request.body&.match?(ASANA_LINK_REGEX),
      pull_request.body&.match?(ASANA_LEGACY_LINK_REGEX),
      commit_messages.match?(ASANA_LINK_REGEX),
      commit_messages.match?(ASANA_LEGACY_LINK_REGEX),
    ].any?
  end
end
