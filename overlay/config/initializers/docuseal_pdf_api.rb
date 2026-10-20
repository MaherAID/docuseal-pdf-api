# frozen_string_literal: true

# docuseal-pdf-api (modified version of DocuSeal, AGPL-3.0) - see lib/docuseal_pdf_api.rb.
#
# Wires the overlay into DocuSeal without editing upstream files:
# - config/routes.rb ends its draw block with ActiveSupport.run_load_hooks(:routes, self),
#   so this hook appends our routes inside the same draw (the Dockerfile verifies the call);
# - the AGPL source offer is a partial in a view path that is searched before app/views.

ActiveSupport.on_load(:routes) do
  namespace :api, defaults: { format: :json } do
    post 'templates/pdf', to: 'templates_pdf#create', as: :templates_pdf
  end

  get 'source', to: 'docuseal_pdf_api/source#show', as: :docuseal_pdf_api_source
end

ActiveSupport.on_load(:action_controller_base) do
  prepend_view_path Rails.root.join('vendor/docuseal_pdf_api/views')
end
