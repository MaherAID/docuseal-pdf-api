# frozen_string_literal: true

# docuseal-pdf-api (modified version of DocuSeal, AGPL-3.0) - see lib/docuseal_pdf_api.rb.

module Api
  # POST /api/templates/pdf - creates a signable template from a base64-encoded PDF and
  # explicit field areas. Request and response follow the DocuSeal Pro API; differences are
  # documented in README.md ("API reference").
  #
  # Authentication (X-Auth-Token), the error format and the 401/403 handling come from
  # Api::ApiBaseController; authorization is the same `create` ability on Template that the
  # upstream template upload and clone endpoints check.
  class TemplatesPdfController < ApiBaseController
    rescue_from DocusealPdfApi::InvalidRequest do |e|
      render json: { error: e.message, errors: e.errors }, status: :unprocessable_content
    end

    rescue_from Templates::CreateAttachments::PdfEncrypted do
      render json: { error: 'PDF is password-protected' }, status: :unprocessable_content
    end

    def create
      template = Template.new(account: current_account, author: current_user, source: :api)

      authorize!(:create, template)

      return render_request_too_large if request_too_large?

      template_request = DocusealPdfApi::TemplateRequest.parse(params.to_unsafe_h)

      DocusealPdfApi::TemplateBuilder.call(template, template_request, author: current_user)

      enqueue_created_callbacks(template)

      render json: Templates::SerializeForApi.call(template.reload)
    end

    private

    # Checked before the action reads params, so oversized bodies are rejected early.
    def request_too_large?
      request.content_length.to_i > DocusealPdfApi::TemplateRequest::MAX_REQUEST_BYTES
    end

    def render_request_too_large
      render json: { error: 'Request body is too large' }, status: :content_too_large
    end

    # Same follow-up work as the upstream upload and clone endpoints.
    def enqueue_created_callbacks(template)
      WebhookUrls.enqueue_events(template, 'template.created')
      SearchEntries.enqueue_reindex(template)
    end
  end
end
