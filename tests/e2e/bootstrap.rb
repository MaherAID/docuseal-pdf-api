# frozen_string_literal: true

# End-to-end test bootstrap, executed inside the app container by tests/e2e/run.sh:
#   bin/rails runner - < tests/e2e/bootstrap.rb
#
# Creates what the DocuSeal setup wizard creates (account, admin user, app URL and the
# e-signature certificates), registers the webhook receiver for all events and prints the
# admin's API token as the single line "E2E_API_TOKEN=<token>". The admin password is random
# and never printed. Safe to run more than once.

webhook_url = ENV.fetch('E2E_WEBHOOK_URL')
app_url = ENV.fetch('APP_URL')

user = ActiveRecord::Base.transaction do
  account = Account.find_or_create_by!(name: 'E2E Test Account') do |new_account|
    new_account.timezone = 'UTC'
    new_account.locale = 'en-US'
  end

  admin = account.users.find_or_create_by!(email: 'e2e-admin@example.com') do |new_user|
    new_user.first_name = 'E2E'
    new_user.last_name = 'Admin'
    new_user.role = User::ADMIN_ROLE
    new_user.password = SecureRandom.base58(32)
  end

  account.encrypted_configs.find_or_create_by!(key: EncryptedConfig::APP_URL_KEY) do |config|
    config.value = app_url
  end

  account.encrypted_configs.find_or_create_by!(key: EncryptedConfig::ESIGN_CERTS_KEY) do |config|
    config.value = GenerateCertificate.call.transform_values(&:to_pem)
  end

  if SearchEntry.table_exists?
    account.account_configs.find_or_create_by!(key: :fulltext_search) { |config| config.value = true }
  end

  webhook = account.webhook_urls.find_or_initialize_by(sha1: Digest::SHA1.hexdigest(webhook_url))
  webhook.update!(
    url: webhook_url,
    events: WebhookUrl::EVENTS,
    secret: { 'X-E2E-Webhook-Secret' => ENV.fetch('E2E_WEBHOOK_SECRET') },
    hmac_secret: ENV.fetch('E2E_WEBHOOK_HMAC_SECRET')
  )

  admin
end

puts "E2E_API_TOKEN=#{user.access_token.token}"
