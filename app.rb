# frozen_string_literal: true

require 'sinatra'
require 'sinatra/contrib'
require 'maxminddb'
require 'useragent'
require 'digest/sha2'
require 'uri'
require_relative 'database'
require_relative 'middlewares/cloudflare_real_ip'

set :public_folder, "#{__dir__}/public"

# use CloudflareRealIP

def authorized?
  @auth ||= Rack::Auth::Basic::Request.new(request.env)
  @auth.provided? && @auth.basic? && @auth.credentials && @auth.credentials == [ENV['APP_USERNAME'], ENV['APP_PASSWORD']]
end

def authorize!
  return if authorized?

  response['WWW-Authenticate'] = %(Basic realm="Restricted Area")
  halt 401, "Not authorized!\n"
end

helpers do
  def deployment_id
    File.read('deployment_id').chomp
  end

  def scheme
    ENV["RACK_ENV"] == 'production' ? 'https' : 'http'
  end
end

get '/' do
  redirect '/admin/websites'
end

get '/admin/websites' do
  authorize!
  db = create_database_connection
  @websites = db.execute('SELECT * FROM websites')
  today = Time.now.getlocal("+07:00").to_date.to_s
  stats = db.execute(<<-SQL, date: today)
    SELECT website_id, COUNT(id) AS visits_count FROM visits
    WHERE date = :date AND website_id IN (#{@websites.map { |w| w["id"] }.join(", ")})
    GROUP BY website_id
  SQL
  @stats = {}
  stats.each { |s| @stats[s["website_id"]] = s["visits_count"] }
  db.close
  @site = { "title" => "Websites" }

  erb :admin_websites, layout: :admin_layout
end

get '/admin/websites/new' do
  authorize!
  @site = { "title" => "Tambah website" }

  erb :admin_website_new, layout: :admin_layout
end

post '/admin/websites' do
  authorize!
  db = create_database_connection

  db.execute('INSERT INTO websites (identifier, name) VALUES (?, ?)', [params['identifier'], params['name']])
  redirect '/admin/websites'
end

get '/admin/websites/:id' do
  authorize!
  @site = { 'title' => 'Stats' }
  params['period'] ||= 'today'
  db = create_database_connection
  @website = db.execute('SELECT * FROM websites WHERE id = ?', params['id']).first
  halt 404, 'Website not found' unless @website

  @ends = Time.now.getlocal("+07:00").to_date
  hash = {
    'today' => @ends,
    'last_seven_days' => @ends - 6,
    'last_fourteen_days' => @ends - 13,
    'last_thirty_days' => @ends - 29
  }
  @starts = hash[params['period']]
  @visits_by_date = db.execute(<<-SQL, website_id: @website['id'], starts: @starts.to_s, ends: @ends.to_s)
    SELECT
      date,
      COUNT(*) AS count
    FROM visits
    WHERE website_id = :website_id AND date BETWEEN :starts AND :ends
    GROUP BY date
    ORDER BY date ASC
  SQL

  if params['period'] == 'today'
    starts = @starts - 3
    visits_by_date = db.execute(<<-SQL, website_id: @website['id'], starts: starts.to_s, ends: @ends.to_s)
      SELECT
        date,
        COUNT(*) AS count
      FROM visits
      WHERE website_id = :website_id AND date BETWEEN :starts AND :ends
      GROUP BY date
      ORDER BY date ASC
    SQL
  else
    starts = @starts
    visits_by_date = @visits_by_date
  end
  labels = (starts..@ends).map { |date| date.strftime("%b %d '%y") }
  data = (starts..@ends).map { |date| visits_by_date.find { |v| v['date'] == date.to_s }&.dig('count') || 0 }
  @chart_data = {
    labels: labels,
    datasets: [
      { label: "Visits", data: data, borderWidth: 1 }
    ]
  }.to_json
  @visits_by_entry = db.execute(<<-SQL, website_id: @website["id"], starts: @starts.to_s, ends: @ends.to_s)
    SELECT
      entry_name AS title,
      entry_path AS slug,
      COUNT(*) AS count
    FROM visits
    WHERE website_id = :website_id AND date BETWEEN :starts AND :ends
    GROUP BY entry_path
    ORDER BY count DESC, title ASC
  SQL
  @total_visits = @visits_by_entry.sum { |visit| visit["count"] }
  @visits_by_referer = db.execute(<<-SQL, website_id: @website["id"], starts: @starts.to_s, ends: @ends.to_s)
    WITH referers AS (
      SELECT visit_hash, referer FROM visits
      WHERE website_id = :website_id AND date BETWEEN :starts AND :ends
    )
    SELECT
      COALESCE(referer, 'Direct') AS title,
      COUNT(visit_hash) AS count
    FROM referers
    GROUP BY referer
    ORDER BY count DESC, title ASC
  SQL
  @visits_by_country = db.execute(<<-SQL, website_id: @website["id"], starts: @starts.to_s, ends: @ends.to_s)
    WITH countries AS (
      SELECT DISTINCT visitor_id, country FROM visits
      WHERE website_id = :website_id AND date BETWEEN :starts AND :ends
    )
    SELECT
      COALESCE(country, 'Unknown') AS title,
      COUNT(visitor_id) AS count
    FROM countries
    GROUP BY country
    ORDER BY count DESC, title ASC
  SQL
  @total_visitors = @visits_by_country.sum { |visit| visit["count"] }
  @visits_by_device = db.execute(<<-SQL, website_id: @website["id"], starts: @starts.to_s, ends: @ends.to_s)
    WITH devices AS (
      SELECT DISTINCT visitor_id, device FROM visits
      WHERE website_id = :website_id AND date BETWEEN :starts AND :ends
    )
    SELECT
      COALESCE(device, 'Unknown') AS title,
      COUNT(visitor_id) AS count
    FROM devices
    GROUP BY device
    ORDER BY count DESC, title ASC
  SQL
  @visits_by_browser = db.execute(<<-SQL, website_id: @website["id"], starts: @starts.to_s, ends: @ends.to_s)
    WITH browsers AS (
      SELECT DISTINCT visitor_id, browser FROM visits
      WHERE website_id = :website_id AND date BETWEEN :starts AND :ends
    )
    SELECT
      COALESCE(browser, 'Unknown') AS title,
      COUNT(visitor_id) AS count
    FROM browsers
    GROUP BY browser
    ORDER BY count DESC, title ASC
  SQL
  db.close

  erb :admin_website_show, layout: :admin_layout
end

get '/admin/websites/:id/edit' do
  authorize!
  params['period'] ||= 'today'
  db = create_database_connection
  @website = db.execute('SELECT * FROM websites WHERE id = ?', params['id']).first
  db.close
  halt 404, 'Website not found' unless @website
  @site = { 'title' => "Edit #{@website['name']}" }

  erb :admin_website_edit, layout: :admin_layout
end

put '/admin/websites/:id' do
  authorize!
  db = create_database_connection
  @website = db.execute('SELECT * FROM websites WHERE id = ?', params['id']).first
  halt 404, 'Website not found' unless @website

  db.execute('UPDATE websites SET name = ?, identifier = ? WHERE id = ?', [params['name'], params['identifier'], params['id']])
  db.close

  redirect '/admin/websites'
end

delete '/admin/websites/:id' do
  authorize!
  db = create_database_connection
  @website = db.execute('SELECT * FROM websites WHERE id = ?', params['id']).first
  halt 404, 'Website not found' unless @website

  db.execute('DELETE FROM visits WHERE website_id = ?', params['id'])
  db.execute('DELETE FROM websites WHERE id = ?', params['id'])
  db.close

  redirect '/admin/websites'
end

get "/hit" do
  response.headers['Access-Control-Allow-Origin'] = ENV['CORS_ALLOW_ORIGIN'] || '*'
  response.headers['Access-Control-Allow-Methods'] = 'GET, OPTIONS'

  content_type :json

  db = create_database_connection
  @website = db.execute('SELECT * FROM websites WHERE identifier = ?', params['website']).first
  halt 404, { success: false }.to_json unless @website

  user_agent = UserAgent.parse(request.user_agent)
  geoip_db = MaxMindDB.new(File.expand_path(File.join('db/GeoLite2-Country.mmdb')))
  date = Time.now.getlocal("+07:00").to_date.to_s
  referer = params['ref']
  referer = nil if referer.to_s.include?(request.base_url) || referer.to_s.empty?
  if referer
    uri = URI.parse(referer)
    port = ":#{uri.port}" if uri.port && ![80, 443].include?(uri.port)
      referer = "#{uri.scheme}://#{uri.host}#{port}/" if port
  end

  client_ip = request.env['HTTP_CF_CONNECTING_IP'] || request.ip
  visitor_id = Digest::SHA256.hexdigest client_ip
  visit_hash = Digest::SHA256.hexdigest [params['path'], date, client_ip].join('-')
  visit_params = {
    'website_id' => @website["id"],
    'entry_name' => params['page'],
    'entry_path' => params['path'],
    'browser' => user_agent.browser,
    'device' => user_agent.platform,
    'country' => geoip_db.lookup(request.ip)&.country&.name,
    'referer' => referer,
    'visit_hash' => visit_hash,
    'date' => date,
    'visitor_id' => visitor_id
  }
  fields = visit_params.keys.join(', ')
  values = visit_params.values.size.times.map { '?' }.join(', ')
  db.execute("INSERT INTO visits (#{fields}) VALUES (#{values}) ON CONFLICT DO NOTHING", visit_params.values)
  db.close

  { success: "true" }.to_json
end

get '/script.js' do
  send_file 'public/js/script.js'
end
