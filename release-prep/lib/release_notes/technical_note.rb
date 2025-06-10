require_relative "release_note"

module ReleaseNotes
  class TechnicalNote < ReleaseNote
    TEMPLATE = <<~WIKI.freeze
      h1. 🆕 What's New

      * Feature name: description

      h1. 🚀 Improvements

      * Improvement name: description

      h1. 🐞 Bug fixes

      * Bug: description of what was fixed and the impact to users

      h1. 💻 Additional Changes

      * Change name: description

      h2. Document History

      || Revision || Date || Summary of Changes ||
      | A | <release date> | Initial Version |
    WIKI
  end
end
