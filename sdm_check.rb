require 'csv'
require 'parallel'
require 'optparse'
require 'faraday'
require 'faraday_middleware'

class SDMCheck
  # SDM: Shoppers Drug Mart, the "entity" in the medmeapp system
  ENTERPRISE = 'SDM'

  # Not sure what this is, but it's required
  TENANT_ID = 'edfbb1a3-aca2-4ee4-bbbb-9237237736c4'

  # We can't ask for all the appointments at a pharmacy in a 60 day window
  # Instead we have to make several smaller calls using filters
  # DAYS_PER_API_CALL states how many days will be included in each filter period
  DAYS_PER_API_CALL = 10

  # Each appointment type has a code name that's required
  # We also give it a human readable name to make it easier in the CSV
  APPOINTMENT_TYPES = {
    "moderna" => "COVID-19 Vaccine (Moderna Dose 3 or Booster Dose)",
    "pfizer" => "COVID-19 Vaccine (Pfizer Dose 3 or Booster Dose)",
    "screening" => "Asymptomatic COVID-19 Rapid Antigen Screening",
  }

  class Pharmacy < Struct.new(:pharmacy)
    def id; pharmacy["id"]; end
    def name; pharmacy["name"]; end
    def appointment_type_id; pharmacy.dig("appointmentTypes", 0, "id"); end
    def city; pharmacy.dig("pharmacyAddress", "city"); end
    def store_number; pharmacy["storeNo"]; end
  end

  class Appointment < Struct.new(:pharmacy, :appointment_type_name, :appointment)
    COLUMNS = [:name, :city, :appointment_type_name, :time, :website]

    def to_row
      COLUMNS.to_h  { |column| [column, send(column)] }
    end

    def name; pharmacy.name; end
    def city; pharmacy.city; end
    def time; "#{date} #{start_time} - #{end_time}"; end
    def website; "https://shoppersdrugmart.medmeapp.com/#{pharmacy.store_number}/schedule/#{pharmacy.appointment_type_id}"; end

    def date; appointment["startDateTime"][0...10]; end
    def start_time; appointment["startDateTime"][11...16]; end
    def end_time; appointment["endDateTime"][11...16]; end
  end

  def initialize(cities:, days:, types:)
    @cities = cities
    @days = days
    @types = types
  end

  attr_reader :cities
  attr_reader :days
  attr_reader :types

  def report
    appointments = Parallel.map(appointment_types) do |appointment_type_name|
      Parallel.map(get_available_pharmacies(appointment_type_name)) do |pharmacy|
        Parallel.map(filters) do |filter|
          get_available_times(pharmacy, appointment_type_name, filter)
        end
      end
    end.flatten.sort_by(&:time)

    CSV(headers: Appointment::COLUMNS, write_headers: true, force_quotes: true) do |csv|
      appointments.each { |appointment| csv << appointment.to_row }
    end
  end

  def appointment_types
    APPOINTMENT_TYPES.slice(*types).values
  end

  def filters
    (0..days).each_slice(DAYS_PER_API_CALL).map do |first, *rest, last|
      { startDate: Date.today + first, endDate: Date.today + (last || first + 1) }
    end
  end

  def get_available_pharmacies(appointment_type_name)
    query = <<-GRAPHQL
      query publicGetEnterprisePharmacies($appointmentTypeName: String, $enterpriseName: String\u0021, $storeNo: String) {
        publicGetEnterprisePharmacies(appointmentTypeName: $appointmentTypeName, enterpriseName: $enterpriseName, storeNo: $storeNo) {
          id
          name
          storeNo
          pharmacyAddress {
            unit
            streetNumber
            streetName
            city
            province
            country
            postalCode
            longitude
            latitude
          }
          pharmacyContact {
            phone
            email
          }
          appointmentTypes {
            id
            isWaitlisted
          }
        }
      }
    GRAPHQL
    variables = {
      appointmentTypeName: appointment_type_name,
      enterpriseName: ENTERPRISE,
    }
    headers = {}
    $stderr.puts("[DEBUG]: publicGetEnterprisePharmacies(#{variables})") if ENV["DEBUG"]
    gql(query, variables, headers)
      .dig("data", "publicGetEnterprisePharmacies")
      .filter { |pharmacy| cities.include? pharmacy.dig("pharmacyAddress", "city") }
      .filter { |pharmacy| !pharmacy.dig("appointmentTypes", 0, "isWaitlisted") }
      .map { |pharmacy| Pharmacy.new(pharmacy) }
  end

  def get_available_times(pharmacy, appointment_type_name, filter)
    query = <<-GRAPHQL
      query publicGetAvailableTimes($pharmacyId: String, $appointmentTypeId: Int!, $noOfPeople: Int!, $filter: AvailabilityFilter!) {
        publicGetAvailableTimes(pharmacyId: $pharmacyId, appointmentTypeId: $appointmentTypeId, noOfPeople: $noOfPeople, filter: $filter) {
          startDateTime
          endDateTime
        }
      }
    GRAPHQL
    variables = { 
      pharmacyId: pharmacy.id,
      appointmentTypeId: pharmacy.appointment_type_id,
      noOfPeople: 1,
      filter: filter,
    }
    headers = { 'x-pharmacyid': pharmacy.id }
    $stderr.puts("[DEBUG]: publicGetAvailableTimes(#{variables})") if ENV["DEBUG"]
    gql(query, variables, headers)
      .dig("data", "publicGetAvailableTimes")
      .then { |available_times| available_times || [] }
      .map { |appointment| Appointment.new(pharmacy, appointment_type_name, appointment) }
  end
  
  private

  def gql(query, variables = {}, headers = {})
    client.post('/graphql', {query: query, variables: variables}, headers).body
  rescue Faraday::TimeoutError
    {}
  end

  def client
    headers = {
      'authority': 'gql.medscheck.medmeapp.com',
      'sec-ch-ua': '" Not A;Brand";v="99", "Chromium";v="96", "Google Chrome";v="96"',
      'sec-ch-ua-mobile': '?0',
      'authorization': '',
      'content-type': 'application/json',
      'accept': '*/*',
      'user-agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/96.0.4664.110 Safari/537.36',
      'x-tenantid': TENANT_ID,
      'sec-ch-ua-platform': '"macOS"',
      'origin': 'https://shoppersdrugmart.medmeapp.com',
      'referer': 'https://shoppersdrugmart.medmeapp.com/',
      'sec-fetch-site': 'same-site',
      'sec-fetch-mode': 'cors',
      'sec-fetch-dest': 'empty',
      'accept-language': 'en-US,en;q=0.9',
    }
    @client ||= Faraday.new 'https://gql.medscheck.medmeapp.com', headers: headers do |conn|
      conn.options.timeout = 10
      conn.request :json
      conn.response :json, content_type: /\bjson$/
      conn.adapter Faraday.default_adapter
    end
  end
end

# Only run report if run as script (allows require_relative without side-effects)
if __FILE__ == $0
  options = {
    # Which cities to include in the search
    cities: ["Toronto", "Mississauga", "Scarborough", "Etobicoke", "Markham", "Richmond Hill", "Thornhill"],
    # How many days (from today) to include in the search
    days: 60,
    # Which appointment types to include in the search
    types: ["moderna", "pfizer"],
  }
  OptionParser.new do |opts|
    opts.banner = "Usage: sdm_check.rb [options]"
    opts.on("--cities x,y,z", Array, "List of cities to include in search") { |cities| options[:cities] = cities }
    opts.on("--days 60", Numeric, "Number of days (from today) to include in search") { |days| options[:days] = days }
    opts.on("--types pfizer,moderna,screening", Array, "List of appointment types") { |types| options[:types] = types }
  end.parse!

  SDMCheck.new(**options).report
end
