require_relative "compare"
require_relative "jira_version"
require_relative "version"
require_relative "release_note"

class Release
  def self.prepare(base_ref:, head_ref:)
    new(base_ref:, head_ref:).prepare
  end

  def initialize(base_ref:, head_ref:)
    @base_ref = base_ref
    @head_ref = head_ref
  end

  attr_reader :base_ref, :head_ref

  def prepare
    puts "Version: #{version.name}"

    puts "Analyzing changes between #{compare.base_ref} and #{compare.head_ref}"

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
      puts "  - #{jira_version.attrs["self"]}"
    end

    puts "Release Notes:"
    release_note = ReleaseNote.find_or_create(version)
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

  def version
    @version ||= Version.from_ref(compare.head_ref)
  end

  def compare
    @compare ||= Compare.new(base_ref: base_ref, head_ref: head_ref)
  end

  def jira_projects
    @jira_projects ||= compare.pull_requests.flat_map(&:jira_projects).uniq
  end

  def jira_versions
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