require_relative "confluence_helper"

class ReleaseNote
  DEPLOYMENT_PLAN_TITLES = [
    "Buoy Rails",
    "Infirmary",
    "Wharf",
  ].freeze

  TECHNICAL_NOTE_TITLES = [
    "DMS Technical Notes",
    "PMS Technical Notes",
    "Payments & CRM Technical Notes",
    "Medical Device Technical Notes",
    "Integrations API Technical Notes",
  ].freeze

  DEPLOYMENT_PLAN_TEMPLATE = <<~HTML
    <div>
      <h1>Rollout</h1>
      <h1>Rollback</h1>
    </div>
  HTML

  TECHNICAL_NOTE_TEMPLATE = <<~HTML
    <div>
      <h1>🆕 What's New</h1>
      <ul>
        <li>Feature name: description</li>
      </ul>
      <h1>🚀 Improvements</h1>
      <ul>
        <li>Improvement name: description</li>
      </ul>
      <h1>🐞 Bug fixes</h1>
      <ul>
        <li>Bug: description of what was fixed and the impact to users</li>
      </ul>
      <h1>💻 Additional Changes</h1>
      <ul>
        <li>Change name: description</li>
      </ul>
      <h2>Document History</h2>
      <table>
        <thead>
          <tr>
            <th>Revision</th>
            <th>Date</th>
            <th>Summary of Changes</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>A</td>
            <td>&lt;release date&gt;</td>
            <td>Initial Version</td>
          </tr>
        </tbody>
      </table>
    </div>
  HTML

  def self.find_or_create(version)
    release_note = new(version)
    release_note.find_or_create
    release_note
  end

  def initialize(version)
    @version = version
  end

  attr_reader :version

  def find_or_create
    main_page
    technical_notes
    deployment_plans
  end

  def main_page
    @main_page ||= ConfluenceHelper.find_or_create_page(title: version.name)
  end

  def technical_notes
    @technical_notes ||= TECHNICAL_NOTE_TITLES.map do |title|
      ConfluenceHelper.find_or_create_page(
        body: TECHNICAL_NOTE_TEMPLATE,
        parent_id: technical_note_page["id"],
        title: "#{title} #{version.name}",
      )
    end
  end

  def technical_note_page
    @technical_note_page ||= ConfluenceHelper.find_or_create_page(
      title: "Technical Notes #{version.name}",
      parent_id: main_page["id"]
    )
  end

  def deployment_plans
    @deloyment_plans ||= DEPLOYMENT_PLAN_TITLES.map do |title|
      ConfluenceHelper.find_or_create_page(
        body: DEPLOYMENT_PLAN_TEMPLATE,
        parent_id: deployment_plan_page["id"],
        title: "#{title} #{version.name}",
      )
    end
  end

  def deployment_plan_page
    @deployment_plan_page ||= ConfluenceHelper.find_or_create_page(
      title: "Deployment Plans #{version.name}",
      parent_id: main_page["id"]
    )
  end
end