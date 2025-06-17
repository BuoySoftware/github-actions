require_relative "jira/issue"
require_relative "jira/project"
require_relative "jira/version"
require_relative "jira_release_card"

class JiraAssets
  ISSUE_KEY_REGEX = /[A-Z]+-\d+/

  attr_accessor(
    :project_versions,
    :release_card
  )

  def initialize(github_assets:, version:)
    @github_assets = github_assets
    @version = version
  end

  def issues
    @issues ||= issue_keys.map do |issue_key|
      Jira::Issue.find(issue_key)
    end
  end

  def issues_by_project
    @issues_by_project ||= projects.each_with_object({}) do |project, memo|
      memo[project] = issues.select { |issue| issue.project.key == project.key }
    end
  end

  def projects
    @projects ||= issues
      .map(&:project)
      .uniq(&:key)
      .map { |project| Jira::Project.find(project.key) }
  end

  def versions_by_project
    return nil if project_versions.nil?

    @versions_by_project ||= projects.each_with_object({}) do |project, memo|
      memo[project] = project_versions.detect do |project_version|
        project_version.attrs["projectId"].to_s == project.id
      end
    end
  end

  def find_or_create_project_versions
    self.project_versions ||= projects.map do |project|
      Jira::Version.create_or_update(project_id: project.id, name: version.name)
    end
  end

  def assign_versions_to_issues
    versions_by_project.each do |project, jira_version|
      issues = issues_by_project[project]

      issues.each do |issue|
        issue.add_to_version(jira_version)
      end
    end
  end

  def create_or_update_release_card(release:)
    self.release_card ||= JiraReleaseCard.create_or_update(release: release)
  end

  private

  attr_reader :github_assets, :version

  def issue_keys
    @issue_keys ||= [
      *github_assets.pull_requests.map(&:title),
      *github_assets.pull_requests.map(&:body),
      *github_assets.commit_messages,
    ].join("\n").scan(ISSUE_KEY_REGEX).flatten.uniq
  end
end
