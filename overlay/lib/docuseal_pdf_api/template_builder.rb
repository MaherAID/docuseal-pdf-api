# frozen_string_literal: true

# docuseal-pdf-api (modified version of DocuSeal, AGPL-3.0) - see lib/docuseal_pdf_api.rb.

module DocusealPdfApi
  # Creates a DocuSeal template from a validated TemplateRequest::Result.
  #
  # The PDF goes through the same upstream services as the web upload
  # (Templates::CreateAttachments -> Templates::ProcessDocument), so the stored document,
  # the page preview images and the PDF metadata are identical to an uploaded file and the
  # signing form works unchanged. Fields get the defaults of the upstream template builder.
  module TemplateBuilder
    PDF_CONTENT_TYPE = 'application/pdf'

    # Per-type defaults copied from app/javascript/template_builder/builder.vue (addField).
    TYPE_DEFAULTS = {
      'stamp' => { 'readonly' => true },
      'datenow' => { 'type' => 'date', 'readonly' => true, 'default_value' => '{{date}}' },
      'strikethrough' => { 'readonly' => true, 'default_value' => true }
    }.freeze

    module_function

    def call(template, request, author:)
      submitters = request.roles.map { |role| { 'name' => role, 'uuid' => SecureRandom.uuid } }
      submitter_uuids = submitters.to_h { |submitter| submitter.values_at('name', 'uuid') }

      ApplicationRecord.transaction do
        assign_attributes(template, request, author:, submitters:)

        template.save!

        schema, fields = attach_documents(template, request.documents, submitter_uuids)

        template.update!(schema:, fields:)
      end

      template
    end

    def assign_attributes(template, request, author:, submitters:)
      template.name = request.name
      template.external_id = request.external_id
      template.shared_link = request.shared_link
      template.folder = TemplateFolders.find_or_create_by_name(author, request.folder_name)
      template.submitters = submitters

      Templates.maybe_assign_access(template)
    end

    def attach_documents(template, documents, submitter_uuids)
      documents.each_with_object([[], []]) do |document, (schema, fields)|
        attachment = attach_pdf(template, document)

        schema << { 'attachment_uuid' => attachment.uuid, 'name' => attachment.filename.base }

        document.fields.each { |field| fields << build_field(field, attachment.uuid, submitter_uuids) }
      end
    end

    def attach_pdf(template, document)
      file = ActionDispatch::Http::UploadedFile.new(
        tempfile: StringIO.new(document.data),
        filename: document.filename,
        type: PDF_CONTENT_TYPE
      )

      Templates::CreateAttachments.handle_pdf_or_image(template, file, document.data, {}, extract_fields: false)
    end

    def build_field(field, attachment_uuid, submitter_uuids)
      options = build_options(field)

      {
        'uuid' => SecureRandom.uuid,
        'submitter_uuid' => submitter_uuids.fetch(field.role),
        'name' => field.name,
        'type' => field.type,
        'required' => required?(field),
        'preferences' => field.preferences,
        'areas' => build_areas(field, attachment_uuid, options),
        **optional_attributes(field, options)
      }.merge(TYPE_DEFAULTS.fetch(field.type, {}))
    end

    # Like the template builder: every field is required by default except checkboxes.
    def required?(field)
      field.required.nil? ? field.type != 'checkbox' : field.required
    end

    def optional_attributes(field, options)
      {
        'title' => field.title,
        'description' => field.description,
        'options' => options,
        'validation' => field.validation.presence
      }.compact
    end

    def build_options(field)
      return if FieldParser::OPTION_FIELD_TYPES.exclude?(field.type)

      (field.options + field.areas.filter_map(&:option)).uniq.map do |value|
        { 'value' => value, 'uuid' => SecureRandom.uuid }
      end
    end

    def build_areas(field, attachment_uuid, options)
      field.areas.each_with_index.map { |area, index| build_area(field, area, index, attachment_uuid, options) }
    end

    def build_area(field, area, index, attachment_uuid, options)
      attrs = { 'x' => area.x, 'y' => area.y, 'w' => area.w, 'h' => area.h,
                'attachment_uuid' => attachment_uuid, 'page' => area.page - 1 }

      option = area_option(field, area, index, options)

      attrs['option_uuid'] = option['uuid'] if option
      attrs['cell_w'] = area.cell_w || default_cell_width(area) if field.type == 'cells'

      attrs
    end

    # Radio/multiple areas reference an option: by its value, or by position when the
    # request passed one option per area instead.
    def area_option(field, area, index, options)
      return if FieldParser::AREA_OPTION_FIELD_TYPES.exclude?(field.type)
      return options.find { |item| item['value'] == area.option } if area.option

      options[index] if field.areas.size > 1 && field.areas.none?(&:option)
    end

    # Same default as the template builder (field.vue): w * 2 / floor(w / h).
    def default_cell_width(area)
      cells = (area.w / area.h).floor

      cells.positive? ? area.w * 2 / cells : area.w
    end
  end
end
