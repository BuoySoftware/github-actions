require_relative "asana_release_card"
require_relative "environment_feature_flags"
require_relative "github_assets"
require_relative "jira_assets"
require_relative "jira_release_card"
require_relative "release_notes/deployment_plan"
require_relative "release_notes/release_note"
require_relative "release_notes/technical_note"
require_relative "version"

class Release
  TECHNICAL_NOTE_TITLES = [
    "DMS Technical Notes",
    "PMS Technical Notes",
    "Payments & CRM Technical Notes",
    "Medical Device Technical Notes",
    "Integrations API Technical Notes",
  ].freeze

  def self.prepare(base_ref:, head_ref:)
    new(base_ref:, head_ref:).prepare
  end

  def initialize(base_ref:, head_ref:)
    @version = Version.new(ref: head_ref)
    @github_assets = GithubAssets.new(base_ref:, head_ref:)
    @jira_assets = JiraAssets.new(github_assets:)
  end

  attr_reader :asana_release_card,
    :github_assets,
    :jira_assets,
    :version

  def prepare
    puts "Preparing release #{version.name}..."
    puts "findings or creating jira project versions..."
    find_or_create_jira_project_versions
    puts "assigning project versions to issues..."
    assign_project_version_to_issues
    puts "finding or creating release notes..."
    find_or_create_release_note
    puts "finding or creating technical notes..."
    find_or_create_technical_notes
    puts "finding or creating deployment plans..."
    find_or_create_deployment_plan
    puts "creating or updating jira release card..."
    create_or_update_jira_release_card
    puts "creating asana release card..."
    create_asana_release_card
  end

  def environment_feature_flags
    @environment_feature_flags ||= EnvironmentFeatureFlags.detect(changes: github_assets.changes)
  end

  private

  def find_or_create_jira_project_versions
    jira_assets.project_versions ||= jira_assets.projects.map do |project|
      project.find_or_create_version(version.name)
    end
  end

  def assign_project_version_to_issues
    jira_assets.versions_by_project.each do |group|
      project, jira_version = group.values_at(:project, :version)
      issues = jira_assets.issues_by_project.detect { |group|
        group[:project].key == project.key
      }[:issues]

      issues.each do |issue|
        issue.add_to_version(jira_version)
      end
    end
  end

  def find_or_create_release_note
    jira_assets.release_note ||= ReleaseNotes::ReleaseNote.find_or_create(version:)
  end

  def find_or_create_technical_notes
    parent_technical_note = ReleaseNotes::ReleaseNote.find_or_create(
      parent_id: jira_assets.release_note.id,
      title: "Technical Notes",
      version:
    )

    jira_assets.technical_notes ||= TECHNICAL_NOTE_TITLES.map do |title|
      ReleaseNotes::TechnicalNote.find_or_create(
        parent_id: parent_technical_note.id,
        title:,
        version:
      )
    end
  end

  def find_or_create_deployment_plan
    # Create parent "Deployment Plans" note
    parent_deployment_note = ReleaseNotes::ReleaseNote.find_or_create(
      parent_id: jira_assets.release_note.id,
      title: "Deployment Plans",
      version:
    )

    jira_assets.deployment_plans ||= [
      ReleaseNotes::DeploymentPlan.find_or_create(
        parent_id: parent_deployment_note.id,
        title: ENV.fetch("GITHUB_REPO"),
        version:
      ),
    ]
  end

  def create_or_update_jira_release_card
    jira_assets.release_card ||= JiraReleaseCard.create_or_update(release: self)
  end

  def create_asana_release_card
    @create_asana_release_card ||= AsanaReleaseCard.create(release: self)
  end
end
