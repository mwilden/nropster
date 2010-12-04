class Show
  attr_reader :size, :url, :title, :episode_title, :time_captured, :duration, :download_duration

  def initialize tivo_show
    @tivo = tivo_show.tivo
    @keep = tivo_show.keep
    @title = tivo_show.title
    @size = tivo_show.size
    @episode_title = tivo_show.episode_title
    @url = tivo_show.url
    @time_captured = tivo_show.time_captured
    @duration = tivo_show.duration
  end

  def download output
    downloader = @tivo.downloader
    downloader.download url, full_title, size, output
    @download_duration = downloader.duration
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

  def to_s
    "#{time_captured_s} #{duration_s} #{full_title} (#{size_s})"
  end

  private
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

