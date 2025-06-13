require_relative "jira/issue"
require_relative "jira/project"

class JiraAssets
  ISSUE_KEY_REGEX = /[A-Z]+-\d+/

  attr_accessor(
    :project_versions,
    :release_card
  )

  def initialize(github_assets:)
    @github_assets = github_assets
  end

  def issues
    @issues ||= issue_keys.map do |issue_key|
      Jira::Issue.find(issue_key)
    end
  end

  def issues_by_project
    @issues_by_project ||= projects.map do |project|
      {
        project:,
        issues: issues.select { |issue| issue.project.key == project.key },
      }
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

    @versions_by_project ||= projects.map do |project|
      {
        project:,
        version: project_versions.detect do |project_version|
          project_version.attrs["projectId"].to_s == project.id
        end,
      }
    end
  end

  private

  attr_reader :github_assets

  def issue_keys
    @issue_keys ||= [
      *github_assets.pull_requests.map(&:title),
      *github_assets.pull_requests.map(&:body),
      *github_assets.commit_messages,
    ].join("\n").scan(ISSUE_KEY_REGEX).flatten.uniq
  end
end
