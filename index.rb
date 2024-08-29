require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'

  gem 'base64'
  gem 'date'
  gem 'json'
  gem 'net-http'
  gem 'uri', '0.13.0'
  gem 'webrick'
end

key, client_id, client_secret, refresh_token, system_id = ENV.values_at('KEY', 'CLIENT_ID', 'CLIENT_SECRET', 'REFRESH_TOKEN', 'SYSTEM_ID')

api_uri = URI('https://api.enphaseenergy.com')

token_uri = api_uri.dup
token_uri.path = '/oauth/token'
token_uri.query = if refresh_token
  URI.encode_www_form(grant_type: 'refresh_token', refresh_token:)
else
  redirect_uri = 'http://fbi.com'

  authorization_uri = api_uri.dup
  authorization_uri.path = '/oauth/authorize'
  authorization_uri.query = URI.encode_www_form(response_type: 'code', redirect_uri:, client_id:)

  system("open '#{authorization_uri}'")

  code = nil
  server = WEBrick::HTTPServer.new
  server.mount_proc('/') do |request, response|
    code = request.query.fetch('code')
    response.body = 'ok'
    server.shutdown
  end
  server.start

  URI.encode_www_form(grant_type: 'authorization_code', redirect_uri:, code:)
end

response = Net::HTTP.post(token_uri, nil, { authorization: "Basic #{Base64.strict_encode64("#{client_id}:#{client_secret}")}" })
access_token, refresh_token = JSON.parse(response.body).fetch_values('access_token', 'refresh_token')

headers = { authorization: "Bearer #{access_token}" }

summary_uri = api_uri.dup
summary_uri.path = "/api/v4/systems/#{URI.encode_uri_component(system_id)}/summary"
summary_uri.query = URI.encode_www_form(key:)

response = Net::HTTP.get(summary_uri, headers)
energy_today = JSON.parse(response).fetch('energy_today')

energy_lifetime_uri = api_uri.dup
energy_lifetime_uri.path = "/api/v4/systems/#{URI.encode_uri_component(system_id)}/energy_lifetime"
energy_lifetime_uri.query = URI.encode_www_form(key:)

response = Net::HTTP.get(energy_lifetime_uri, headers)
start_date, production = JSON.parse(response).fetch_values('start_date', 'production')

start_date = Date.parse(start_date)
production << energy_today

year, year_production = production.each_with_index.with_object({}) do |(watt_hours, index), out|
  date = start_date + index
  out[date.year] ||= {}
  out[date.year][date.month] ||= []
  out[date.year][date.month] << watt_hours
end.max_by(&:first)

month, month_production = year_production.max_by(&:first)

month_date = Date.new(year, month)
pvwatts = [451, 607, 928, 1_195, 1_352, 1_373, 1_330, 1_155, 979, 753, 488, 408]

month_total = month_production.sum
month_average_watt_hours = month_total.to_f / month_production.size
month_days = month_date.next_month.prev_day.day
projected_month_total = month_average_watt_hours * month_days
pvwatts_month_projection = pvwatts[month - 1]
pvwatts_month_average = pvwatts_month_projection.to_f / month_days

year_total = year_production.each_value.sum(&:sum)
year_average_watt_hours = year_total.to_f / year_production.each_value.sum(&:size)
year_days = month_date.leap? ? 366 : 365
projected_year_total = year_average_watt_hours * year_days
pvwatts_year_projection = pvwatts.sum
pvwatts_year_average = pvwatts_year_projection.to_f / year_days

File.write('index.html', <<~HTML)
  <!doctype html>
  <html>
  <head>
    <title>solar</title>
  </head>
  <body>
    <h1>solar</h1>
    <dl>
      <dt>today</dt>
      <dd>#{(energy_today.to_f / 1_000).round(1)} kwh</dd>

      <dt>month</dt>
      <dd>#{month_total / 1_000} kwh</dd>
      <dt>month average</dt>
      <dd>#{(month_average_watt_hours.to_f / 1_000).round(1)} kwh</dd>
      <dt>month projection</dt>
      <dd>#{(projected_month_total / 1_000).round} kwh</dd>
      <dt>pvwatts month average</dt>
      <dd>#{pvwatts_month_average.round(1)} kwh</dd>
      <dt>pvwatts month projection</dt>
      <dd>#{pvwatts_month_projection} kwh</dd>

      <dt>year</dt>
      <dd>#{year_total / 1_000} kwh</dd>
      <dt>year average</dt>
      <dd>#{(year_average_watt_hours.to_f / 1_000).round(1)} kwh</dd>
      <dt>year projection</dt>
      <dd>#{(projected_year_total / 1_000).round} kwh</dd>
      <dt>pvwatts year average</dt>
      <dd>#{pvwatts_year_average.round(1)} kwh</dd>
      <dt>pvwatts year projection</dt>
      <dd>#{pvwatts_year_projection} kwh</dd>
    </dl>
  </body>
  </html>
HTML

$stdout.puts("REFRESH_TOKEN=#{refresh_token}")
