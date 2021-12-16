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

  # Each appointment type has a code name that's required
  # We also give it a human readable name to make it easier in the CSV
  APPOINTMENT_TYPES = {
    moderna: "COVID-19 Vaccine (Moderna Dose 3 or Booster Dose)",
    pfizer: "COVID-19 Vaccine (Pfizer Dose 3 or Booster Dose)",
  }

  # Filter down the dates per query to avoid overwhelming their system
  NUM_FILTERS = 5
  FILTER_DAYS = 10

  class Pharmacy < Struct.new(:pharmacy)
    def id; pharmacy["id"]; end
    def name; pharmacy["name"]; end
    def appointment_type_id; pharmacy.dig("appointmentTypes", 0, "id"); end
    def city; pharmacy.dig("pharmacyAddress", "city"); end
    def store_number; pharmacy["storeNo"]; end
  end

  class Appointment < Struct.new(:pharmacy, :vaccine, :appointment)
    COLUMNS = [:name, :city, :vaccine, :time, :website]

    def to_row
      COLUMNS.to_h  { |column| [column, send(column)] }
    end

    def name; pharmacy.name; end
    def city; pharmacy.city; end
    def time; "#{date} #{start_time} - #{end_time}"; end
    def website; "https://www1.shoppersdrugmart.ca/en/store-locator/store/#{pharmacy.store_number}"; end

    def date; appointment["startDateTime"][0...10]; end
    def start_time; appointment["startDateTime"][11...16]; end
    def end_time; appointment["endDateTime"][11...16]; end
  end

  def initialize(cities:)
    @cities = cities
  end

  attr_reader :cities

  def report
    CSV(headers: Appointment::COLUMNS, write_headers: true, force_quotes: true) do |csv|
      Parallel.each(APPOINTMENT_TYPES) do |vaccine_name, appointment_type_name|
        Parallel.each(get_available_pharmacies(appointment_type_name)) do |pharmacy|
          Parallel.each(filters) do |filter|
            get_available_times(pharmacy, vaccine_name, filter).each { |appointment| csv << appointment.to_row }
          end
        end
      end
    end
  end

  def filters
    (0..NUM_FILTERS).map do |i|
      today = Date.today
      start_date = today + (i * FILTER_DAYS)
      end_date = start_date + FILTER_DAYS
      { startDate: start_date, endDate: end_date }
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
    gql(query, variables, headers)
      .dig("data", "publicGetEnterprisePharmacies")
      .filter { |pharmacy| cities.include? pharmacy.dig("pharmacyAddress", "city") }
      .filter { |pharmacy| !pharmacy.dig("appointmentTypes", 0, "isWaitlisted") }
      .map { |pharmacy| Pharmacy.new(pharmacy) }
  end

  def get_available_times(pharmacy, vaccine_name, filter)
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
    gql(query, variables, headers)
      .dig("data", "publicGetAvailableTimes")
      .then { |available_times| available_times || [] }
      .map { |appointment| Appointment.new(pharmacy, vaccine_name, appointment) }
  end
  
  private

  def gql(query, variables = {}, headers = {})
    client.post('/graphql', {query: query, variables: variables}, headers).body
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
      conn.request :json
      conn.response :json, content_type: /\bjson$/
      conn.adapter Faraday.default_adapter
    end
  end
end

options = {
  cities: ["Toronto", "Mississauga", "Scarborough", "Etobicoke", "Markham", "Richmond Hill", "Thornhill"],
}
OptionParser.new do |opts|
  opts.banner = "Usage: sdm_check.rb [options]"
  opts.on("--cities x,y,z", Array, "List of cities to include in search") { |cities| options[:cities] = cities }
end.parse!

SDMCheck.new(**options).report
