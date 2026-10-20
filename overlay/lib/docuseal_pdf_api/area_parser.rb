# frozen_string_literal: true

# docuseal-pdf-api (modified version of DocuSeal, AGPL-3.0) - see lib/docuseal_pdf_api.rb.

module DocusealPdfApi
  # Parses documents[].fields[].areas into TemplateRequest::Area values.
  #
  # x, y, w and h are fractions of the rendered page (origin top-left); page is 1-based.
  class AreaParser
    include Validation

    MAX_AREAS = 100
    TOLERANCE = 1e-6

    def initialize(errors)
      @errors = errors
    end

    def parse(value, path, page_count, type)
      return add_error("#{path} must be a non-empty array") || [] unless value.is_a?(Array) && value.any?
      return add_error("#{path} must not contain more than #{MAX_AREAS} areas") || [] if value.size > MAX_AREAS

      value.each_with_index.filter_map { |area, index| parse_area(area, "#{path}[#{index}]", page_count, type) }
    end

    private

    def parse_area(area, path, page_count, type)
      return add_error("#{path} must be an object") unless area.is_a?(Hash)

      x, y, w, h = %w[x y w h].map { |key| coordinate(area, key, path) }

      check_bounds(x, y, w, h, path)

      TemplateRequest::Area.new(
        x:, y:, w:, h:,
        page: parse_page(area['page'], "#{path}.page", page_count),
        option: parse_option(area['option'], "#{path}.option", type),
        cell_w: parse_cell_width(area['cell_w'], "#{path}.cell_w", type, w)
      )
    end

    # x and y may be 0, width and height must be positive; all are at most 1.
    def coordinate(area, key, path)
      value = area[key]
      allow_zero = %w[x y].include?(key)

      return value.to_f if valid_coordinate?(value, allow_zero:)

      lower = allow_zero ? 'from 0' : 'greater than 0'

      add_error("#{path}.#{key} must be a number #{lower} up to 1 (relative to the page size)")
    end

    def valid_coordinate?(value, allow_zero:)
      return false unless value.is_a?(Numeric) && value.finite? && value <= 1

      allow_zero ? value >= 0 : value.positive?
    end

    def check_bounds(left, top, width, height, path)
      if left && width && left + width > 1 + TOLERANCE
        add_error("#{path} exceeds the page width (x + w must not exceed 1)")
      end

      return unless top && height && top + height > 1 + TOLERANCE

      add_error("#{path} exceeds the page height (y + h must not exceed 1)")
    end

    def parse_page(value, path, page_count)
      page = whole_number(value)

      return page if page&.between?(1, page_count || Float::INFINITY)

      range = page_count ? "between 1 and #{page_count} (pages of the document)" : 'of at least 1'

      add_error("#{path} must be an integer #{range}")
    end

    def whole_number(value)
      return value if value.is_a?(Integer)

      value.to_i if value.is_a?(Float) && value.finite? && (value % 1).zero?
    end

    def parse_option(value, path, type)
      return if value.nil?

      if type && FieldParser::AREA_OPTION_FIELD_TYPES.exclude?(type)
        return add_error("#{path} is only supported for #{FieldParser::AREA_OPTION_FIELD_TYPES.join(' and ')} fields")
      end

      scalar_text?(value) ? value.to_s.strip : add_error("#{path} must be a string")
    end

    def parse_cell_width(value, path, type, area_width)
      return if value.nil?
      return add_error("#{path} is only supported for cells fields") if type && type != 'cells'
      return value.to_f if value.is_a?(Numeric) && value.positive? && value <= (area_width || 1) + TOLERANCE

      add_error("#{path} must be a number greater than 0 and at most the area width")
    end
  end
end
