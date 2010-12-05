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
      confirm
      download
      display_results
    end
  rescue Timeout::Error
    display_error_msg "TiVo web server is down"
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
        if show.already_downloaded?
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
          if already_downloaded = show.already_downloaded?
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
    @tivo.now_playing @download_now_playing
  end

  def anything_to_do?
    @groups[:to_download].any?
  end

  def display_header
    puts
    display_msg 'Recorded    Len  Title (Size)'
    display_msg '----------- ---- --------------------------------------------'
  end

  def display_lists
    display_header
    display_list 'To Download:', :to_download, true
    display_list "Already Downloaded:", :already_downloaded
    display_list "Included:", :included
    display_list "Excluded:", :excluded
    puts
  end

  def display_list header, state, show_if_empty = false
    shows = @groups[state]
    return if shows.empty? unless show_if_empty
    display_msg header
    shows.each {|show| display_msg show.to_s(:long)}
  end

  def confirm
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

  def download
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
      send state == :errored ? :display_error_msg : :display_msg, header + ':'
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
          show.download
          just_downloaded_file = true
        end
      end
      break unless anything_to_be_done
      sleep 1
    end
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
        show.encode if show.state == :downloaded
      end
      break unless anything_to_be_done
      sleep 1
    end
  end
end
