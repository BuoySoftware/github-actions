require "faraday"
require "json"

class ConfluenceHelper
  def self.client
    @client ||= Faraday.new(url: base_url) do |conn|
      conn.request(:authorization, :basic, username, api_token)
      conn.headers["Content-Type"] = "application/json"
      conn.headers["Accept"] = "application/json"
    end
  end

  def self.base_url
    @base_url ||= ENV.fetch("ATLASSIAN_URL")
  end

  def self.username
    @username ||= ENV.fetch("ATLASSIAN_EMAIL")
  end

  def self.api_token
    @api_token ||= ENV.fetch("ATLASSIAN_API_TOKEN")
  end

  def self.find_or_create_page(title:, body: "", parent_id: nil)
    puts "Processing Confluence Page: #{title}..."
    page = pages_by_title(title:)["results"].first

    if page
      puts " - Page Found: #{title}"
      page
    else
      puts " - Creating Page: #{title}"
      create_page(body:, parent_id:, title:)
    end
  end

  def self.create_page(body:, title:, parent_id: nil)
    payload = {
      body: {
        storage: {
          value: body,
          representation: "storage"
        }
      },
      space: { key: ENV.fetch("CONFLUENCE_RELEASES_SPACE_KEY") },
      title: title,
      type: "page",
    }

    payload[:ancestors] = [{ id: parent_id }] if parent_id

    response = client.post("/wiki/rest/api/content") do |req|
      req.body = payload.to_json
    end

    handle_response(response)
  end

  def self.pages_by_title(title:)
    params = {
      title: title,
      spaceKey: ENV.fetch("CONFLUENCE_RELEASES_SPACE_KEY"),
      type: "page",
      expand: "version"
    }

    response = client.get("/wiki/rest/api/content") { |req| req.params = params }
    handle_response(response)
  end

  def self.web_url(webui:)
    "#{base_url}/wiki#{webui}"
  end

  private

  def self.handle_response(response)
    case response.status
    when 200, 201
      JSON.parse(response.body)
    else
      raise "Confluence API error: #{response.status} - #{response.body}"
    end
  end
end 