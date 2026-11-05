require 'json'
require_relative './lib/ruby4lich5/recovery_consumers'
require_relative './lib/ruby4lich5/recovery_sequence'
entry = Ruby4Lich5::RecoveryConsumers.entry(ARGV.fetch(0))
require entry.fetch('absolute_path')
document = JSON.parse(File.read(ARGV.fetch(1), encoding: 'bom|utf-8'))
target = document.fetch('targets').find { |item| item.values_at('ruby_abi', 'platform') == ['4.0', 'x64-mingw-ucrt'] }
abort 'missing Windows target' unless target
projected = document.merge('targets' => [target.merge('platform' => Gem::Platform.local.to_s)])
recovery = Lich::DependencyRecovery.new(http_get: ->(_url) { JSON.generate(projected) })
recovery.define_singleton_method(:ruby_abi) { '4.0' }
names = target.fetch('units').flat_map { |unit| unit.fetch('members') }.uniq
Ruby4Lich5::RecoverySequence.next_plan(recovery, names, installed: ->(_package) { false })
puts [ARGV.fetch(0), entry.fetch('commit'), 'P1 planning accepted'].join(' ')
