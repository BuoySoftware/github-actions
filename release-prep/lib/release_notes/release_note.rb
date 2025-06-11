require_relative "../confluence/page"

module ReleaseNotes
  class ReleaseNote
    TEMPLATE = "".freeze

    def self.find_or_create(**)
      release_note = new(**)
      release_note.find_or_create
    end

    def self.create_or_update(**)
      release_note = new(**)
      release_note.create_or_update
    end

    def initialize(version:, body: nil, parent_id: nil, title: nil, jira_assets: nil)
      @body = body
      @parent_id = parent_id
      @title = [title, version.name].compact.join(" ")
      @version = version
      @jira_assets = jira_assets
    end

    def find_or_create
      page = Confluence::Page.find_by(space_key:, title:)

      if page
        puts " - Page Found: #{title}"
        page
      else
        puts " - Creating Page: #{title}"
        Confluence::Page.create(body:, parent_id:, space_key:, title:)
      end
    end

    def create_or_update
      page = Confluence::Page.find_by(space_key:, title:)

      if page
        puts " - Page Found, Updating: #{title}"
        page.update(body:, title:)
      else
        puts " - Creating Page: #{title}"
        Confluence::Page.create(body:, parent_id:, space_key:, title:)
      end
    end

    private

    attr_reader :parent_id, :title, :version, :jira_assets

    def body
      @body ||= generate_template
    end

    def generate_template
      self.class.const_defined?(:TEMPLATE) ? self.class::TEMPLATE : ""
    end

    def space_key
      ENV.fetch("CONFLUENCE_RELEASES_SPACE_KEY")
    end
  end
end
