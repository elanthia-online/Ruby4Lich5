#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative '../lib/ruby4lich5/replacement_plan'
abort 'Usage: verify_replacement.rb <plan> <staged-directory>' unless ARGV.length == 2
Ruby4Lich5::ReplacementPlan.verify_staged!(JSON.parse(File.read(ARGV[0])), ARGV[1])
