require 'rubygems'
require 'nokogiri'
require 'ktghttpclient'
require 'formatter'

class TiVo
  def initialize(work_directory)
    @now_playing_filename = File.join(work_directory, 'now_playing.xml')
  end

  def now_playing(reload = false)
    download_now_playing if reload
    load_now_playing
  end

  def downloader
    TiVo::Show::Downloader.new mak
  end

  def mak
    8185711423
  end

  private
  def download_now_playing
    downloader = Downloader.new 'https://10.0.1.7/TiVoConnect?Command=QueryContainer&Container=/NowPlaying&Recurse=Yes', mak
    downloader.download_to_file @now_playing_filename
  end

  def load_now_playing
    shows = []
    document = Nokogiri::XML(File.read(@now_playing_filename))
    document.css('Item').each do |item|
      item_details = item.css('Details')
      if item_details.css('ContentType').text =~ /raw-tts/
        shows << Show.new(self, item)
      end
    end
    shows
  end
end

class TiVo::Show
  attr_reader :tivo, :keep, :title, :size, :episode_title, :url, :time_captured, :duration

  def initialize tivo, item
    @tivo = tivo
    @keep = item.css('Links CustomIcon Url').text =~ /save-until-i-delete-recording/
    @title = item.css('Details Title').text
    @size = item.css('Details SourceSize').text.to_i
    @episode_title = item.css('Details EpisodeTitle').text
    @url = item.css('Links Content Url').text
    @time_captured = Time.at(item.css('Details CaptureDate').text.to_i(16) + 2)
    @duration = item.css('Details Duration').text.to_i / 1000
  end
end

class TiVo::Downloader
  def initialize(url, mak)
    @url = url
    @client = HTTPClient.new
    @client.ssl_config.verify_mode = OpenSSL::SSL::VERIFY_NONE
    @client.set_auth(@url, 'tivo', mak)
  end

  def download
    # We ignore the first chunk to work around a bug in
    # http client where we see the "Auth required" digest-auth
    # header.
    first_chunk = true
    get_content do |chunk|
      if first_chunk
        first_chunk = false
        next
      end
      yield chunk
    end
  end

  def download_to_file filename
    temp_filename = filename + '.tmp'
    File.open(temp_filename, 'w') {|f| f.write get_content}
    `mv '#{temp_filename}' '#{filename}'`
  end

  private
  def get_content &block
    @client.get_content(@url, &block)
  end

end

class TiVo::Show::Downloader
  attr_reader :duration

  def initialize mak
    @mak = mak
  end

  def download url, title, size, output
    started_at = Time.now
    progress_bar = Console::ProgressBar.new title, size 
    work = output + '.work'
    File.delete output if File.exists? output
    File.delete work if File.exists? work
    IO.popen(%Q[tivodecode -o #{quote_for_exec(work)} -m "#{@mak}" -], 'wb') do |tivodecode|
      TiVo::Downloader.new(url, @mak).download do |chunk|
        tivodecode << chunk
        progress_bar.inc chunk.length
      end
    end
    progress_bar.finish
    @duration = Time.now - started_at
    FileUtils.move work, output if File.exists? work
  rescue Exception => err
    File.delete work if File.exist? work
    if err.message =~ /@reason_phrase="Server Busy"/
      raise TiVo::ServerBusyError
    else
      raise TiVo::Error.new err
    end
  end

  def quote_for_exec str
    with_escaped_apostrophes = str.gsub /'/, "'\\\\''"
    "'#{with_escaped_apostrophes}'"
  end
end

class TiVo::ServerBusyError < StandardError; end

class TiVo::Error < StandardError
  def initialize inner_exception
    @inner_exception = inner_exception
  end
  def to_s
    @inner_exception.to_s
  end
end

