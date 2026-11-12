# frozen_string_literal: true

# For platform-table.Tests.ps1: prints whether Ruby4Lich5::TargetPlatform.current
# accepts each candidate tag in the JSON array file ARGV[0], plus R1's recorded
# x64 snapshot as [tag, accepted] pairs (its keys differ only by case, which
# ConvertFrom-Json cannot read as an object).
require 'json'
require 'ruby4lich5/target_platform'

pattern = Ruby4Lich5::TargetPlatform.current.candidate_tag_pattern
snapshot = JSON.parse(File.read(File.expand_path('../../fixtures/platform-table/x64-snapshot.json', __dir__)))
puts JSON.generate(
  'accepts'  => JSON.parse(File.read(ARGV.fetch(0), encoding: 'UTF-8')).map { |tag| pattern.match?(tag) },
  'snapshot' => snapshot.fetch('promotion_candidate_tags').to_a
)
