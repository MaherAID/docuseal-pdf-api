# frozen_string_literal: true

# docuseal-pdf-api (modified version of DocuSeal, AGPL-3.0) - see lib/docuseal_pdf_api.rb.

module DocusealPdfApi
  # Parses documents[].fields of POST /api/templates/pdf into TemplateRequest::Field values.
  class FieldParser
    include Validation

    # Field types of DocuSeal 3.3.3 (app/javascript/template_builder/field_type.vue).
    # "datenow" is the builder's read-only "date signed" field; it is stored as type "date".
    FIELD_TYPES = %w[heading text signature initials date datenow number image checkbox multiple file
                     radio select cells stamp payment phone verification kba strikethrough].freeze
    OPTION_FIELD_TYPES = %w[select radio multiple].freeze
    AREA_OPTION_FIELD_TYPES = %w[radio multiple].freeze

    # Keys documented for DocuSeal Pro; other keys are ignored.
    PREFERENCE_KEYS = %w[font_size font_type font color background align valign format
                         price currency mask reasons].freeze
    VALIDATION_KEYS = %w[pattern message min max step].freeze

    MAX_OPTIONS = 100
    MAX_TEXT_LENGTH = 2000

    def initialize(errors)
      @errors = errors
      @area_parser = AreaParser.new(errors)
    end

    def parse(value, path, page_count)
      return [] if value.nil?
      return add_error("#{path} must be an array") || [] unless value.is_a?(Array)

      value.each_with_index.filter_map { |field, index| parse_field(field, "#{path}[#{index}]", page_count) }
    end

    private

    def parse_field(field, path, page_count)
      return add_error("#{path} must be an object") unless field.is_a?(Hash)

      name = required_string(field, 'name', path)
      type = parse_type(field['type'], "#{path}.type")
      role = required_string(field, 'role', path)
      options = parse_options(field['options'], "#{path}.options", type)
      areas = @area_parser.parse(field['areas'], "#{path}.areas", page_count, type)

      check_options(type, options, areas, path)

      TemplateRequest::Field.new(name:, type:, role:, options:, areas:, **optional_attributes(field, path))
    end

    def optional_attributes(field, path)
      {
        required: optional_boolean(field, 'required', path),
        title: optional_string(field, 'title', path, max_length: MAX_TEXT_LENGTH),
        description: optional_string(field, 'description', path, max_length: MAX_TEXT_LENGTH),
        preferences: parse_settings(field['preferences'], "#{path}.preferences", PREFERENCE_KEYS),
        validation: parse_settings(field['validation'], "#{path}.validation", VALIDATION_KEYS)
      }
    end

    def parse_type(value, path)
      return value if FIELD_TYPES.include?(value)

      add_error("#{path} must be one of: #{FIELD_TYPES.join(', ')}")
    end

    def parse_options(value, path, type)
      return [] if value.nil?

      if type && OPTION_FIELD_TYPES.exclude?(type)
        return add_error("#{path} is only supported for #{OPTION_FIELD_TYPES.join(', ')} fields") || []
      end

      return value.map { |option| option.to_s.strip } if option_list?(value)

      add_error("#{path} must be an array of at most #{MAX_OPTIONS} strings") || []
    end

    def option_list?(value)
      value.is_a?(Array) && value.size <= MAX_OPTIONS && value.all? { |option| scalar_text?(option) }
    end

    def check_options(type, options, areas, path)
      return if OPTION_FIELD_TYPES.exclude?(type)

      if (options + areas.filter_map(&:option)).empty?
        add_error("#{path}.options must not be empty for #{type} fields")
      elsif AREA_OPTION_FIELD_TYPES.include?(type)
        check_area_options(type, options, areas, path)
      end
    end

    # A radio/multiple field with several areas needs to know which option each area shows.
    def check_area_options(type, options, areas, path)
      return if areas.size < 2 || areas.all?(&:option)
      return if areas.none?(&:option) && options.size == areas.size

      add_error("#{path}.areas[].option is required on every area of a #{type} field with several areas " \
                '(or pass exactly one entry in options per area)')
    end

    def parse_settings(value, path, allowed_keys)
      return {} if value.nil?
      return add_error("#{path} must be an object") || {} unless value.is_a?(Hash)

      value.to_h.slice(*allowed_keys).each_with_object({}) do |(key, item), settings|
        next settings[key.to_s] = item if setting_value?(item)

        add_error("#{path}.#{key} must be a string, number, boolean or an array of strings")
      end
    end

    def setting_value?(item)
      scalar?(item) || (item.is_a?(Array) && item.all?(String))
    end
  end
end
