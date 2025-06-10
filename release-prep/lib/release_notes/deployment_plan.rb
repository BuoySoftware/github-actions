require_relative "release_note"

module ReleaseNotes
  class DeploymentPlan < ReleaseNote
    private

    def generate_template
      <<~HTML
        <div>
          <h1>Pre-Deployment Instructions</h1>
          <table>
            <thead>
              <tr>
                <th>Jira Issue</th>
                <th>Instructions</th>
              </tr>
            </thead>
            <tbody>
              #{generate_pre_deployment_table_rows}
            </tbody>
          </table>
        </div>
        <hr />
        <div>
          <h1>Post-Deployment Instructions</h1>
          <table>
            <thead>
              <tr>
                <th>Jira Issue</th>
                <th>Instructions</th>
              </tr>
            </thead>
            <tbody>
              #{generate_post_deployment_table_rows}
            </tbody>
          </table>
        </div>
      HTML
    end

    def generate_pre_deployment_table_rows
      issues_with_pre_deployment_instructions.map do |issue|
        <<~HTML.strip
          <tr>
            <td><a href="#{issue.url}">#{issue.key}</a></td>
            <td>#{issue.pre_deployment_instructions}</td>
          </tr>
        HTML
      end.join("\n")
    end

    def generate_post_deployment_table_rows
      issues_with_post_deployment_instructions.map do |issue|
        <<~HTML.strip
          <tr>
            <td><a href="#{issue.url}">#{issue.key}</a></td>
            <td>#{issue.post_deployment_instructions}</td>
          </tr>
        HTML
      end.join("\n")
    end

    def issues_with_pre_deployment_instructions
      return [] unless jira_assets&.issues

      jira_assets.issues.select(&:pre_deployment_instructions)
    end

    def issues_with_post_deployment_instructions
      return [] unless jira_assets&.issues

      jira_assets.issues.select(&:post_deployment_instructions)
    end
  end
end
