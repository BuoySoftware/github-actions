# frozen_string_literal: true

require_relative "client"

module Confluence
  class Resource
    def self.find_by(params)
      json = where(params)

      first_result = json["results"].first

      return unless first_result

      find(first_result["id"])
    end

    def self.where(params)
      Client.instance.get(self::API_PATH, params:)
    end

    def self.find(id)
      json = Client.instance.get("#{self::API_PATH}/#{id}")

      new(json)
    end

    def self.create(params)
      json = Client.instance.post(self::API_PATH, params:)

      new(json)
    end

    def initialize(json)
      @json = json
    end

    private

    attr_reader :json
  end
end
