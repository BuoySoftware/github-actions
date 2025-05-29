require_relative "jira_helper"

class Version
  VERSION_REGEX = /^v(\d+\.\d+)(?:-rc\.\d+)?$/

  def self.from_ref(ref)
    new(ref).name
  end

  def initialize(ref, jira_projects: nil)
    @ref = ref
    @jira_projects = jira_projects
  end

  def jira_versions
    @jira_versions ||= jira_projects.map do |jira_project|
      find_or_create_jira_version(jira_project, name)
    end
  end

  attr_reader :ref, :jira_projects

  def name
    ref.match(VERSION_REGEX)&.[](1)
  end

  private

  def find_or_create_jira_version(jira_project_name, version_name)
    jira_project = JiraHelper.client.Project.find(jira_project_name)

    existing_version = jira_project.versions.find { |v| v.name == version_name }

    if existing_version
      puts "Version #{version_name} already exists in project #{jira_project_name}"
      existing_version
    else
      puts "Creating new version #{version_name} in project #{jira_project_name}"
      jira_version = JiraHelper.client.Version.build
      jira_version.save!(
        'archived' => false,
        'description' => "Release version #{version_name}",
        'name' => version_name,
        'projectId' => jira_project.id,
        'released' => false
      )
      jira_version.fetch
    end
  end
end