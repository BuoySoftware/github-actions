# frozen_string_literal: true

require_relative "release_note"

module ReleaseNotes
  class TechnicalNote < ReleaseNote
    TEMPLATE = <<~HTML
      <div>
        <h1>🆕 What's New</h1>
        <ul>
          <li>Feature name: description</li>
        </ul>
        <h1>🚀 Improvements</h1>
        <ul>
          <li>Improvement name: description</li>
        </ul>
        <h1>🐞 Bug fixes</h1>
        <ul>
          <li>Bug: description of what was fixed and the impact to users</li>
        </ul>
        <h1>💻 Additional Changes</h1>
        <ul>
          <li>Change name: description</li>
        </ul>
        <h2>Document History</h2>
        <table>
          <thead>
            <tr>
              <th>Revision</th>
              <th>Date</th>
              <th>Summary of Changes</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td>A</td>
              <td>&lt;release date&gt;</td>
              <td>Initial Version</td>
            </tr>
          </tbody>
        </table>
      </div>
    HTML
  end
end
