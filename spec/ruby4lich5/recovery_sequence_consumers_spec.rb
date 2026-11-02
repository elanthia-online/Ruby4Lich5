# frozen_string_literal: true

require 'open3'
require 'ruby4lich5/recovery_consumers'

RSpec.describe 'Clean recovery gate with pinned consumers' do
  %w[current oldest].each do |key|
    it "rejects a multi-native plan for #{key} while accepting one native suite" do
      consumer = Ruby4Lich5::RecoveryConsumers.entry(key).fetch('absolute_path')
      sequence = File.expand_path('../../lib/ruby4lich5/recovery_sequence.rb', __dir__)
      script = <<~'RUBY'
        require 'json'
        require ARGV.fetch(0)
        require ARGV.fetch(1)
        # Simulate only platform selection; never download or install packages.
        Gem.define_singleton_method(:win_platform?) { true }
        units = %w[gtk3 native-second direct].map do |name|
          archive = name == 'direct' ? 'gem' : 'zip'
          filename = "#{name}-1.0.0-#{Gem::Platform.local}.gem"
          artifact = archive == 'zip' ? "#{name}.zip" : filename
          { 'id' => name, 'members' => [name], 'install_order' => [name],
            'artifact' => { 'filename' => artifact, 'url' => "https://example.invalid/#{artifact}",
                            'archive' => archive, 'sha256' => "sha256:#{'a' * 64}" },
            'packages' => [{ 'name' => name, 'version' => '1.0.0', 'filename' => filename, 'sha256' => "sha256:#{'b' * 64}" }] }
        end
        manifest = { 'schema' => 1, 'targets' => [{ 'ruby_abi' => RUBY_VERSION.split('.')[0, 2].join('.'),
                                                   'platform' => Gem::Platform.local.to_s, 'units' => units }] }
        recovery = Lich::DependencyRecovery.new(http_get: ->(_) { JSON.generate(manifest) })
        names = units.flat_map { |unit| unit['members'] }
        begin
          Ruby4Lich5::RecoverySequence.next_plan(recovery, names, installed: ->(_) { false })
          abort 'multi-native acceptance unexpectedly passed'
        rescue RuntimeError => e
          raise unless e.message.include?('at most one native runtime unit')
        end
        units.delete_at(1)
        plan = Ruby4Lich5::RecoverySequence.next_plan(recovery, %w[gtk3 direct], installed: ->(_) { false })
        abort 'one-native control failed' unless plan.units.flat_map { |unit| unit['members'] }.sort == %w[direct gtk3]
        puts 'multi-native rejected; one-native accepted'
      RUBY
      output, status = Open3.capture2e(RbConfig.ruby, '-e', script, consumer, sequence)
      expect(status).to be_success, output
      expect(output).to include('multi-native rejected; one-native accepted')
    end
  end
end
