source "https://rubygems.org"

gem "sinatra"
gem "sinatra-contrib"
gem "activesupport", '~> 3.2'
gem "riak-client", :github => "5apps/riak-ruby-client", :branch => "invalid_uri_error"
gem "fog"

group :test do
  gem 'rake'
  gem 'purdytest', :require => false
  gem 'm'
end

group :staging, :production do
  gem "rainbows"
end
