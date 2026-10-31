# frozen_string_literal: true

require 'tmpdir'
require 'json'
require 'digest'
require 'open3'

RSpec.describe 'Frozen GTK published-byte preparation' do
  around { |example| Dir.mktmpdir { |directory| @directory = directory; example.run } }

  def prepare(corrupt: false, existing: false)
    packages = %w[red-colors gtk3].map do |name|
      bytes = "published #{name} bytes"
      filename = "#{name}-1.0.gem"
      File.write(File.join(@directory, filename), corrupt && name == 'gtk3' ? 'wrong bytes' : bytes)
      { 'name' => name, 'version' => '1.0', 'filename' => filename, 'sha256' => "sha256:#{Digest::SHA256.hexdigest(bytes)}" }
    end
    unit = { 'id' => 'gtk3-runtime', 'members' => %w[red-colors gtk3], 'packages' => packages, 'install_order' => %w[red-colors gtk3],
             'artifact' => { 'url' => 'https://example.test/published.zip', 'filename' => 'published.zip', 'archive' => 'zip', 'sha256' => "sha256:#{'a' * 64}" } }
    manifest = File.join(@directory, 'manifest.json')
    File.write(manifest, JSON.generate('schema' => 1, 'targets' => [{ 'ruby_abi' => '4.0', 'platform' => 'x64-mingw-ucrt', 'units' => [unit] }]))
    output = File.join(@directory, 'frozen')
    Dir.mkdir(output) if existing
    result, status = Open3.capture2e(RbConfig.ruby, File.expand_path('../../bin/prepare_frozen_gtk.rb', __dir__), manifest, @directory, output)
    [result, status, output, unit]
  end

  it 'copies every native and pure closure package unchanged, preserving install order' do
    text, status, output, unit = prepare
    expect(status).to be_success, text
    expect(JSON.parse(File.read(File.join(output, 'unit.json')))).to eq(unit)
    expect(Dir.children(File.join(output, 'pkg')).sort).to eq(%w[gtk3-1.0.gem red-colors-1.0.gem])
    unit.fetch('packages').each do |package|
      expect("sha256:#{Digest::SHA256.file(File.join(output, 'pkg', package.fetch('filename'))).hexdigest}").to eq(package.fetch('sha256'))
    end
  end

  it 'rejects changed published package bytes before writing a frozen output' do
    text, status, output, = prepare(corrupt: true)
    expect(status).not_to be_success
    expect(text).to include('published GTK package bytes differ')
    expect(File.exist?(output)).to be(false)
  end

  it 'refuses to overwrite a prior preparation' do
    text, status, = prepare(existing: true)
    expect(status).not_to be_success
    expect(text).to include('requires a new directory')
  end
end
