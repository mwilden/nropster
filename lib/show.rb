class Show
  attr_accessor :state
  attr_reader :time_captured

  def initialize tivo_show, destination_directory, edited_directory, work_directory
    @state = :to_download
    @tivo = tivo_show.tivo
    @keep = tivo_show.keep
    @title = tivo_show.title
    @size = tivo_show.size
    @episode_title = tivo_show.episode_title
    @url = tivo_show.url
    @time_captured = tivo_show.time_captured
    @duration = tivo_show.duration
    make_filepaths destination_directory, edited_directory, work_directory
  end

  def already_downloaded?
    [@destination_filepath, @edited_filepath].any? {|file| File.exist? file}
  end

  def download
    display_msg "Downloading #{self}"
    @state = :downloading

    downloader = @tivo.downloader
    downloader.download @url, full_title, @size, @downloaded_filepath
    @download_duration = downloader.duration

    @state = :downloaded
    display_msg "  Finished downloading #{self}"
    display_statistics @download_duration, download_rate

  rescue TiVo::ServerBusyError
    display_error_msg "  Server busy trying to download #{self}"
    @state = :to_download
  rescue TiVo::Error => err
    display_error_msg "  Error downloading #{self}: #{err}"
    @state = :errored
  end

  def encode
    display_msg "Encoding #{self}"
    @state = :encoding

    encoder = Encoder.new
    unless encoder.encode @downloaded_filepath, @destination_filepath
      display_error_msg "  Error encoding #{self}"
      @state = :errored
      return
    end
    @encode_duration = encoder.duration

    File.delete @downloaded_filepath
    @state = :encoded
    display_msg "  Finished encoding #{self}"
    display_statistics @encode_duration, encode_rate
  end

  def display_statistics duration, rate
    display_msg "    time: #{Formatter.duration(duration)} " +
            "size: #{Formatter.size(@size)} " +
            "rate: #{Formatter.size(rate)}/sec"
  end

  def display_complete_statistics
    display_msg "#{self} (#{Formatter.size(@size)})"
    return if @state == :errored
    display_msg "  download: #{Formatter.duration(@download_duration)} (#{Formatter.size(@size / @download_duration)}/sec) " +
            "encode: #{Formatter.duration(@encode_duration)} (#{Formatter.size(@size / @encode_duration)}/sec)"
  end

  def keep?
    @keep
  end

  def full_title
    return @title if @episode_title.empty?
    @title + '-' + @episode_title
  end

  def to_s format = :short
    return "#{time_captured_s} #{duration_s} #{full_title} (#{size_s})" if format == :long
    full_title
  end

  private
  def make_filepaths destination_directory, edited_directory, work_directory
    @downloaded_filepath = work_directory + '/' + filename_root + '.mpg'
    @edited_filepath = edited_directory + '/' + filename_root + '.dv'
    @destination_filepath = destination_directory + '/' + filename_root + '.dv'
  end

  def download_rate
    @size / @download_duration
  end

  def encode_rate
    @size / @encode_duration
  end

  def time_captured_s
    Formatter.time @time_captured
  end

  def duration_s
    Formatter.duration @duration
  end

  def size_s
    Formatter.size @size
  end

  def filename_root
    full_title + ' ' + time_captured_s.gsub(':', '')
  end
end

