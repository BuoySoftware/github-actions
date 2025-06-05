# frozen_string_literal: true

require "faraday"
require "json"
require "singleton"

module Confluence
  class Client
    include Singleton

    def get(path, params: {})
      response = connection.get(path) do |req|
        req.params = params
      end

      handle_response(response)
    end

    def post(path, params: {})
      response = connection.post(path) do |req|
        req.body = params.to_json
      end

      handle_response(response)
    end

    private

    def connection
      @connection ||= Faraday.new(url: ENV.fetch("ATLASSIAN_URL").to_s) do |conn|
        conn.request(:authorization, :basic, ENV.fetch("ATLASSIAN_EMAIL"),
          ENV.fetch("ATLASSIAN_API_TOKEN"))
        conn.headers["Content-Type"] = "application/json"
        conn.headers["Accept"] = "application/json"
      end
    end

    def handle_response(response)
      case response.status
      when 200, 201
        JSON.parse(response.body)
      else
        raise "Confluence API error: #{response.status} - #{response.body}"
      end
    end
  end
end
