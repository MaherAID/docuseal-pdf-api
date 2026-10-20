# frozen_string_literal: true

# Development tooling only: RuboCop for the overlay Ruby files, pinned to the versions
# DocuSeal 3.3.3 uses (see its Gemfile.lock). The application gems come from the upstream
# image and are not managed here.
source 'https://rubygems.org'

ruby '>= 4.0.0'

group :development do
  gem 'rubocop', '1.92.0', require: false
  gem 'rubocop-performance', '1.27.0', require: false
  gem 'rubocop-rails', '2.38.0', require: false
end
