# frozen_string_literal: true

require_relative "../confluence/page"

module ReleaseNotes
  class ReleaseNote
    TEMPLATE = ""

    def self.find_or_create(**)
      release_note = new(**)
      release_note.find_or_create
    end

    def initialize(version:, body: nil, parent_id: nil, title: nil)
      @body = body || self.class::TEMPLATE
      @parent_id = parent_id
      @title = [title, version.name].compact.join(" ")
      @version = version
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

    private

    attr_reader :body, :parent_id, :title, :version

    def space_key
      ENV.fetch("CONFLUENCE_RELEASES_SPACE_KEY")
    end
  end
end
