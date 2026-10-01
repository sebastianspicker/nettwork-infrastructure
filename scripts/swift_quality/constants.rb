# frozen_string_literal: true

module SwiftQuality
  MAX_PRODUCTION_FILE_LINES = 380
  MAX_TEST_FILE_LINES = 500
  MAX_CALLABLE_LINES = 60
  MAX_COMPLEXITY = 9
  PRODUCTION_CLONE_LINES = 7
  PRODUCTION_CLONE_TOKENS = 50
  TEST_CLONE_LINES = 8
  TEST_CLONE_TOKENS = 60
  NON_SWIFT_FILE_LIMITS = {
    ".html" => 500,
    ".css" => 500,
    ".js" => 400,
    ".rb" => 300,
    ".mjs" => 300,
    ".sh" => 200
  }.freeze
  GENERATED_DIRECTORIES = %w[
    .build .git .serena .swiftpm build deriveddata generated node_modules vendor
  ].freeze
end
