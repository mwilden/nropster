require 'rubygems'
require 'nokogiri'
require 'ktghttpclient'

class TiVo
  def initialize(work_directory)
    @now_playing_filename = File.join(work_directory, 'now_playing.xml')
  end

  def now_playing(reload = false)
    download_now_playing if reload
    load_now_playing
  end

  def download_show show, &block
    Downloader.new(show.url).download &block
  end

  private
  def download_now_playing
    downloader = Downloader.new('https://10.0.1.7/TiVoConnect?Command=QueryContainer&Container=/NowPlaying&Recurse=Yes')
    downloader.download_to_file(@now_playing_filename)
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
  attr_reader :size, :url, :title, :episode_title, :time_captured, :duration

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

  def keep?
    @keep
  end

  def full_title
    return @title if @episode_title.empty?
    @title + '-' + @episode_title
  end

  def time_captured_s
    @time_captured.strftime('%m-%d-%H:%M')
  end

  def duration_s
    minutes = (@duration.to_f / 60).ceil
    hours = minutes / 60
    minutes = minutes % 60
    sprintf("%d:%02d", hours, minutes)
  end

  def download &block
    @tivo.download_show self, &block
  end

  def downloaded_filename
    filename_root + '.mpg'
  end

  def encoded_filename
    filename_root + '.dv'
  end

  def to_s
    "#{time_captured_s} #{duration_s} #{full_title} (#{size_s})"
  end

  def size_s
    Console::ProgressBar.convert_bytes(size).strip
  end

  private
  def filename_root
    full_title + ' ' + time_captured_s.gsub(':', '')
  end
end

class TiVo::Downloader
  def initialize(url)
    @url = url
    @client = HTTPClient.new
    @client.ssl_config.verify_mode = OpenSSL::SSL::VERIFY_NONE
    @client.set_auth(@url, 'tivo', 8185711423)
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
