# frozen_string_literal: true

# docuseal-pdf-api - a modified version of DocuSeal (https://github.com/docusealco/docuseal)
# that adds POST /api/templates/pdf. Copyright (C) 2026 Auto-i-DAT AG.
# Licensed under the GNU Affero General Public License v3.0 together with the additional
# terms of DocuSeal (see LICENSE and LICENSE_ADDITIONAL_TERMS).
# Corresponding source: https://github.com/MaherAID/docuseal-pdf-api

# Namespace and runtime configuration of the docuseal-pdf-api overlay.
module DocusealPdfApi
  VERSION = '0.1.0'
  REPOSITORY_URL = 'https://github.com/MaherAID/docuseal-pdf-api'
  REVISION_FORMAT = /\A[0-9a-f]{7,40}\z/

  # Raised when the request body of POST /api/templates/pdf is invalid (rendered as HTTP 422).
  class InvalidRequest < StandardError
    attr_reader :errors

    def initialize(errors)
      @errors = Array(errors)

      super(@errors.first)
    end
  end

  module_function

  # Where network users obtain the Corresponding Source of the running version
  # (AGPL-3.0 section 13). SOURCE_CODE_URL overrides it, e.g. for a fork or mirror.
  def source_code_url
    ENV['SOURCE_CODE_URL'].presence || revision_url || REPOSITORY_URL
  end

  # Links to the exact commit when the image was built with SOURCE_REVISION (CI does that).
  def revision_url
    revision = ENV.fetch('DOCUSEAL_PDF_API_REVISION', '').strip

    "#{REPOSITORY_URL}/tree/#{revision}" if REVISION_FORMAT.match?(revision)
  end
end
