#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative '../lib/ruby4lich5/replacement_plan'
abort 'Usage: prepare_replacement.rb <accepted-preparation> <new-lock> <plan-output>' unless ARGV.length == 3
begin
  directory, lock_path, output = ARGV
  prior = Ruby4Lich5::ResolutionLock.from_h(JSON.parse(File.read(File.join(directory, 'bundle/resolution-lock.json'))))
  lock = Ruby4Lich5::ResolutionLock.from_h(JSON.parse(File.read(lock_path)))
  manifest = JSON.parse(File.read(File.join(directory, 'candidate/R4L5-gem-manifest.json')))
  plan = Ruby4Lich5::ReplacementPlan.build(previous_lock: prior, lock: lock, manifest: manifest, directory: File.join(directory, 'bundle'))
  File.write(output, JSON.pretty_generate(plan) + "\n")
rescue StandardError => e
  warn "ERROR: #{e.class}: #{e.message}"
  exit 1
end
