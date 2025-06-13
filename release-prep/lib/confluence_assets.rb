require_relative "release_notes/deployment_plan"
require_relative "release_notes/release_note"
require_relative "release_notes/technical_note"

class ConfluenceAssets
  TECHNICAL_NOTE_TITLES = [
    "DMS Technical Notes",
    "PMS Technical Notes",
    "Payments & CRM Technical Notes",
    "Medical Device Technical Notes",
    "Integrations API Technical Notes",
  ].freeze

  attr_accessor :deployment_plans, :release_note, :technical_notes

  def initialize(jira_assets:, version:)
    @jira_assets = jira_assets
    @version = version
  end

  def find_or_create_release_note
    self.release_note ||= ReleaseNotes::ReleaseNote.find_or_create(
      body: "{children:all=true}",
      version: version
    )
  end

  def find_or_create_technical_notes
    parent_technical_note = ReleaseNotes::ReleaseNote.find_or_create(
      body: "{children:all=true}",
      parent_id: release_note.id,
      title: "Technical Notes",
      version: version
    )

    self.technical_notes ||= TECHNICAL_NOTE_TITLES.map do |title|
      ReleaseNotes::TechnicalNote.find_or_create(
        parent_id: parent_technical_note.id,
        title: title,
        version: version
      )
    end
  end

  def find_or_create_deployment_plans
    parent_deployment_note = ReleaseNotes::ReleaseNote.find_or_create(
      body: "{children:all=true}",
      parent_id: release_note.id,
      title: "Deployment Plans",
      version: version
    )

    self.deployment_plans ||= [
      ReleaseNotes::DeploymentPlan.create_or_update(
        parent_id: parent_deployment_note.id,
        title: "#{ENV.fetch('GITHUB_REPO')} Deployment Plan",
        version: version,
        jira_assets: jira_assets
      ),
    ]
  end

  private

  attr_reader :jira_assets, :version
end
