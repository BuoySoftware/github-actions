require_relative "release_note"

module ReleaseNotes
  class DeploymentPlan < ReleaseNote
    private

    def generate_template
      <<~WIKI
        h1. Pre-Deployment Instructions

        || Jira Issue || Instructions ||
        #{generate_pre_deployment_table_rows}

        ----

        h1. Post-Deployment Instructions

        || Jira Issue || Instructions ||
        #{generate_post_deployment_table_rows}
      WIKI
    end

    def generate_pre_deployment_table_rows
      issues_with_pre_deployment_instructions.map do |issue|
        cleaned_instructions = clean_line_breaks(issue.pre_deployment_instructions)
        "| [#{issue.key}|#{issue.url}] | #{cleaned_instructions} |"
      end.join("\n")
    end

    def generate_post_deployment_table_rows
      issues_with_post_deployment_instructions.map do |issue|
        cleaned_instructions = clean_line_breaks(issue.post_deployment_instructions)
        "| [#{issue.key}|#{issue.url}] | #{cleaned_instructions} |"
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
