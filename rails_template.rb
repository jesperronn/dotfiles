# usage:
#
# rails new . -m ~/.dotfiles/rails_template.rb

gem 'devise'
gem 'enumerize'
gem 'pg'
gem 'rails-i18n'

gem_group :development do
  gem 'pry-rails'
  gem 'rubocop', require: false
  gem 'rubocop-rails', require: false
  gem 'rubocop-performance', require: false
  gem 'rubocop-rspec', require: false
end

gem_group :development, :test do
  gem 'rspec-rails', require: false
end

after_bundle do
  generate 'rspec:install'
end
