class Show
  attr_accessor :state, :specifically_included
  attr_reader :time_captured

  def initialize tivo_show, destination_directory, edited_directory, work_directory
    @tivo = tivo_show.tivo
    @keep = tivo_show.keep
    @title = tivo_show.title
    @size = tivo_show.size
    @episode_title = tivo_show.episode_title
    @url = tivo_show.url
    @time_captured = tivo_show.time_captured
    @duration = tivo_show.duration
    @download_duration = @encode_duration = 0
    @still_watching = tivo_show.still_watching
    make_filepaths destination_directory, edited_directory, work_directory
  end

  def set_initial_state inclusion_regexp, exclusion_regexp, force_download_existing
    if already_downloaded? && !force_download_existing
      @state = :already_downloaded
    else
      @state = test_regexps(inclusion_regexp, exclusion_regexp) || :to_download
      if @state == :included
        @state = :to_download
        @specifically_included = true
      end
      if @state == :to_download
        if download_exists?
          @state = :downloaded
        elsif @still_watching
          @state = :still_watching
        end
      end
    end
  end

  def anything_to_do?
    [:to_download, :downloaded].include? @state
  end

  def ready_to_download?
    @state == :to_download
  end

  def needs_encoding?
    [:to_download, :downloading, :downloaded].include? state
  end

  def ready_to_encode?
    state == :downloaded
  end

  def already_downloaded?
    [@destination_filepath, @edited_filepath].any? {|file| File.exist? file}
  end

  def download_exists?
    File.exist?(@downloaded_filepath) && !File.exist?(@destination_filepath)
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
    @error = 'Server busy'
    @state = :to_download
  rescue TiVo::Error => err
    display_error_msg "  Error downloading #{self}: #{err}"
    @error = err.to_s
    @state = :errored
  end

  def encode
    display_msg "Encoding #{self}"
    @state = :encoding

    encoder = Encoder.new
    unless encoder.encode @downloaded_filepath, @destination_filepath
      display_error_msg "  Error encoding #{self}"
      @state = :errored
      @error = 'Encoding error'
      return
    end
    @encode_duration = encoder.duration

    @state = :done
    display_msg "  Finished encoding #{self}"
    display_statistics @encode_duration, encode_rate
  end

  def display_statistics duration, rate
    display_msg "    time: #{Formatter.duration(duration)} " +
            "size: #{Formatter.size(@size)} " +
            "rate: #{Formatter.size(rate)}/sec"
  end

  def display_complete_statistics
    entry = "#{self} (#{Formatter.size(@size)})"
    if @state == :errored
      entry << ": #{@error}"
      display_error_msg entry
      return
    end
    display_msg entry
    display_msg "  download: #{Formatter.duration(@download_duration)} (#{Formatter.ratio_size(@size,  @download_duration)}/sec) " +
            "encode: #{Formatter.duration(@encode_duration)} (#{Formatter.ratio_size(@size, @encode_duration)}/sec)"
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
  def test_regexps inclusion_regexp, exclusion_regexp
    if inclusion_regexp && full_title =~ inclusion_regexp
      :included
    elsif inclusion_regexp && full_title !=~ inclusion_regexp
      :not_included
    elsif exclusion_regexp && full_title =~ exclusion_regexp
      :excluded
    end
  end

  def make_filepaths destination_directory, edited_directory, work_directory
    @downloaded_filepath = work_directory + '/' + filename_root + '.mpg'
    @edited_filepath = edited_directory + '/' + filename_root + '.dv'
    @destination_filepath = destination_directory + '/' + filename_root + '.dv'
  end

  def download_rate
    return 0 unless @download_duration && @download_duration != 0
    @size / @download_duration
  end

  def encode_rate
    return 0 unless @encode_duration && @encode_duration != 0
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

class Shows < Array
  def initialize shows
    concat shows
  end
  def anything_to_do?
    any? {|show| show.anything_to_do?}
  end
  def still_watching
    select {|show| show.state == :still_watching}
  end
  def excluded
    select {|show| show.state == :excluded}
  end
  def included
    select {|show| show.specifically_included}
  end
  def not_included
    select {|show| show.state == :not_included}
  end
  def to_download
    select {|show| show.ready_to_download?}
  end
  def already_downloaded
    select {|show| show.already_downloaded?}
  end
  def to_encode
    select {|show| show.state == :downloaded}
  end

  def show_progress
    each do |show|
      case show.state
      when :to_download then display_msg "  To download #{show}"
      when :downloading then display_msg "  Downloading #{show}"
      when :downloaded then display_msg "  Downloaded #{show}"
      when :encoding then display_msg "  Encoding #{show}"
      when :errored then display_msg "  Errored #{show}"
      when :done then display_msg "  Finished #{show}"
      end
    end
  end
end

