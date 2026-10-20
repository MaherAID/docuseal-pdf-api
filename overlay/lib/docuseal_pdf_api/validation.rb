# frozen_string_literal: true

# docuseal-pdf-api (modified version of DocuSeal, AGPL-3.0) - see lib/docuseal_pdf_api.rb.

module DocusealPdfApi
  # Shared helpers of the request parsers. They collect messages in @errors instead of
  # raising, so one 422 response can report every problem of a payload at once.
  module Validation
    MAX_NAME_LENGTH = 255

    private

    def add_error(message)
      @errors << message

      nil
    end

    def join_path(path, key)
      path.empty? ? key : "#{path}.#{key}"
    end

    def required_string(hash, key, path, max_length: MAX_NAME_LENGTH)
      value = hash[key]
      text = value.strip if value.is_a?(String)
      label = join_path(path, key)

      return add_error("#{label} is required and must be a non-empty string") if text.blank?
      return add_error("#{label} must not exceed #{max_length} characters") if text.length > max_length

      text
    end

    def optional_string(hash, key, path, max_length: MAX_NAME_LENGTH)
      value = hash[key]

      return if value.nil?

      label = join_path(path, key)

      return add_error("#{label} must be a string") unless value.is_a?(String)
      return add_error("#{label} must not exceed #{max_length} characters") if value.strip.length > max_length

      value.strip.presence
    end

    def optional_boolean(hash, key, path)
      value = hash[key]

      return value if value.nil? || value == true || value == false

      add_error("#{join_path(path, key)} must be true or false")
    end

    def scalar?(value)
      value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false
    end

    def scalar_text?(value)
      (value.is_a?(String) || value.is_a?(Numeric)) && value.to_s.length <= MAX_NAME_LENGTH
    end
  end
end
