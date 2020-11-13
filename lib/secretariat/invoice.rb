# frozen_string_literal: true

# Copyright Jan Krutisch
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'bigdecimal'

module Secretariat
  Invoice = Struct.new('Invoice',
                       :id,
                       :issue_date,
                       :seller,
                       :buyer,
                       :line_items,
                       :currency_code,
                       :payment_type,
                       :payment_info,
                       :taxes,
                       :tax_amount,
                       :basis_amount,
                       :grand_total_amount,
                       :due_amount,
                       :paid_amount,
                       :type,
                       :payment_text,
                       :due_date,
                       keyword_init: true) do
    include Versioner

    def errors
      @errors
    end

    def payment_code
      PAYMENT_CODES[payment_type] || '1'
    end

    def valid?
      @errors = []
      tax = BigDecimal(tax_amount)
      basis = BigDecimal(basis_amount)
      # calc_tax = basis * BigDecimal(tax_percent) / BigDecimal(100)
      # calc_tax = calc_tax.round(2, :down)
      # if tax != calc_tax
      #   @errors << "Tax amount and calculated tax amount deviate: #{tax} / #{calc_tax}"
      #   return false
      # end
      grand_total = BigDecimal(grand_total_amount)
      calc_grand_total = basis + tax
      if grand_total != calc_grand_total
        @errors << "Grand total amount and calculated grand total amount deviate: #{grand_total} / #{calc_grand_total}"
        return false
      end
      line_item_sum = line_items.inject(BigDecimal(0)) do |m, item|
        m + BigDecimal(item.total_amount)
      end
      if line_item_sum != basis
        @errors << "Line items do not add up to basis amount #{line_item_sum} / #{basis}"
        return false
      end
      true
    end

    def namespaces(version: 1)
      by_version(version,
                 {
                   'xmlns:ram' => 'urn:un:unece:uncefact:data:standard:ReusableAggregateBusinessInformationEntity:12',
                   'xmlns:udt' => 'urn:un:unece:uncefact:data:standard:UnqualifiedDataType:15',
                   'xmlns:rsm' => 'urn:ferd:CrossIndustryDocument:invoice:1p0',
                   'xmlns:xsi' => 'http://www.w3.org/2001/XMLSchema-instance'
                 },
                 'xmlns:qdt' => 'urn:un:unece:uncefact:data:standard:QualifiedDataType:100',
                 'xmlns:ram' => 'urn:un:unece:uncefact:data:standard:ReusableAggregateBusinessInformationEntity:100',
                 'xmlns:udt' => 'urn:un:unece:uncefact:data:standard:UnqualifiedDataType:100',
                 'xmlns:rsm' => 'urn:un:unece:uncefact:data:standard:CrossIndustryInvoice:100',
                 'xmlns:xsi' => 'http://www.w3.org/2001/XMLSchema-instance')
    end

    def invoice_name_and_type(xml, version)
      self[:type] ||= :INVOICE
      xml['ram'].Name INVOICE_TYPES[type][:name] if version == 1
      xml['ram'].TypeCode INVOICE_TYPES[type][:code]
    end

    def to_xml(version: 1)
      raise 'Unsupported Document Version' if version < 1 || version > 2

      raise ValidationError.new('Invoice is invalid', errors) unless valid?

      builder = Nokogiri::XML::Builder.new do |xml|
        root = by_version(version, 'CrossIndustryDocument', 'CrossIndustryInvoice')

        xml['rsm'].send(root, namespaces(version: version)) do
          context = by_version(version, 'SpecifiedExchangedDocumentContext', 'ExchangedDocumentContext')

          xml['rsm'].send(context) do
            xml['ram'].GuidelineSpecifiedDocumentContextParameter do
              version_id = by_version(version, 'urn:ferd:CrossIndustryDocument:invoice:1p0:comfort', 'urn:cen.eu:en16931:2017')
              xml['ram'].ID version_id
            end
          end

          header = by_version(version, 'HeaderExchangedDocument', 'ExchangedDocument')

          xml['rsm'].send(header) do
            xml['ram'].ID id
            invoice_name_and_type(xml, version)
            # xml['ram'].Name 'RECHNUNG' if version == 1
            # xml['ram'].TypeCode '380' # TODO: make configurable
            xml['ram'].IssueDateTime do
              xml['udt'].DateTimeString(format: '102') do
                xml.text(issue_date.strftime('%Y%m%d'))
              end
            end
          end
          transaction = by_version(version, 'SpecifiedSupplyChainTradeTransaction', 'SupplyChainTradeTransaction')
          xml['rsm'].send(transaction) do
            if version == 2
              line_items.each_with_index do |item, i|
                item.to_xml(xml, i + 1, version: version) # one indexed
              end
            end

            trade_agreement = by_version(version, 'ApplicableSupplyChainTradeAgreement', 'ApplicableHeaderTradeAgreement')

            xml['ram'].send(trade_agreement) do
              xml['ram'].SellerTradeParty do
                seller.to_xml(xml, version: version)
              end
              xml['ram'].BuyerTradeParty do
                buyer.to_xml(xml, version: version)
              end
            end

            delivery = by_version(version, 'ApplicableSupplyChainTradeDelivery', 'ApplicableHeaderTradeDelivery')

            xml['ram'].send(delivery) do
              if version == 2
                xml['ram'].ShipToTradeParty do
                  buyer.to_xml(xml, exclude_tax: true, version: version)
                end
              end
              xml['ram'].ActualDeliverySupplyChainEvent do
                xml['ram'].OccurrenceDateTime do
                  xml['udt'].DateTimeString(format: '102') do
                    xml.text(issue_date.strftime('%Y%m%d'))
                  end
                end
              end
            end
            trade_settlement = by_version(version, 'ApplicableSupplyChainTradeSettlement', 'ApplicableHeaderTradeSettlement')
            xml['ram'].send(trade_settlement) do
              xml['ram'].InvoiceCurrencyCode currency_code
              xml['ram'].SpecifiedTradeSettlementPaymentMeans do
                xml['ram'].TypeCode payment_code
                xml['ram'].Information payment_info
              end

              taxes.each { |tax| tax.to_xml(xml, version: version) }

              # xml['ram'].SpecifiedTradePaymentTerms do
              #   xml['ram'].Description 'Paid'
              # end

              unless self[:payment_text].nil?
                xml['ram'].SpecifiedTradePaymentTerms do
                  xml['ram'].Description payment_text
                  xml['ram'].DueDateDateTime do
                    xml['udt'].DateTimeString(format: '102') do
                      xml.text(due_date.strftime('%Y%m%d'))
                    end
                  end
                end
              end

              monetary_summation = by_version(version, 'SpecifiedTradeSettlementMonetarySummation', 'SpecifiedTradeSettlementHeaderMonetarySummation')

              xml['ram'].send(monetary_summation) do
                Helpers.currency_element(xml, 'ram', 'LineTotalAmount', basis_amount, currency_code, add_currency: version == 1)
                # TODO: Fix this!
                Helpers.currency_element(xml, 'ram', 'ChargeTotalAmount', BigDecimal(0), currency_code, add_currency: version == 1)
                Helpers.currency_element(xml, 'ram', 'AllowanceTotalAmount', BigDecimal(0), currency_code, add_currency: version == 1)
                Helpers.currency_element(xml, 'ram', 'TaxBasisTotalAmount', basis_amount, currency_code, add_currency: version == 1)
                Helpers.currency_element(xml, 'ram', 'TaxTotalAmount', tax_amount, currency_code, add_currency: true)
                Helpers.currency_element(xml, 'ram', 'GrandTotalAmount', grand_total_amount, currency_code, add_currency: version == 1)
                Helpers.currency_element(xml, 'ram', 'TotalPrepaidAmount', paid_amount, currency_code, add_currency: version == 1)
                Helpers.currency_element(xml, 'ram', 'DuePayableAmount', due_amount, currency_code, add_currency: version == 1)
              end
            end
            if version == 1
              line_items.each_with_index do |item, i|
                item.to_xml(xml, i + 1, version: version) # one indexed
              end
            end
          end
        end
      end
      builder.to_xml
    end
  end
end
