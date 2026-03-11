require 'test_helper'

class USPSTest < ActiveSupport::TestCase
  include ActiveShipping::Test::Fixtures

  def setup
    @credentials = { client_id: 'test_client_id', client_secret: 'test_client_secret' }
    @carrier = USPS.new(@credentials)
    @token_response = json_fixture('usps/token_response')
    @tracking_response = json_fixture('usps/tracking_response')
    @tracking_response_failure = json_fixture('usps/tracking_response_failure')
    @domestic_rate_priority = json_fixture('usps/domestic_rate_response_priority')
    @domestic_rate_ground = json_fixture('usps/domestic_rate_response_ground')
    @international_rate_response = json_fixture('usps/international_rate_response')
  end

  def test_initialize_options_requirements
    assert_raises(ArgumentError) { USPS.new }
    assert_raises(ArgumentError) { USPS.new(client_id: 'only_id') }
    assert USPS.new(client_id: 'id', client_secret: 'secret')
  end

  def test_valid_credentials
    @carrier.expects(:ssl_post).returns(@token_response)
    assert @carrier.valid_credentials?
  end

  def test_invalid_credentials
    @carrier.expects(:ssl_post).raises(ActiveShipping::ResponseError.new('Unauthorized'))
    refute @carrier.valid_credentials?
  end

  # --- Tracking ---

  def test_find_tracking_info_should_return_a_tracking_response
    stub_token
    @carrier.expects(:ssl_get).returns(@tracking_response)
    response = @carrier.find_tracking_info('9102901000462189604217')
    assert_instance_of ActiveShipping::TrackingResponse, response
  end

  def test_find_tracking_info_should_have_correct_fields
    stub_token
    @carrier.expects(:ssl_get).returns(@tracking_response)
    response = @carrier.find_tracking_info('9102901000462189604217')
    assert_equal 10, response.shipment_events.size
    assert_equal Time.parse('April 28, 2015'), response.scheduled_delivery_date
    assert_equal Time.parse('2015-04-28 09:01:00 UTC'), response.actual_delivery_date
    assert_equal '9102901000462189604217', response.tracking_number
  end

  def test_find_tracking_info_should_return_events_in_ascending_order
    stub_token
    @carrier.expects(:ssl_get).returns(@tracking_response)
    response = @carrier.find_tracking_info('9102901000462189604217')
    assert_equal response.shipment_events.map(&:time).sort, response.shipment_events.map(&:time)
  end

  def test_find_tracking_info_should_have_correct_timestamps
    stub_token
    @carrier.expects(:ssl_get).returns(@tracking_response)
    response = @carrier.find_tracking_info('9102901000462189604217')
    assert_equal [
      "2015-04-23 23:36:00 UTC",
      "2015-04-25 18:04:00 UTC",
      "2015-04-25 19:19:00 UTC",
      "2015-04-26 00:18:00 UTC",
      "2015-04-27 16:04:00 UTC",
      "2015-04-28 04:05:00 UTC",
      "2015-04-28 07:03:00 UTC",
      "2015-04-28 08:19:00 UTC",
      "2015-04-28 08:29:00 UTC",
      "2015-04-28 09:01:00 UTC"], response.shipment_events.map { |e| e.time.strftime('%Y-%m-%d %H:%M:00 %Z') }
  end

  def test_find_tracking_info_should_have_correct_event_names
    stub_token
    @carrier.expects(:ssl_get).returns(@tracking_response)
    response = @carrier.find_tracking_info('9102901000462189604217')
    assert_equal [
      "SHIPPING LABEL CREATED",
      "ACCEPTED AT USPS ORIGIN SORT FACILITY",
      "ARRIVED AT USPS ORIGIN FACILITY",
      "DEPARTED USPS FACILITY",
      "ARRIVED AT USPS FACILITY",
      "DEPARTED USPS FACILITY",
      "ARRIVED AT POST OFFICE",
      "SORTING COMPLETE",
      "OUT FOR DELIVERY",
      "DELIVERED"], response.shipment_events.map(&:name)
  end

  def test_find_tracking_info_should_have_correct_event_codes
    stub_token
    @carrier.expects(:ssl_get).returns(@tracking_response)
    response = @carrier.find_tracking_info('9102901000462189604217')
    assert_equal ["GX", "OA", "10", "EF", "10", "EF", "07", "PC", "OF", "01"], response.shipment_events.map(&:type_code)
  end

  def test_find_tracking_info_should_have_correct_locations
    stub_token
    @carrier.expects(:ssl_get).returns(@tracking_response)
    response = @carrier.find_tracking_info('9102901000462189604217')
    assert_equal [
      "ARGYLE, TX, 76226",
      "ARGYLE, TX, 76226",
      "COPPELL, TX, 75099",
      "COPPELL, TX, 75099",
      "HAZELWOOD, MO, 63042",
      "HAZELWOOD, MO, 63042",
      "HANNA CITY, IL, 61536",
      "HANNA CITY, IL, 61536",
      "HANNA CITY, IL, 61536",
      "HANNA CITY, IL, 61536"], response.shipment_events.map(&:location).map { |l| "#{l.city}, #{l.state}, #{l.postal_code}" }
  end

  def test_find_tracking_info_should_have_correct_status
    stub_token
    @carrier.expects(:ssl_get).returns(@tracking_response)
    response = @carrier.find_tracking_info('9102901000462189604217')
    assert_equal :delivered, response.status
  end

  def test_find_tracking_info_should_be_delivered
    stub_token
    @carrier.expects(:ssl_get).returns(@tracking_response)
    response = @carrier.find_tracking_info('9102901000462189604217')
    assert response.delivered?
  end

  def test_find_tracking_info_should_have_destination
    stub_token
    @carrier.expects(:ssl_get).returns(@tracking_response)
    response = @carrier.find_tracking_info('9102901000462189604217')
    assert_equal 'HANNA CITY', response.destination.city
    assert_equal 'IL', response.destination.state
    assert_equal '61536', response.destination.postal_code
  end

  def test_tracking_failure_should_raise_exception
    stub_token
    @carrier.expects(:ssl_get).returns(@tracking_response_failure)
    e = assert_raises(ResponseError) do
      @carrier.find_tracking_info('abc123xyz')
    end
    assert_match(/could not locate/, e.message)
  end

  def test_batch_find_tracking_info
    stub_token
    tracking_infos = [
      { number: '9102901000462189604217' },
      { number: '5555555555555555555555' }
    ]
    @carrier.expects(:ssl_get).twice.returns(@tracking_response).then.returns(@tracking_response_failure)
    responses = @carrier.batch_find_tracking_info(tracking_infos)
    assert_equal 2, responses.length
    assert responses[0].success?
    # second one should be a failed ResponseError response
    assert responses[1].is_a?(ActiveShipping::TrackingResponse) || responses[1].is_a?(ActiveShipping::Response)
  end

  # --- Rates ---

  def test_domestic_rates
    stub_token
    stub_api_post(@carrier) do |path, body|
      case body['mailClass']
      when 'USPS_GROUND_ADVANTAGE'
        json_fixture('usps/domestic_rate_response_ground')
      when 'PRIORITY_MAIL'
        json_fixture('usps/domestic_rate_response_priority')
      else
        raise StandardError, 'Not eligible'
      end
    end

    response = @carrier.find_rates(
      location_fixtures[:beverly_hills],
      location_fixtures[:new_york],
      package_fixtures[:book]
    )

    assert response.success?
    assert_equal 2, response.rates.length
    assert_equal [450, 695], response.rates.map(&:price)
    assert_equal ['USPS USPS Ground Advantage', 'USPS Priority Mail'], response.rates.map(&:service_name)
  end

  def test_international_rates
    stub_token
    stub_api_post(@carrier) do |path, body|
      if body['mailClass'] == 'PRIORITY_MAIL_INTERNATIONAL'
        json_fixture('usps/international_rate_response')
      else
        raise StandardError, 'Not eligible'
      end
    end

    response = @carrier.find_rates(
      location_fixtures[:beverly_hills],
      location_fixtures[:ottawa],
      package_fixtures[:american_wii]
    )

    assert response.success?
    assert_equal 1, response.rates.length
    assert_equal 3420, response.rates.first.price
    assert_equal 'USPS Priority Mail International', response.rates.first.service_name
  end

  def test_domestic_rates_with_specific_mail_class
    stub_token
    stub_api_post(@carrier) do |path, body|
      json_fixture('usps/domestic_rate_response_priority')
    end

    response = @carrier.find_rates(
      location_fixtures[:beverly_hills],
      location_fixtures[:new_york],
      package_fixtures[:book],
      mail_class: 'PRIORITY_MAIL'
    )

    assert response.success?
    assert_equal 1, response.rates.length
    assert_equal 695, response.rates.first.price
  end

  def test_domestic_rates_commercial_pricing
    request_bodies = []
    carrier_with_commercial = USPS.new(@credentials.merge(commercial_base: true))
    stub_token_on(carrier_with_commercial)
    stub_api_post(carrier_with_commercial, capture: request_bodies) do |path, body|
      json_fixture('usps/domestic_rate_response_priority')
    end

    carrier_with_commercial.find_rates(
      location_fixtures[:beverly_hills],
      location_fixtures[:new_york],
      package_fixtures[:book],
      mail_class: 'PRIORITY_MAIL'
    )

    assert_equal 'COMMERCIAL', request_bodies.first['priceType']
  end

  def test_no_rates_returns_failure
    stub_token
    stub_api_post(@carrier) do |path, body|
      raise StandardError, 'Service not available'
    end

    e = assert_raises(ResponseError) do
      @carrier.find_rates(
        location_fixtures[:beverly_hills],
        location_fixtures[:new_york],
        package_fixtures[:book]
      )
    end
    assert_match(/Service not available/, e.message)
  end

  # --- Request building ---

  def test_domestic_rate_request_body_structure
    body = @carrier.send(:build_domestic_rate_body,
      package_fixtures[:book],
      location_fixtures[:beverly_hills],
      location_fixtures[:new_york],
      'PRIORITY_MAIL',
      {}
    )

    assert_equal '90210', body['originZIPCode']
    assert_equal '10017', body['destinationZIPCode']
    assert_equal 'PRIORITY_MAIL', body['mailClass']
    assert_equal 'RETAIL', body['priceType']
    assert_equal 'NONE', body['destinationEntryFacilityType']
    assert body['weight'].is_a?(Float)
    assert body['length'].is_a?(Float)
    assert body['width'].is_a?(Float)
    assert body['height'].is_a?(Float)
  end

  def test_international_rate_request_body_structure
    body = @carrier.send(:build_international_rate_body,
      package_fixtures[:american_wii],
      location_fixtures[:beverly_hills],
      location_fixtures[:ottawa],
      'PRIORITY_MAIL_INTERNATIONAL',
      {}
    )

    assert_equal '90210', body['originZIPCode']
    assert_equal 'CA', body['destinationCountryCode']
    assert_equal 'PRIORITY_MAIL_INTERNATIONAL', body['mailClass']
    assert_equal 'K1P 1J1', body['foreignPostalCode']
  end

  def test_strip_9_digit_zip_codes
    body = @carrier.send(:build_domestic_rate_body,
      package_fixtures[:book],
      location_fixtures[:beverly_hills_9_zip],
      location_fixtures[:new_york],
      'PRIORITY_MAIL',
      {}
    )
    assert_equal '90210', body['originZIPCode']
  end

  # --- Static methods ---

  def test_size_codes
    assert_equal 'REGULAR', USPS.size_code_for(Package.new(2, [1, 12, 1], :units => :imperial))
    assert_equal 'LARGE', USPS.size_code_for(Package.new(2, [12.1, 1, 1], :units => :imperial))
    assert_equal 'LARGE', USPS.size_code_for(Package.new(2, [1000, 1000, 1000], :units => :imperial))
  end

  def test_maximum_weight
    assert Package.new(70 * 16, [5, 5, 5], :units => :imperial).mass == @carrier.maximum_weight
    assert Package.new((70 * 16) + 0.01, [5, 5, 5], :units => :imperial).mass > @carrier.maximum_weight
    assert Package.new((70 * 16) - 0.01, [5, 5, 5], :units => :imperial).mass < @carrier.maximum_weight
  end

  def test_maximum_address_field_length
    assert_equal 38, @carrier.maximum_address_field_length
  end

  # --- OAuth ---

  def test_token_caching
    @carrier.expects(:ssl_post).once.returns(@token_response)
    @carrier.send(:access_token)
    # Second call should use cached token (no additional ssl_post)
    @carrier.send(:access_token)
  end

  def test_token_refresh_when_expired
    @carrier.instance_variable_set(:@token, 'old_token')
    @carrier.instance_variable_set(:@token_expires_at, Time.now - 100)
    @carrier.expects(:ssl_post).once.returns(@token_response)
    @carrier.send(:access_token)
  end

  def test_uses_test_domain_in_test_mode
    carrier = USPS.new(@credentials.merge(test: true))
    domain = carrier.send(:api_domain)
    assert_equal 'apis-tem.usps.com', domain
  end

  def test_uses_live_domain_in_production_mode
    domain = @carrier.send(:api_domain)
    assert_equal 'apis.usps.com', domain
  end

  private

  def stub_token
    stub_token_on(@carrier)
  end

  def stub_token_on(carrier)
    carrier.instance_variable_set(:@token, 'test_token_12345')
    carrier.instance_variable_set(:@token_expires_at, Time.now + 3600)
  end

  def stub_api_post(carrier, capture: nil, &block)
    test_context = self
    carrier.define_singleton_method(:api_post) do |path, body, opts = {}|
      capture << body if capture
      test_context.instance_exec(path, body, &block)
    end
  end
end
