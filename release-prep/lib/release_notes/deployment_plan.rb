require_relative "release_note"

module ReleaseNotes
  class DeploymentPlan < ReleaseNote
    private

    def generate_template
      <<~HTML
        <div>
          <h1>Post-Deployment Instructions</h1>
          <table border="1" style="border-collapse: collapse; width: 100%;">
            <thead>
              <tr>
                <th style="padding: 8px; text-align: left;">Jira Issue</th>
                <th style="padding: 8px; text-align: left;">Instructions</th>
              </tr>
            </thead>
            <tbody>
              #{generate_table_rows}
            </tbody>
          </table>
        </div>
      HTML
    end

    def generate_table_rows
      issues_with_post_deployment_instructions.map do |issue|
        <<~HTML.strip
          <tr>
            <td style="padding: 8px; border: 1px solid #ddd;"><a href="#{issue.url}">#{issue.key}</a></td>
            <td style="padding: 8px; border: 1px solid #ddd;">#{issue.post_deployment_instructions}</td>
          </tr>
        HTML
      end.join("\n")
    end

    def issues_with_post_deployment_instructions
      return [] unless jira_assets&.issues

      jira_assets.issues.select(&:post_deployment_instructions)
    end
  end
end
