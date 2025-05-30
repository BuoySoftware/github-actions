require_relative "compare"
require_relative "jira_version"
require_relative "version"
require_relative "release_note"

class Release
  def self.prepare(base_ref:, head_ref:)
    new(base_ref:, head_ref:).prepare
  end

  def initialize(base_ref:, head_ref:)
    @compare = Compare.new(base_ref:, head_ref:)
    @version = Version.new(ref: head_ref)
    @pull_requests = compare.pull_requests
    @environment_feature_flags = compare.environment_feature_flags
    @jira_projects = compare.jira_projects
  end

  attr_reader :compare, :environment_feature_flags, :jira_projects, :pull_requests, :version

  def prepare
    jira_versions = create_jira_versions
    release_note = ReleaseNote.find_or_create(version)

    puts "Version: #{version.name}"

    puts "Pull Requests:"
    compare.pull_requests.each do |pr|
      puts "- ##{pr.number}: #{pr.title}"
      puts "  - Asana Links:"
      pr.asana_links.each do |link|
        puts "    - #{link}"
      end
      puts "  - Jira Tickets:"
      pr.jira_tickets.each do |ticket|
        puts "    - #{ticket}"
      end
    end

    puts "Feature Flags:"
    compare.environment_feature_flags.each do |feature|
      puts "  - #{feature}"
    end

    puts "Jira Projects:"
    jira_projects.each do |jira_project|
      puts "  - #{jira_project}"
    end

    puts "Jira Versions:"
    jira_versions.each do |jira_version|
      puts "  - #{jira_version.url}"
    end

    puts "Release Notes:"
    puts "Main Page:"
    puts "  - #{release_note.main_page["title"]}: #{release_note.main_page.dig("_links", "base")}#{release_note.main_page.dig("_links", "webui")}"
    puts "Technical Notes:"
    release_note.technical_notes.each do |technical_note|
      puts "  - #{technical_note["title"]}: #{technical_note.dig("_links", "base")}#{technical_note.dig("_links", "webui")}"
    end
    puts "Deployment Plans:"
    release_note.deployment_plans.each do |deployment_plan|
      puts "  - #{deployment_plan["title"]}: #{deployment_plan.dig("_links", "base")}#{deployment_plan.dig("_links", "webui")}"
    end
  end

  private

  def create_jira_versions
    @jira_versions ||= jira_projects.map do |jira_project_name|
      JiraVersion.find_or_create(
        jira_project_name:,
        tickets: jira_tickets_by_project(jira_project_name),
        version:
      )
    end
  end

  def jira_tickets_by_project(jira_project_name)
    compare.pull_requests.flat_map do |pr|
      pr.jira_tickets.select { |ticket| ticket.start_with?(jira_project_name) }
    end.uniq
  end
end