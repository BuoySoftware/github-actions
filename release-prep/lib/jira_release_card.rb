require_relative "./jira/issue"

class JiraReleaseCard
  ASANA_LEGACY_LINK_REGEX = %r{https?://app\.asana\.com/\d+/\d+/\d+}.freeze
  ASANA_LINK_REGEX = %r{https?://app\.asana\.com/\d+/\d+/project/\d+/task/\d+}.freeze
  JIRA_TICKET_REGEX = %r{[A-Z]+-\d+}.freeze

  def self.create_or_update(release:)
    new(release:).create_or_update
  end

  def initialize(release:)
    @release = release
  end

  attr_reader :release

  def create_or_update
    if existing_release_card
      puts "Release card found: #{existing_release_card.attrs["key"]}"
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
        "customfield_10363" => release.jira_assets.release_note.url
      },
    }
  end

  def summary
    "#{ENV.fetch("GITHUB_REPO")} #{release.version.name}"
  end

  def description
    <<~MARKDOWN
    h1. #{summary}

    ||Version||#{release.version.name}|
    ||Base Ref||#{release.github_assets.base_ref}|
    ||Head Ref||#{release.github_assets.head_ref}|
    ||Github Compare||[#{release.github_assets.base_ref}...#{release.github_assets.head_ref}|#{release.github_assets.compare_url}]|
    ||Project Versions||#{project_versions}|

    ----

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

    #{asana_tasks}

    ----

    h2. Referenced Environment Feature Flags

    ||Environment Feature Flage||Enabled||
    #{release.environment_feature_flags.map do |feature|
      "|#{feature}|false|"
    end.join("\n")}

    ----

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
      url = "#{ENV.fetch("ATLASSIAN_URL")}/projects/#{project.key}/versions/#{version.attrs["id"]}"

      "[#{project.key}|#{url}]"
    end.join("\n")
  end

  def asana_tasks
    prs_by_asana_link = release.github_assets.pull_requests.map(&:body).map do |body|
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

    prs_by_asana_link.any? ? <<~MARKDOWN : ""
      ----

      h2. Asana Tasks

      #{prs_by_asana_link.map do |group|
        [
          " # #{group[:link]}",
          *group[:prs].map { |pr| " *# [##{pr.number}: #{pr.title}|#{pr.html_url}]" }
        ].join("\n")
      end.join("\n")}
    MARKDOWN
  end

  def pull_requests_by_group
    associated_pull_requests = []
    asana_pull_requests = []
    dependency_pull_requests = []
    unassociated_pull_requests = []

    release.github_assets.commits_by_pull_request.each do |group|
      pull_request, commits = group.values_at(:pull_request, :commits)
      commit_messages = commits.map(&:commit).map(&:message).join("\n")

      if [
        commit_messages.match?(JIRA_TICKET_REGEX),
        pull_request.title.match?(JIRA_TICKET_REGEX),
        pull_request.body&.match?(JIRA_TICKET_REGEX),
      ].any?
        associated_pull_requests << pull_request
      elsif [
        pull_request.body&.match?(ASANA_LINK_REGEX),
        pull_request.body&.match?(ASANA_LEGACY_LINK_REGEX),
        commit_messages.match?(ASANA_LINK_REGEX),
        commit_messages.match?(ASANA_LEGACY_LINK_REGEX),
      ].any?
        asana_pull_requests << pull_request
      elsif pull_request.user.login.match?("dependabot")
        dependency_pull_requests << pull_request
      else
        unassociated_pull_requests << pull_request
      end
    end

    [
      {
        group: "Associated",
        pull_requests: associated_pull_requests,
      },
      {
        group: "Asana",
        pull_requests: asana_pull_requests,
      },
      {
        group: "Unassociated",
        pull_requests: unassociated_pull_requests,
      },
      {
        group: "Dependencies",
        pull_requests: dependency_pull_requests,
      }
    ]
  end
end