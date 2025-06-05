# frozen_string_literal: true

require_relative "resource"

module Confluence
  class Page < Resource
    API_PATH = "/wiki/rest/api/content"

    def self.create(body:, space_key:, title:, parent_id: nil)
      params = {
        body: {
          storage: {
            value: body,
            representation: "storage",
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
