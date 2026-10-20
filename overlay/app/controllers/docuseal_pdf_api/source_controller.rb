# frozen_string_literal: true

# docuseal-pdf-api (modified version of DocuSeal, AGPL-3.0) - see lib/docuseal_pdf_api.rb.

module DocusealPdfApi
  # GET /source - offers the Corresponding Source of this modified version to every network
  # user (AGPL-3.0 section 13), e.g. API clients that never see the signing pages.
  class SourceController < ActionController::API
    def show
      redirect_to DocusealPdfApi.source_code_url, allow_other_host: true
    end
  end
end
