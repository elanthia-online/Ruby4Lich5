#!/usr/bin/env ruby
# frozen_string_literal: true

# Legacy migration utility for moving artifact URLs between release tags.
# Immutable run/attempt candidates keep their artifact URLs at promotion;
# only the consumer-named manifest is replaced after administrative review.
#
# Retargets rather than regenerates deliberately: promotion moves the exact
# same zip bytes from the candidate tag to the live tag (gh release upload
# <live-tag> <same-local-zip> --clobber) -- the content and its SHA-256
# don't change, only which tag hosts it does. Re-running the whole generator
# against a fresh closure at promotion time would risk resolving a different
# closure than what was actually reviewed on the candidate (a real risk if
# any upstream gem published a new version in between); a plain string
# retarget of the one field that actually changes cannot do that.
#
# Only rewrites artifact.url entries that reference <old_tag> -- units whose
# artifact is an individual native gem's own release (never affected by
# bundle promotion) are left untouched.
#
# Usage:
#   ruby bin/retarget_gem_manifest.rb <input_json_path> <old_tag> <new_tag> <output_json_path>
#
# Exit status:
#   0 -- success, output_json_path written.
#   1 -- input_json_path doesn't exist, isn't valid JSON, or contains no
#        artifact referencing old_tag at all (almost certainly the wrong
#        manifest file or the wrong old_tag argument -- fails loud rather
#        than silently writing an unmodified copy).
#   2 -- bad ARGV invocation.

require 'json'

ARG_NAMES = %i[input_json_path old_tag new_tag output_json_path].freeze

if ARGV.size != ARG_NAMES.size
  warn "Usage: #{$PROGRAM_NAME} #{ARG_NAMES.map { |n| "<#{n}>" }.join(' ')}"
  exit 2
end

input_json_path, old_tag, new_tag, output_json_path = ARGV

if old_tag.match?(/\AR4L5-gem-bundle-.*-candidate-\d+-\d+\z/)
  warn 'ERROR: immutable candidates must retain artifact URLs; do not retarget or overwrite production artifacts.'
  exit 1
end

unless File.exist?(input_json_path)
  warn "ERROR: #{input_json_path} does not exist"
  exit 1
end

manifest = begin
  JSON.parse(File.read(input_json_path))
rescue JSON::ParserError => e
  warn "ERROR: #{input_json_path} is not valid JSON: #{e.message}"
  exit 1
end

old_url_segment = "/releases/download/#{old_tag}/"
new_url_segment = "/releases/download/#{new_tag}/"
retargeted_count = 0

manifest.fetch('targets', []).each do |target|
  target.fetch('units', []).each do |unit|
    url = unit.dig('artifact', 'url')
    next unless url&.include?(old_url_segment)

    unit['artifact']['url'] = url.sub(old_url_segment, new_url_segment)
    retargeted_count += 1
  end
end

if retargeted_count.zero?
  warn "ERROR: no artifact in #{input_json_path} references #{old_tag} -- wrong manifest file or wrong old_tag?"
  exit 1
end

File.write(output_json_path, JSON.pretty_generate(manifest))
puts "Retargeted #{retargeted_count} unit(s) from #{old_tag} to #{new_tag}, wrote #{output_json_path}"
