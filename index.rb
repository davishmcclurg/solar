require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'

  gem 'base64'
  gem 'date'
  gem 'json'
  gem 'net-http'
  gem 'uri'
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

(year, month), month_production = production.map.with_index do |watt_hours, index|
  [start_date + index, watt_hours]
end.group_by do |date, _watt_hours|
  [date.year, date.month]
end.max_by(&:first)

average_watt_hours = month_production.sum(&:last).to_f / month_production.size
month_days = Date.new(year, month).next_month.prev_day.day
projected_total = average_watt_hours * month_days

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
      <dt>month average</dt>
      <dd>#{(average_watt_hours.to_f / 1_000).round(1)} kwh</dd>
      <dt>month projection</dt>
      <dd>#{(projected_total / 1_000).round} kwh</dd>
    </dl>
  </body>
  </html>
HTML

$stdout.puts("REFRESH_TOKEN=#{refresh_token}")
