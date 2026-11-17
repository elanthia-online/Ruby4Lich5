# frozen_string_literal: true

require 'yaml'

# The bundle's patch_fingerprints record must describe the committed curated
# tree: taken before "Prepare native gems" may generate patches, relayed to the
# smoke job, and embedded in gem-build-metadata.json, which accepted package
# reuse reads (bin/prepare_replacement.rb -> PatchFingerprint.read_metadata).
RSpec.describe 'Curated patch fingerprint recording' do
  root = File.expand_path('../..', __dir__)
  let(:jobs) { YAML.load_file(File.join(root, '.github/workflows/ruby4-bundled-gems-suite.yml')).fetch('jobs') }
  let(:build) { jobs.fetch('build_ruby4_bundled_gems_suite').fetch('steps') }
  let(:smoke) { jobs.fetch('smoke_ruby4_bundled_gems_suite').fetch('steps') }

  def index(steps, name) = steps.index { |step| step['name'].to_s.start_with?(name) }

  it 'records fingerprints, carrying the replacement plan record, before native gem preparation' do
    reuse = index(build, 'Prepare accepted package reuse')
    prepare = index(build, 'Prepare native gems')
    run = build[reuse].fetch('run')
    expect(reuse).to be < prepare
    expect(run).to include('bin/record_patch_fingerprints.rb @recordArgs')
    expect(run).to include('if ($planPath) { $recordArgs += $planPath }')
    expect(run.index('bin/record_patch_fingerprints.rb')).to be > run.index('bin/prepare_replacement.rb')
    expect(run).to include('"PATCH_FINGERPRINTS=$patchRecord"')
  end

  it 'relays the record to the smoke job and embeds it in the bundle metadata' do
    relay = build[index(build, 'Retain verified source-package receipts')].fetch('run')
    expect(index(build, 'Retain verified source-package receipts')).to be < index(build, 'Upload packaged runtime gem bundle')
    expect(relay).to include("Copy-Item -LiteralPath $env:PATCH_FINGERPRINTS -Destination (Join-Path $env:PKG_DIR 'patch-fingerprints.json')")
    stage = smoke[index(smoke, 'Stage artifact')].fetch('run')
    expect(stage).to include("-PatchFingerprintsPath (Join-Path $pkgDir 'patch-fingerprints.json')")
  end

  it 'passes the accepted record into the replacement plan' do
    bin = File.read(File.join(root, 'bin/prepare_replacement.rb'))
    expect(bin).to include("PatchFingerprint.read_metadata(File.join(directory, 'bundle/gem-build-metadata.json'))")
    expect(bin).to include('accepted_patches: accepted_patches')
  end
end
