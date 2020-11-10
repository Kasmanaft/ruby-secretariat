# frozen_string_literal: true

require 'bigdecimal'
module Secretariat
  Tax = Struct.new('Tax', :tax_category, :tax_percent, :tax_amount, :basis_amount, :tax_reason, :currency_code, keyword_init: true) do
    include Versioner

    def errors
      @errors
    end

    def valid?
      true
    end

    def tax_reason_text
      tax_reason || TAX_EXEMPTION_REASONS[tax_category]
    end

    def tax_category_code(version: 2)
      return TAX_CATEGORY_CODES_1[tax_category] || 'S' if version == 1

      TAX_CATEGORY_CODES[tax_category] || 'S'
    end

    def to_xml(xml, version: 2)
      raise ValidationError.new('Invoice is invalid', errors) unless valid?

      xml['ram'].ApplicableTradeTax do
        Helpers.currency_element(xml, 'ram', 'CalculatedAmount', tax_amount, currency_code, add_currency: version == 1)
        xml['ram'].TypeCode 'VAT'
        if tax_reason_text && tax_reason_text != ''
          xml['ram'].ExemptionReason tax_reason_text
        end
        Helpers.currency_element(xml, 'ram', 'BasisAmount', basis_amount, currency_code, add_currency: version == 1)
        xml['ram'].CategoryCode tax_category_code(version: version)

        percent = by_version(version, 'ApplicablePercent', 'RateApplicablePercent')
        xml['ram'].send(percent, Helpers.format(tax_percent))
      end
    end
  end
end
