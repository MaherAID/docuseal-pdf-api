# frozen_string_literal: true

# docuseal-pdf-api (modified version of DocuSeal, AGPL-3.0) - see lib/docuseal_pdf_api.rb.

module DocusealPdfApi
  # Parses and validates the JSON body of POST /api/templates/pdf.
  #
  # Field areas are relative to the rendered page (0..1, origin top-left, as DocuSeal stores
  # them) and pages are 1-based like in the DocuSeal Pro API. The parser keeps the API values;
  # TemplateBuilder converts the page number to DocuSeal's 0-based index.
  class TemplateRequest
    include Validation

    MAX_REQUEST_BYTES = Integer(ENV.fetch('PDF_API_MAX_REQUEST_MB', '64')).megabytes
    MAX_DOCUMENTS = 10
    MAX_FIELDS = 500
    MAX_ERRORS = 50

    Area = Data.define(:x, :y, :w, :h, :page, :option, :cell_w)

    Field = Data.define(:name, :type, :role, :required, :title, :description, :options, :preferences,
                        :validation, :areas)

    Document = Data.define(:name, :data, :page_count, :fields) do
      def filename
        name.match?(/\.pdf\z/i) ? name : "#{name}.pdf"
      end
    end

    Result = Data.define(:name, :external_id, :folder_name, :shared_link, :documents) do
      # Distinct roles in order of first appearance; they become the template submitters.
      def roles
        documents.flat_map(&:fields).map(&:role).uniq
      end
    end

    # Returns a Result or raises InvalidRequest listing every problem found.
    def self.parse(params)
      new.parse(params)
    end

    def parse(params)
      @errors = []

      result = build_result(params.is_a?(Hash) ? params : {})

      raise InvalidRequest, @errors.first(MAX_ERRORS) if @errors.any?

      result
    end

    private

    def build_result(params)
      name = required_string(params, 'name', '')
      external_id = parse_external_id(params['external_id'])
      folder_name = optional_string(params, 'folder_name', '')
      shared_link = optional_boolean(params, 'shared_link', '') || false

      # Accepted for DocuSeal Pro compatibility without effect: text tags are not parsed and
      # PDF form fields are kept as they are.
      optional_boolean(params, 'flatten', '')
      optional_boolean(params, 'remove_tags', '')

      documents = parse_documents(params['documents'])
      fields = documents.flat_map(&:fields)

      check_field_count(documents, fields)
      check_role_names(fields)

      Result.new(name:, external_id:, folder_name:, shared_link:, documents:)
    end

    def parse_external_id(value)
      return if value.nil?

      text = value.to_s.strip if value.is_a?(String) || value.is_a?(Integer)

      return text.presence if text && text.length <= MAX_NAME_LENGTH

      add_error("external_id must be a string of at most #{MAX_NAME_LENGTH} characters")
    end

    def parse_documents(value)
      return add_error('documents must be a non-empty array') || [] unless value.is_a?(Array) && value.any?

      if value.size > MAX_DOCUMENTS
        return add_error("documents must not contain more than #{MAX_DOCUMENTS} entries") || []
      end

      value.each_with_index.filter_map { |document, index| parse_document(document, "documents[#{index}]") }
    end

    def parse_document(document, path)
      return add_error("#{path} must be an object") unless document.is_a?(Hash)

      name = required_string(document, 'name', path)
      pdf = PdfDecoder.new(@errors).decode(document['file'], "#{path}.file")
      fields = FieldParser.new(@errors).parse(document['fields'], "#{path}.fields", pdf&.page_count)

      Document.new(name:, data: pdf&.data, page_count: pdf&.page_count, fields:)
    end

    def check_field_count(documents, fields)
      if documents.any? && fields.empty?
        add_error('documents[].fields must define at least one field (PDF text tags are not supported)')
      end

      add_error("documents[].fields must not contain more than #{MAX_FIELDS} fields") if fields.size > MAX_FIELDS
    end

    # Submissions match roles case-insensitively, so "Kunde" and "kunde" would be ambiguous.
    def check_role_names(fields)
      fields.filter_map(&:role).uniq.group_by(&:downcase).each_value do |variants|
        add_error("roles must be unique ignoring case: #{variants.join(', ')}") if variants.size > 1
      end
    end
  end
end
