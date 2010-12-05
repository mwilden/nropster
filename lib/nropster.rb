require 'progressbar'
require 'tivo'
require 'msg'
require 'encoder'
require 'show'

class Nropster
  def initialize(options)
    @confirm = options[:confirm]
    @destination_directory = options[:destination_directory]
    @edited_directory = options[:edited_directory]
    @work_directory = options[:work_directory]
    @inclusion_regexp = Regexp.new(options[:inclusion_regexp], Regexp::IGNORECASE) if options[:inclusion_regexp]
    @exclusion_regexp = Regexp.new(options[:exclusion_regexp], Regexp::IGNORECASE) if options[:exclusion_regexp]
    @download_now_playing = options[:download_now_playing]
    @force_download_existing = options[:force_download_existing]
    @tivo = TiVo.new @work_directory
  end

  def run
    get_shows
    display_lists
    unless anything_to_do?
      puts "Nothing to do"
      puts
    else
      confirm_execution
      download_shows
      display_results
    end
  rescue Timeout::Error
    error_msg "TiVo web server is down"
    exit 1
  end

  private
  def get_shows
    shows = get_now_playing.map do |tivo_show|
      Show.new tivo_show, @destination_directory, @edited_directory, @work_directory
    end.select do |show|
      show.keep?
    end.sort do |a,b|
      a.time_captured <=> b.time_captured
    end
    group shows
  end

  def group shows
    @groups = {}
    @groups[:excluded] = []
    @groups[:included] = []
    @groups[:to_download] = []
    @groups[:already_downloaded] = []
    shows.each do |show|
      if !@inclusion_regexp && !@exclusion_regexp
        if already(downloaded?(show))
          @groups[:already_downloaded] << show
        else
          @groups[:to_download] << show
        end
      else
        potentially_downloadable = nil
        if @inclusion_regexp && show.full_title =~ @inclusion_regexp
          potentially_downloadable = show
          @groups[:included] << show
        elsif @exclusion_regexp && show.full_title =~ @exclusion_regexp
          @groups[:excluded] << show
        else
          potentially_downloadable = show
        end
        if potentially_downloadable
          if already_downloaded = already_downloaded?(show)
            @groups[:already_downloaded] << show
          end
          if !already_downloaded || @force_download_existing
            @groups[:to_download] << show
          end
        end
      end
    end
  end

  def get_now_playing
    display_msg "Downloading Now Playing list" if @download_now_playing
    @tivo.now_playing(@download_now_playing)
  end

  def anything_to_do?
    @groups[:to_download].any?
  end

  def already_downloaded?(show)
    destination_file = "#{@destination_directory}/#{show.encoded_filename}"
    edited_file = "#{@edited_directory}/#{show.encoded_filename}"
    File.exist?(destination_file) || File.exist?(edited_file)
  end

  def display_header
    puts
    display_msg 'Recorded    Len  Title (Size)'
    display_msg '----------- ---- --------------------------------------------'
  end

  def display_lists
    display_header
    display_msg "To Download:"
    @groups[:to_download].each {|show| display_msg show.to_s(:long)}
    unless @groups[:already_downloaded].empty?
      display_msg "Already Downloaded:"
      @groups[:already_downloaded].each {|show| display_msg show.to_s(:long)}
    end
    unless @groups[:included].empty?
      display_msg "Included:"
      @groups[:included].each {|show| display_msg show.to_s(:long)}
    end
    unless @groups[:excluded].empty?
      display_msg "Excluded:"
      @groups[:excluded].each {|show| display_msg show.to_s(:long)}
    end
    puts
  end

  def confirm_execution
    if @confirm
      print "Press Enter to download or ^C to cancel: "
      begin
        $stdin.getc
      rescue Interrupt
        puts
        exit 1
      ensure
        puts
      end
    end
  end

  def download_shows
    started_at = Time.now
    @shows = @groups[:to_download]
    download_worker = Thread.new {DownloadWorker.new(@shows, @work_directory).perform}
    encode_worker = Thread.new {EncodeWorker.new(@shows, @destination_directory).perform}
    [download_worker, encode_worker].each {|thread| thread.join}
    @duration = Time.now - started_at
  end

  def display_results
    puts
    display_results_in_state :encoded, "Downloaded and Encoded"
    display_results_in_state :errored, "Errors"
    display_msg "Total #{Formatter.duration(@duration)}"
    puts
  end

  def display_results_in_state state, header
    shows = @shows.select {|show| show.state == state }
    unless shows.empty?
      send state == :errored ? :error_msg : :display_msg, header + ':'
      for show in shows do
        show.display_complete_statistics
      end
    end
  end

end

class Nropster::Worker
  def initialize shows, output_directory
    @shows = shows
    @output_directory = output_directory
  end
end

class Nropster::DownloadWorker < Nropster::Worker
  def perform
    while true
      anything_to_be_done = false
      just_downloaded_file = false
      for show in @shows
        if show.state == :to_download
          anything_to_be_done = true
          if just_downloaded_file
            sleep 3
          end
          download show
          just_downloaded_file = true
        end
      end
      break unless anything_to_be_done
      sleep 1
    end
  end

  def download show
    show.output_filename = "#{@output_directory}/#{show.downloaded_filename}"
    display_msg "Downloading #{show}"
    show.state = :downloading

    show.download show.output_filename

    display_msg "  Finished downloading #{show}"
    show.state = :downloaded
    show.display_statistics :download_duration, :download_rate
  rescue TiVo::ServerBusyError
    error_msg "  Server busy trying to download #{show}"
    show.state = :to_download
  rescue TiVo::Error => err
    error_msg "  Error downloading #{show}: #{err}"
    show.state = :errored
  end
end

class Nropster::EncodeWorker < Nropster::Worker
  def perform
    while true
      anything_to_be_done = false
      for show in @shows
        if not [:encoded, :errored].include? show.state
          anything_to_be_done = true
        end

        if show.state == :downloaded
          encode show
        end
      end
      break unless anything_to_be_done
      sleep(1)
    end
  end

  def encode show
    input_filename = show.output_filename
    show.output_filename = "#{@output_directory}/#{show.encoded_filename}"
    display_msg "Encoding #{show}"
    show.state = :encoding

    encoder = Encoder.new
    unless encoder.encode input_filename, show.output_filename
      error_msg "  Error encoding #{show}"
      show.state = :errored
      return
    end

    File.delete input_filename
    show.state = :encoded
    display_msg "  Finished encoding #{show}"
    show.encode_duration = encoder.duration
    show.display_statistics :encode_duration, :encode_rate
  end

end
