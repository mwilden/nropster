class Show
  attr_accessor :state, :input_filename, :output_filename, :encode_duration
  attr_reader :size, :url, :title, :episode_title, :time_captured, :duration, :download_duration

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
    @destination_directory = destination_directory
    @edited_directory = edited_directory
    @work_directory = work_directory
  end

  def download output
    downloader = @tivo.downloader
    downloader.download url, full_title, size, output
    @download_duration = downloader.duration
  end

  def display_statistics(duration_method, rate_method)
    display_msg "    time: #{Formatter.duration(send(duration_method))} " +
            "size: #{Formatter.size(size)} " +
            "rate: #{Formatter.size(send(rate_method))}/sec"
  end

  def display_complete_statistics
    display_msg "#{self} (#{Formatter.size(size)})"
    return if @state == :errored
    display_msg "  download: #{Formatter.duration(download_duration)} (#{Formatter.size(size / download_duration)}/sec) " +
            "encode: #{Formatter.duration(encode_duration)} (#{Formatter.size(size / encode_duration)}/sec)"
  end

  def keep?
    @keep
  end

  def full_title
    return @title if @episode_title.empty?
    @title + '-' + @episode_title
  end

  def downloaded_filename
    filename_root + '.mpg'
  end

  def encoded_filename
    filename_root + '.dv'
  end

  def to_s format = :short
    return "#{time_captured_s} #{duration_s} #{full_title} (#{size_s})" if format == :long
    full_title
  end

  private
  def download_rate
    size / @download_duration
  end

  def encode_rate
    size / @encode_duration
  end

  def time_captured_s
    Formatter.time(@time_captured)
  end

  def duration_s
    Formatter.duration(@duration)
  end

  def size_s
    Formatter.size(size)
  end

  def filename_root
    full_title + ' ' + time_captured_s.gsub(':', '')
  end
end

