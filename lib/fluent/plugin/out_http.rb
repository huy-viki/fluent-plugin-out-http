require 'json'

class Fluent::HTTPOutput < Fluent::Output
  Fluent::Plugin.register_output('http', self)

  def initialize
    super
    require 'net/http'
    require 'uri'
  end

  # Endpoint URL ex. localhost.local/api/
  config_param :endpoint_url, :string

  # HTTP method
  config_param :http_method, :string, :default => :post
  
  # form | json
  config_param :serializer, :string, :default => :form

  # Simple rate limiting: ignore any records within `rate_limit_msec`
  # since the last one.
  config_param :rate_limit_msec, :integer, :default => 0

  # nil | 'none' | 'basic'
  config_param :authentication, :string, :default => nil 
  config_param :username, :string, :default => ''
  config_param :password, :string, :default => ''

  def configure(conf)
    super

    serializers = [:json, :form]
    @serializer = if serializers.include? @serializer.intern
                    @serializer.intern
                  else
                    :form
                  end

    http_methods = [:get, :put, :post, :delete]
    @http_method = if http_methods.include? @http_method.intern
                    @http_method.intern
                  else
                    :post
                  end

    @auth = case @authentication
            when 'basic' then :basic
            else
              :none
            end
  end

  def start
    super
  end

  def shutdown
    super
  end

  def format_url(tag, time, record)
    @endpoint_url
  end

  def set_body(req, tag, time, record)
    if @serializer == :json
      set_json_body(req, record)
    else
      req.set_form_data(record)
    end
    req
  end

  def set_header(req, tag, time, record)
    req
  end

  def set_json_body(req, data)
    req.body = JSON.dump(data)
    req['Content-Type'] = 'application/json'
  end

  def create_request(tag, time, record)
    url = format_url(tag, time, record)
    uri = URI.parse(url)
    req = Net::HTTP.const_get(@http_method.to_s.capitalize).new(uri.path)
    set_body(req, tag, time, record)
    set_header(req, tag, time, record)
    return req, uri
  end

  def send_request(req, uri)    
    is_rate_limited = (@rate_limit_msec != 0 and not @last_request_time.nil?)
    if is_rate_limited and ((Time.now.to_f - @last_request_time) * 1000.0 < @rate_limit_msec)
      $log.info('Dropped request due to rate limiting')
      return
    end
    
    res = nil
    begin
      if @auth and @auth == :basic
        req.basic_auth(@username, @password)
      end
      @last_request_time = Time.now.to_f
      res = Net::HTTP.new(uri.host, uri.port).start {|http| http.request(req) }
    rescue IOError, EOFError, SystemCallError
      # server didn't respond
      $log.warn "Net::HTTP.#{req.method.capitalize} raises exception: #{$!.class}, '#{$!.message}'"
    end
    unless res and res.is_a?(Net::HTTPSuccess)
      $log.warn "failed to #{req.method} #{uri} (res: #{res.inspect})"
    end
  end

  def handle_record(tag, time, record)
    req, uri = create_request(tag, time, record)
    send_request(req, uri)
  end

  def emit(tag, es, chain)
    es.each do |time, record|
      handle_record(tag, time, record)
    end
    chain.next
  end
end
