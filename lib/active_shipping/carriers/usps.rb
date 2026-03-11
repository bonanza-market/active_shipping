require 'json'

module ActiveShipping
  # USPS carrier using the modern REST API with OAuth2 authentication.
  #
  # Usage:
  #   usps = USPS.new(
  #     client_id: 'your_client_id',
  #     client_secret: 'your_client_secret',
  #     test: true  # optional, uses TEM sandbox
  #   )
  #
  class USPS < Carrier
    EventDetails = Struct.new(:description, :time, :zoneless_time, :location, :event_code)
    ONLY_PREFIX_EVENTS = ['DELIVERED', 'OUT FOR DELIVERY']
    self.retry_safe = true

    cattr_reader :name
    @@name = "USPS"

    LIVE_DOMAIN = 'apis.usps.com'
    TEST_DOMAIN = 'apis-tem.usps.com'

    OAUTH_PATH = '/oauth2/v3/token'
    DOMESTIC_RATES_PATH = '/prices/v3/base-rates/search'
    INTERNATIONAL_RATES_PATH = '/international-prices/v3/base-rates/search'
    TRACKING_PATH = '/tracking/v3/tracking'

    DOMESTIC_MAIL_CLASSES = %w[
      USPS_GROUND_ADVANTAGE
      PRIORITY_MAIL
      PRIORITY_MAIL_EXPRESS
      PARCEL_SELECT
      MEDIA_MAIL
      LIBRARY_MAIL
      BOUND_PRINTED_MATTER
    ]

    INTERNATIONAL_MAIL_CLASSES = %w[
      PRIORITY_MAIL_EXPRESS_INTERNATIONAL
      PRIORITY_MAIL_INTERNATIONAL
      FIRST-CLASS_PACKAGE_INTERNATIONAL_SERVICE
      GLOBAL_EXPRESS_GUARANTEED
    ]

    SERVICE_LABELS = {
      'USPS_GROUND_ADVANTAGE' => 'USPS Ground Advantage',
      'PRIORITY_MAIL' => 'Priority Mail',
      'PRIORITY_MAIL_EXPRESS' => 'Priority Mail Express',
      'PARCEL_SELECT' => 'Parcel Select',
      'MEDIA_MAIL' => 'Media Mail',
      'LIBRARY_MAIL' => 'Library Mail',
      'BOUND_PRINTED_MATTER' => 'Bound Printed Matter',
      'FIRST_CLASS_MAIL' => 'First Class Mail',
      'PRIORITY_MAIL_EXPRESS_INTERNATIONAL' => 'Priority Mail Express International',
      'PRIORITY_MAIL_INTERNATIONAL' => 'Priority Mail International',
      'FIRST-CLASS_PACKAGE_INTERNATIONAL_SERVICE' => 'First-Class Package International Service',
      'GLOBAL_EXPRESS_GUARANTEED' => 'Global Express Guaranteed',
    }

    DEFAULT_RATE_INDICATORS = {
      'USPS_GROUND_ADVANTAGE' => 'DR',
      'PRIORITY_MAIL' => 'DR',
      'PRIORITY_MAIL_EXPRESS' => 'DR',
      'PARCEL_SELECT' => 'DR',
      'MEDIA_MAIL' => 'SP',
      'LIBRARY_MAIL' => 'SP',
      'BOUND_PRINTED_MATTER' => 'SP',
      'FIRST_CLASS_MAIL' => 'SP',
      'PRIORITY_MAIL_EXPRESS_INTERNATIONAL' => 'SP',
      'PRIORITY_MAIL_INTERNATIONAL' => 'SP',
      'FIRST-CLASS_PACKAGE_INTERNATIONAL_SERVICE' => 'SP',
      'GLOBAL_EXPRESS_GUARANTEED' => 'SP',
    }

    CONTAINERS = {
      rectangular: 'RECTANGULAR',
      variable: 'VARIABLE',
      box: 'FLAT RATE BOX',
      box_large: 'LG FLAT RATE BOX',
      box_medium: 'MD FLAT RATE BOX',
      box_small: 'SM FLAT RATE BOX',
      envelope: 'FLAT RATE ENVELOPE',
      envelope_legal: 'LEGAL FLAT RATE ENVELOPE',
      envelope_padded: 'PADDED FLAT RATE ENVELOPE',
      envelope_gift_card: 'GIFT CARD FLAT RATE ENVELOPE',
      envelope_window: 'WINDOW FLAT RATE ENVELOPE',
      envelope_small: 'SM FLAT RATE ENVELOPE',
      package_service: 'PACKAGE SERVICE'
    }

    # Array of U.S. possessions according to USPS
    US_POSSESSIONS = %w(AS FM GU MH MP PW PR VI)

    COUNTRY_NAME_CONVERSIONS = {
      "BA" => "Bosnia-Herzegovina",
      "CD" => "Congo, Democratic Republic of the",
      "CG" => "Congo (Brazzaville),Republic of the",
      "CI" => "Côte d'Ivoire (Ivory Coast)",
      "CK" => "Cook Islands (New Zealand)",
      "FK" => "Falkland Islands",
      "GB" => "Great Britain and Northern Ireland",
      "GE" => "Georgia, Republic of",
      "IR" => "Iran",
      "KN" => "Saint Kitts (St. Christopher and Nevis)",
      "KP" => "North Korea (Korea, Democratic People's Republic of)",
      "KR" => "South Korea (Korea, Republic of)",
      "LA" => "Laos",
      "LY" => "Libya",
      "MC" => "Monaco (France)",
      "MD" => "Moldova",
      "MK" => "Macedonia, Republic of",
      "MM" => "Burma",
      "PN" => "Pitcairn Island",
      "RU" => "Russia",
      "SK" => "Slovak Republic",
      "TK" => "Tokelau (Union) Group (Western Samoa)",
      "TW" => "Taiwan",
      "TZ" => "Tanzania",
      "VA" => "Vatican City",
      "VG" => "British Virgin Islands",
      "VN" => "Vietnam",
      "WF" => "Wallis and Futuna Islands",
      "WS" => "Western Samoa"
    }

    TRACKING_ODD_COUNTRY_NAMES = {
      'TAIWAN' => 'TW',
      'MACEDONIA THE FORMER YUGOSLAV REPUBLIC OF' => 'MK',
      'MICRONESIA FEDERATED STATES OF' => 'FM',
      'MOLDOVA REPUBLIC OF' => 'MD',
    }

    ATTEMPTED_DELIVERY_CODES = %w(02 53 54 55 56 H0)

    def requirements
      [:client_id, :client_secret]
    end

    def find_rates(origin, destination, packages, options = {})
      options = @options.merge(options)
      origin = Location.from(origin)
      destination = Location.from(destination)
      packages = Array(packages)

      domestic_codes = US_POSSESSIONS + ['US', nil]
      if domestic_codes.include?(destination.country_code(:alpha2))
        us_rates(origin, destination, packages, options)
      else
        world_rates(origin, destination, packages, options)
      end
    end

    def find_tracking_info(tracking_number, options = {})
      options = @options.merge(options)
      raw = api_get("#{TRACKING_PATH}/#{URI.encode_www_form_component(tracking_number)}?expand=DETAIL", options)
      parse_tracking_response(JSON.parse(raw), tracking_number, raw)
    end

    def batch_find_tracking_info(tracking_infos, options = {})
      options = @options.merge(options)
      tracking_infos.map do |info|
        number = info[:number]
        begin
          raw = api_get("#{TRACKING_PATH}/#{URI.encode_www_form_component(number)}?expand=DETAIL", options)
          parse_tracking_response(JSON.parse(raw), number, raw)
        rescue ResponseError => e
          e.response
        end
      end
    end

    def self.size_code_for(package)
      package.inches(:max) <= 12 ? 'REGULAR' : 'LARGE'
    end

    def self.package_machinable?(package, options = {})
      at_least_minimum =  package.inches(:length) >= 6.0 &&
                          package.inches(:width) >= 3.0 &&
                          package.inches(:height) >= 0.25 &&
                          package.ounces >= 6.0
      at_most_maximum  =  package.inches(:length) <= 34.0 &&
                          package.inches(:width) <= 17.0 &&
                          package.inches(:height) <= 17.0 &&
                          package.pounds <= (package.options[:books] ? 25.0 : 35.0)
      at_least_minimum && at_most_maximum
    end

    def valid_credentials?
      fetch_token
      true
    rescue
      false
    end

    def maximum_weight
      Measured::Weight.new(70, :pounds)
    end

    def maximum_address_field_length
      38
    end

    protected

    def us_rates(origin, destination, packages, options = {})
      mail_classes = options[:mail_class] ? Array(options[:mail_class]) : DOMESTIC_MAIL_CLASSES
      rate_estimates = []
      errors = []

      mail_classes.each do |mail_class|
        package_rates = []
        all_rated = true

        packages.each do |package|
          begin
            body = build_domestic_rate_body(package, origin, destination, mail_class, options)
            save_request(body.to_json)
            raw = api_post(DOMESTIC_RATES_PATH, body, options)
            data = JSON.parse(raw)

            if data['rates'] && data['rates'].any?
              rate = data['rates'].first
              package_rates << { package: package, rate: (rate['price'].to_f * 100).round }
            else
              all_rated = false
              break
            end
          rescue => e
            errors << e.message
            all_rated = false
            break
          end
        end

        if all_rated && package_rates.any?
          label = SERVICE_LABELS[mail_class] || mail_class
          rate_estimates << RateEstimate.new(origin, destination, @@name, "USPS #{label}",
            package_rates: package_rates,
            service_code: mail_class,
            currency: 'USD')
        end
      end

      rate_estimates.sort_by!(&:total_price)
      success = rate_estimates.any?
      message = success ? '' : (errors.first || 'No rates available')
      RateResponse.new(success, message, {}, rates: rate_estimates, request: last_request)
    end

    def world_rates(origin, destination, packages, options = {})
      mail_classes = options[:mail_class] ? Array(options[:mail_class]) : INTERNATIONAL_MAIL_CLASSES
      rate_estimates = []
      errors = []

      mail_classes.each do |mail_class|
        package_rates = []
        all_rated = true

        packages.each do |package|
          begin
            body = build_international_rate_body(package, origin, destination, mail_class, options)
            save_request(body.to_json)
            raw = api_post(INTERNATIONAL_RATES_PATH, body, options)
            data = JSON.parse(raw)

            if data['rates'] && data['rates'].any?
              rate = data['rates'].first
              package_rates << { package: package, rate: (rate['price'].to_f * 100).round }
            else
              all_rated = false
              break
            end
          rescue => e
            errors << e.message
            all_rated = false
            break
          end
        end

        if all_rated && package_rates.any?
          label = SERVICE_LABELS[mail_class] || mail_class
          rate_estimates << RateEstimate.new(origin, destination, @@name, "USPS #{label}",
            package_rates: package_rates,
            service_code: mail_class,
            currency: 'USD')
        end
      end

      rate_estimates.sort_by!(&:total_price)
      success = rate_estimates.any?
      message = success ? '' : (errors.first || 'No rates available')
      RateResponse.new(success, message, {}, rates: rate_estimates, request: last_request)
    end

    private

    def build_domestic_rate_body(package, origin, destination, mail_class, options)
      machinable = if package.options.has_key?(:machinable)
        package.options[:machinable]
      else
        USPS.package_machinable?(package)
      end

      body = {
        'originZIPCode' => strip_zip(origin.zip),
        'destinationZIPCode' => strip_zip(destination.zip),
        'weight' => package.lbs.to_f.round(2),
        'length' => package.inches(:length).round(2),
        'width' => package.inches(:width).round(2),
        'height' => package.inches(:height).round(2),
        'mailClass' => mail_class,
        'processingCategory' => machinable ? 'MACHINABLE' : 'NON_MACHINABLE',
        'destinationEntryFacilityType' => 'NONE',
        'rateIndicator' => options[:rate_indicator] || DEFAULT_RATE_INDICATORS[mail_class] || 'SP',
        'priceType' => options[:commercial_base] || options[:commercial_plus] ? 'COMMERCIAL' : 'RETAIL',
        'mailingDate' => (options[:mailing_date] || Date.today).strftime('%Y-%m-%d'),
      }
      body['accountType'] = options[:account_type] if options[:account_type]
      body['accountNumber'] = options[:account_number] if options[:account_number]
      body
    end

    def build_international_rate_body(package, origin, destination, mail_class, options)
      country_code = destination.country_code(:alpha2)

      body = {
        'originZIPCode' => strip_zip(origin.zip),
        'destinationCountryCode' => country_code,
        'weight' => package.lbs.to_f.round(2),
        'length' => package.inches(:length).round(2),
        'width' => package.inches(:width).round(2),
        'height' => package.inches(:height).round(2),
        'mailClass' => mail_class,
        'processingCategory' => 'NON_MACHINABLE',
        'destinationEntryFacilityType' => 'NONE',
        'rateIndicator' => options[:rate_indicator] || DEFAULT_RATE_INDICATORS[mail_class] || 'SP',
        'priceType' => options[:commercial_base] || options[:commercial_plus] ? 'COMMERCIAL' : 'RETAIL',
        'mailingDate' => (options[:mailing_date] || Date.today).strftime('%Y-%m-%d'),
      }
      body['foreignPostalCode'] = destination.zip if destination.zip.present?
      body['accountType'] = options[:account_type] if options[:account_type]
      body['accountNumber'] = options[:account_number] if options[:account_number]
      body
    end

    def parse_tracking_response(data, tracking_number, raw_response)
      if data['error'] || data['errors']
        error_msg = data.dig('error', 'message') || data.dig('errors', 0, 'message') || 'Tracking error'
        return TrackingResponse.new(false, error_msg, data,
          carrier: @@name, request: last_request)
      end

      shipment_events = []
      tracking_events = data['trackingEvents'] || []

      tracking_events.each do |event|
        description = (event['eventType'] || '').upcase
        if prefix = ONLY_PREFIX_EVENTS.find { |p| description.start_with?(p) }
          description = prefix
        end

        time = if event['eventTimestamp'].present?
          Time.parse(event['eventTimestamp'])
        else
          Time.at(0)
        end

        event_code = event['eventCode'] || ''
        city = event['eventCity']
        state = event['eventState']
        zip_code = event['eventZIP']
        country_code = event['eventCountry']

        if country_code.blank? || country_code == 'null'
          country_code = 'US'
        else
          country_code = find_country_code_case_insensitive(country_code) rescue country_code
        end

        zoneless_time = Time.utc(time.year, time.month, time.mday, time.hour, time.min, time.sec)
        location = Location.new(city: city, state: state, postal_code: zip_code, country: country_code)

        shipment_events << ShipmentEvent.new(description, zoneless_time, location, description, event_code)
      end

      shipment_events.sort_by!(&:time)

      attempted_delivery_date = shipment_events.detect { |e|
        ATTEMPTED_DELIVERY_CODES.include?(e.type_code)
      }.try(:time)

      status = nil
      actual_delivery_date = nil
      scheduled_delivery = nil

      if data['expectedDeliveryDate'].present?
        scheduled_delivery = Time.parse(data['expectedDeliveryDate']) rescue nil
      end

      if last_event = shipment_events.last
        status = last_event.status
        actual_delivery_date = last_event.time if last_event.delivered?
      end

      destination = if data['destinationCity'] || data['destinationState'] || data['destinationZIP']
        Location.new(
          city: data['destinationCity'],
          state: data['destinationState'],
          postal_code: data['destinationZIP'],
          country: 'US'
        )
      end

      TrackingResponse.new(true, data['statusSummary'] || '', data,
        carrier: @@name,
        xml: raw_response,
        request: last_request,
        shipment_events: shipment_events,
        destination: destination,
        tracking_number: tracking_number,
        status: status,
        actual_delivery_date: actual_delivery_date,
        attempted_delivery_date: attempted_delivery_date,
        scheduled_delivery_date: scheduled_delivery
      )
    end

    def find_country_code_case_insensitive(name)
      upcase_name = name.upcase.gsub('  ', ', ')
      if special = TRACKING_ODD_COUNTRY_NAMES[upcase_name]
        return special
      end
      country = ActiveUtils::Country::COUNTRIES.detect { |c| c[:name].upcase == upcase_name }
      raise ActiveShipping::Error, "No country found for #{name}" unless country
      country[:alpha2]
    end

    # --- OAuth2 token management ---

    def access_token(options = {})
      if @token && @token_expires_at && Time.now < @token_expires_at
        return @token
      end
      fetch_token(options)
    end

    def fetch_token(options = {})
      domain = api_domain(options)
      url = "https://#{domain}#{OAUTH_PATH}"

      token_body = {
        'client_id' => @options[:client_id],
        'client_secret' => @options[:client_secret],
        'grant_type' => 'client_credentials'
      }.to_json

      response = ssl_post(url, token_body, {
        'Content-Type' => 'application/json',
        'Accept' => 'application/json'
      })

      data = JSON.parse(response)
      if data['access_token']
        @token = data['access_token']
        @token_expires_at = Time.now + (data['expires_in'].to_i - 300) # refresh 5 min early
        @token
      else
        raise ActiveShipping::ResponseError.new("OAuth token error: #{data['error'] || response}")
      end
    end

    # --- HTTP helpers ---

    def api_post(path, body, options = {})
      token = access_token(options)
      domain = api_domain(options)
      url = "https://#{domain}#{path}"

      ssl_post(url, body.to_json, {
        'Content-Type' => 'application/json',
        'Accept' => 'application/json',
        'Authorization' => "Bearer #{token}"
      })
    end

    def api_get(path, options = {})
      token = access_token(options)
      domain = api_domain(options)
      url = "https://#{domain}#{path}"

      ssl_get(url, {
        'Accept' => 'application/json',
        'Authorization' => "Bearer #{token}"
      })
    end

    def api_domain(options = {})
      (options[:test] || @test_mode) ? TEST_DOMAIN : LIVE_DOMAIN
    end

    def strip_zip(zip)
      zip.to_s.scan(/\d{5}/).first || zip
    end
  end
end
