require_relative "resource"

module Confluence
  class Page < Resource
    API_PATH = "/wiki/rest/api/content".freeze

    def self.create(body:, space_key:, title:, parent_id: nil)
      params = {
        body: {
          wiki: {
            value: body,
            representation: "wiki",
          },
        },
        title: title,
        space: {
          key: space_key,
        },
        type: "page",
      }

      params[:ancestors] = [{ id: parent_id }] if parent_id

      super(params)
    end

    def update(body:, title: nil)
      current_page = self.class.find(id)
      current_version = current_page.json["version"]["number"]

      params = {
        id: id,
        type: "page",
        title: title || self.title,
        body: {
          wiki: {
            value: body,
            representation: "wiki",
          },
        },
        version: {
          number: current_version + 1,
        },
      }

      super(params)
    end

    def id
      json["id"]
    end

    def title
      json["title"]
    end

    def url
      "#{json['_links']['base']}#{json['_links']['webui']}"
    end
  end
end
