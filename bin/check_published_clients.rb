#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative '../lib/ruby4lich5/published_startup_releases'
abort 'Usage: check_published_clients.rb <gate-context.json>' unless ARGV.length == 1
begin
  approved = JSON.parse(File.read(ARGV.first, encoding: 'bom|utf-8')).fetch('supported_startup_policy').fetch('published_releases')
  unless Ruby4Lich5::PublishedStartupReleases.capture == approved
    raise ArgumentError, 'published clients changed after inspection; inspect and approve again before promotion'
  end
rescue StandardError => e
  warn "ERROR: #{e.class}: #{e.message}"
  exit 1
end
