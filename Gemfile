=begin
When building Gemfile.lock file, please add additional platforms to the file via the following command:

bundle lock \
  --add-platform x64-mingw-ucrt \
  --add-platform x86_64-linux \
  --add-platform x86_64-linux-musl \
  --add-platform arm64-darwin \
  --add-platform x86_64-darwin

This ensures that the lock file can be used by all platforms that are able to support it.
=end

source "https://rubygems.org"

group :development do
  gem "rspec"
  gem "rubocop"
end
