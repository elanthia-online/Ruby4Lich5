# frozen_string_literal: true

# `ruby -r` preload for the CLI integration specs; see registry_without_minimums.rb.
require_relative 'registry_without_minimums'

Ruby4Lich5::KnownNativeGems.instance_variable_set(:@registry, RegistryWithoutMinimums.registry)
