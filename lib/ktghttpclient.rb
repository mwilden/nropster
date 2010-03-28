# There is a bug in the HTTPClient library, as it ships, in keeping
# all of the contents in memory when you pass it a block.  This is the
# library's method with a small change to not keep the contents in
# memory.
#
# All hail the ruby never closed class!
require 'httpclient'

class HTTPClient
  def do_get_block(req, proxy, conn, &block)
    @request_filter.each do |filter|
      filter.filter_request(req)
    end
    if str = @test_loopback_response.shift
      dump_dummy_request_response(req.body.dump, str) if @debug_dev
      conn.push(HTTP::Message.new_response(str))
      return
    end
    content = ''
    res = HTTP::Message.new_response(content)
    @debug_dev << "= Request\n\n" if @debug_dev
    sess = @session_manager.query(req, proxy)
    res.peer_cert = sess.ssl_peer_cert
    @debug_dev << "\n\n= Response\n\n" if @debug_dev
    do_get_header(req, res, sess)
    conn.push(res)
    sess.get_data() do |str|
      # If we pass a block, we want to operate on it now, not keep it in
      # memory. - KTG
      if block
        block.call(str)
      else
        content << str
      end
    end
    @session_manager.keep(sess) unless sess.closed?
    commands = @request_filter.collect { |filter|
      filter.filter_response(req, res)
    }
    if commands.find { |command| command == :retry }
      raise RetryableResponse.new
    end
  end
end
