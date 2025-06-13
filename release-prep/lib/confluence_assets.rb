require_relative "release_notes/deployment_plan"
require_relative "release_notes/release_note"
require_relative "release_notes/scraped_release_notes"
require_relative "release_notes/technical_note"

class ConfluenceAssets
  TECHNICAL_NOTE_TITLES = [
    "DMS Technical Notes",
    "PMS Technical Notes",
    "Payments & CRM Technical Notes",
    "Medical Device Technical Notes",
    "Integrations API Technical Notes",
  ].freeze

  attr_accessor :deployment_plans,
    :scraped_release_notes,
    :technical_notes,
    :version_note

  def initialize(jira_assets:, version:)
    @jira_assets = jira_assets
    @version = version
  end

  def find_or_create_deployment_plans
    self.deployment_plans ||= [
      ReleaseNotes::DeploymentPlan.create_or_update(
        parent_id: parent_deployment_note.id,
        title: "#{ENV.fetch('GITHUB_REPO')} Deployment Plan",
        version: version,
        jira_assets: jira_assets
      ),
    ]
  end

  def find_or_create_technical_notes
    self.technical_notes ||= TECHNICAL_NOTE_TITLES.map do |title|
      ReleaseNotes::TechnicalNote.find_or_create(
        parent_id: parent_technical_note.id,
        title: title,
        version: version
      )
    end
  end

  def find_or_create_version_note
    self.version_note ||= ReleaseNotes::ReleaseNote.find_or_create(
      body: "{children:all=true}",
      parent_id: "41123847",
      version: version
    )
  end

  def update_or_create_scraped_release_notes
    self.scraped_release_notes ||= jira_assets.issues_by_project.map do |group|
      project, issues = group.values_at(:project, :issues)

      ReleaseNotes::ScrapedReleaseNotes.create_or_update(
        issues:,
        parent_id: parent_scraped_release_notes.id,
        title: "Scraped Release Notes #{project.key}",
        version:
      )
    end
  end

  private

  attr_reader :jira_assets, :version

  def parent_deployment_note
    @parent_deployment_note ||= ReleaseNotes::ReleaseNote.find_or_create(
      body: "{children:all=true}",
      parent_id: version_note.id,
      title: "Deployment Plans",
      version: version
    )
  end

  def parent_scraped_release_notes
    @parent_scraped_release_notes ||= ReleaseNotes::ReleaseNote.find_or_create(
      body: "{children:all=true}",
      parent_id: "71270523",
      title: "Scraped Release Notes",
      version: version
    )
  end

  def parent_technical_note
    @parent_technical_note ||= ReleaseNotes::ReleaseNote.find_or_create(
      body: "{children:all=true}",
      parent_id: version_note.id,
      title: "Technical Notes",
      version: version
    )
  end
end
