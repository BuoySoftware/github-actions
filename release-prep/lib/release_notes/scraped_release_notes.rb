require_relative "release_note"

module ReleaseNotes
  class ScrapedReleaseNotes < ReleaseNote
    def initialize(issues:, **)
      @issues = issues

      super(**)
    end

    private

    attr_reader :issues

    def generate_template
      <<~WIKI
        || Jira Issue || Feature Flag || Release Notes ||
        #{generate_table_rows}
      WIKI
    end

    def generate_table_rows
      issues.map do |issue|
        release_notes = clean_line_breaks(issue.release_notes)
        "| [#{issue.key}|#{issue.url}] | #{issue.feature_flag} | #{release_notes} |"
      end.join("\n")
    end
  end
end
