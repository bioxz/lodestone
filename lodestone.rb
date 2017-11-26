require 'sinatra'
require 'sinatra/json'
require 'sinatra/custom_logger'
require 'logger'

require 'open-uri'
require 'ostruct'
require 'time'
require 'thwait'
require 'yaml'

configure do
  file = File.new("#{settings.root}/log/#{settings.environment}.log", 'a')
  file.sync = true
  logger = Logger.new(file)
  set :logger, logger
  use Rack::CommonLogger, logger

  # Cache static assets for one week
  set :static_cache_control, [:public, max_age: 604_800]

  load 'lib/news_cache.rb'
  load 'lib/news.rb'
  load 'lib/scheduler.rb'
  load 'lib/webhooks.rb'

  Redis.current = Redis::Namespace.new(:lodestone)
  Scheduler.run(logger)
end

get '/' do
  @categories = { topics: '1', notices: '0', maintenance: '1', updates: '1', status: '0' }
  @code = params['code']
  erb :index
end

post '/' do
  @categories = News.categories.to_h.keys.each_with_object({}) do |category, h|
    h[category.to_s] = params.dig('categories', category) || '0'
  end

  begin
    url = Webhooks.url(params['code'])
    News.subscribe(@categories.merge('url' => url))
    @flash = { success: 'You are now subscribed to Lodestone updates.' }
  rescue Exception => e
    logger.error "Failed to subscribe - #{e.message}"
    logger.error e.backtrace.join("\n") unless settings.production?
    @flash = { danger: 'Sorry, something went wrong. Please try again.' }
  end

  erb :index
end

get '/news/subscribe' do
  cache_control :no_cache

  begin
    json News.subscribe(params)
  rescue ArgumentError
    halt 400, json(error: 'Invalid webhook URL.')
  end
end

get '/news/:category' do
  category = params[:category].downcase

  begin
    news = News.fetch(category)
    headers = NewsCache.headers(category)
    last_modified headers[:last_modified]
    expires headers[:expires], :must_revalidate
    json news
  rescue ArgumentError
    halt 400, json(error: 'Invalid news category.')
  end
end

not_found do
  erb 'errors/not_found'.to_sym
end

error do
  erb 'errors/error'.to_sym
end
