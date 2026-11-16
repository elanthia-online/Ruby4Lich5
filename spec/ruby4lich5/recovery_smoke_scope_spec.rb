# frozen_string_literal: true

require 'json'
require 'digest'
require 'open3'
require 'rbconfig'
require 'tmpdir'

# bin/recovery_smoke.rb refuses non-Windows hosts before anything else; the
# scope decision runs before any consumer code, lock or RubyInstaller check,
# so this drives it with only that host check answered.
RSpec.describe 'bin/recovery_smoke.rb platform scope' do
  let(:script) { File.expand_path('../../bin/recovery_smoke.rb', __dir__) }
  let(:scope) { { 'legacy' => [], 'startup' => [], 'soak' => [], 'ranged' => true, 'platform' => 'aarch64-mingw-ucrt' } }

  def run_smoke(consumer, platform:, policy:)
    Dir.mktmpdir do |directory|
      manifest = JSON.generate('targets' => [{ 'contract' => { 'ruby_inventory' => { 'platform' => platform } } }])
      File.write(File.join(directory, 'manifest.json'), manifest)
      context = { 'manifest_path' => 'manifest.json', 'lock_path' => 'missing-lock.json', 'candidate_sha256' => "sha256:#{Digest::SHA256.hexdigest(manifest)}",
                  'ranged_consumer' => { 'commit' => 'f' * 40, 'sha256' => 'a' * 64, 'policy_sha256' => 'b' * 64 }, 'supported_startup_policy' => policy }
      File.write(File.join(directory, 'context.json'), JSON.generate(context))
      receipt = File.join(directory, 'receipts', "#{consumer}.json")
      Dir.mkdir(File.dirname(receipt))
      prelude = 'module Gem; def self.win_platform? = true; end; load ARGV.shift'
      output, status = Open3.capture2e(RbConfig.ruby, '-e', prelude, script, consumer, File.join(directory, 'context.json'), receipt)
      written = File.file?(receipt) ? JSON.parse(File.read(receipt)) : nil
      yield output, status, written, context
    end
  end

  it 'skips an out-of-scope consumer with a marker before loading any consumer code' do
    run_smoke('current', platform: 'aarch64-mingw-ucrt', policy: { 'platform_scope' => scope }) do |output, status, written, context|
      expect(status).to be_success, output
      expect(output).to include('current consumer is out of scope for aarch64-mingw-ucrt')
      expect(written).to eq('schema' => 1, 'consumer' => 'current', 'skipped' => true, 'platform' => 'aarch64-mingw-ucrt',
                            'candidate_sha256' => context['candidate_sha256'])
    end
  end

  it 'runs in-scope and unscoped consumers as before' do
    run_smoke('ranged', platform: 'aarch64-mingw-ucrt', policy: { 'platform_scope' => scope }) do |output, status, written|
      expect(status).not_to be_success
      expect(output).not_to include('out of scope')
      expect(written).to be_nil
    end
    run_smoke('current', platform: 'x64-mingw-ucrt', policy: { 'clients' => [] }) do |output, status, written|
      expect(status).not_to be_success
      expect(output).not_to include('out of scope')
      expect(written).to be_nil
    end
  end

  it 'refuses to skip when the candidate platform differs from the approved scope' do
    run_smoke('current', platform: 'x64-mingw-ucrt', policy: { 'platform_scope' => scope }) do |output, status, written|
      expect(status).not_to be_success
      expect(output).to include('candidate platform has no approved scope')
      expect(written).to be_nil
    end
  end
end
