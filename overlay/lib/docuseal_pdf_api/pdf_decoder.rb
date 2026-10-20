# frozen_string_literal: true

# docuseal-pdf-api (modified version of DocuSeal, AGPL-3.0) - see lib/docuseal_pdf_api.rb.

module DocusealPdfApi
  # Turns documents[].file (base64, optionally a data: URL) into PDF bytes and a page count.
  class PdfDecoder
    include Validation

    MAX_FILE_BYTES = Integer(ENV.fetch('PDF_API_MAX_FILE_MB', '20')).megabytes
    PDF_HEADER = '%PDF-'
    DATA_URL_PREFIX = %r{\Adata:[\w.+/-]*;base64,}i

    Decoded = Data.define(:data, :page_count)

    def initialize(errors)
      @errors = errors
    end

    # Returns Decoded (page_count is nil when the PDF cannot be opened) or nil on errors.
    def decode(value, path)
      data = decode_base64(value, path)

      return unless data
      return add_error("#{path} exceeds the maximum size of #{max_file_mb} MB") if data.bytesize > MAX_FILE_BYTES
      return add_error("#{path} is not a PDF (the file must start with #{PDF_HEADER})") unless pdf?(data)

      Decoded.new(data:, page_count: read_page_count(data, path))
    end

    private

    def decode_base64(value, path)
      return add_error("#{path} is required (base64-encoded PDF)") unless value.is_a?(String) && value.present?

      encoded = value.sub(DATA_URL_PREFIX, '')
      encoded = encoded.gsub(/\s+/, '') if encoded.match?(/\s/)

      # Reject oversized payloads before allocating the decoded copy.
      return add_error("#{path} exceeds the maximum size of #{max_file_mb} MB") if encoded.bytesize > max_encoded_bytes

      Base64.strict_decode64(pad(encoded))
    rescue ArgumentError
      add_error("#{path} is not valid base64")
    end

    def pdf?(data)
      data.start_with?(PDF_HEADER)
    end

    def read_page_count(data, path)
      page_count = Pdfium::Document.open_bytes(data, &:page_count)

      page_count.positive? ? page_count : add_error("#{path} contains no pages")
    rescue Pdfium::PasswordError
      add_error("#{path} is password-protected; remove the password before uploading")
    rescue Pdfium::PdfiumError
      add_error("#{path} could not be read as a PDF")
    end

    def pad(encoded)
      remainder = encoded.length % 4

      remainder.zero? ? encoded : encoded + ('=' * (4 - remainder))
    end

    def max_encoded_bytes
      ((MAX_FILE_BYTES + 2) / 3) * 4
    end

    def max_file_mb
      MAX_FILE_BYTES / 1.megabyte
    end
  end
end
