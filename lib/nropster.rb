require 'progressbar'
require 'tivo'
require 'msg'

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
    @tivo = TiVo.new(@work_directory)

    initialize_show_lists

  rescue Timeout::Error
    error_msg "TiVo web server is down"
    exit 1
  end

  def run
    show_lists
    unless anything_to_do?
      puts "Nothing to do"
      puts
    else
      confirm_execution
      execute_jobs
      show_results
    end
  end

  private

  def initialize_show_lists
    @now_playing_keep = get_now_playing.select {|show| show.keep? }.sort {|a,b| a.time_captured <=> b.time_captured}
    group @now_playing_keep
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
          if already_downloaded?(show)
            @groups[:already_downloaded] << show
          else
            @groups[:to_download] << show
          end
        end
      end
    end
  end

  def get_now_playing
    msg "Downloading Now Playing list" if @download_now_playing
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

  def show_header
    puts
    msg 'Recorded    Len  Title (Size)'
    msg '----------- ---- --------------------------------------------'
  end

  def show_lists
    show_header
    msg "To Download:"
    @groups[:to_download].each {|show| msg show.to_s}
    unless @groups[:already_downloaded].empty?
      msg "Already Downloaded:"
      @groups[:already_downloaded].each {|show| msg show.to_s}
    end
    unless @groups[:included].empty?
      msg "Included:"
      @groups[:included].each {|show| msg show.to_s}
    end
    unless @groups[:excluded].empty?
      msg "Excluded:"
      @groups[:excluded].each {|show| msg show.to_s}
    end
    puts
  end

  def confirm_execution
    if @confirm
      printf "Press Enter to download or ^C to cancel: "
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

  def execute_jobs
    started_at = Time.now
    @jobs = @groups[:to_download].map {|show| Job.new(show)}
    download_worker = Thread.new {DownloadWorker.new(@jobs, @work_directory, @tivo.mak).perform}
    encode_worker = Thread.new {EncodeWorker.new(@jobs, @destination_directory).perform}
    [download_worker, encode_worker].each {|thread| thread.join}
    @duration = Time.now - started_at
  end

  def show_results
    puts
    show_results_in_state(:encoded, "Downloaded and Encoded")
    show_results_in_state(:errored, "Errors", true)
    msg "Total #{Formatter.duration(@duration)}"
    puts
  end

  def show_results_in_state state, header, errors = false
    jobs = @jobs.select {|job| job.state == state }
    unless jobs.empty?
      send errors ? :error_msg : :msg, header + ':'
      for job in jobs do
        job.show_complete_statistics
      end
    end
  end

  def download? show
    return true unless @inclusion_regexp || @exclusion_regexp
    if @inclusion_regexp
      show.full_title =~ @inclusion_regexp
    else
      not show.full_title =~ @exclusion_regexp
    end
  end
end

class Nropster::Job
  attr_reader :show
  attr_accessor :state, :input_filename, :output_filename, :download_duration, :encode_duration

  def initialize show
    @show = show
    @state = :to_download
  end

  def to_s
    @show.full_title
  end

  def size
    @show.size
  end

  def show_statistics(duration_method, rate_method)
    msg "    time: #{Formatter.duration(send(duration_method))} " +
            "size: #{Formatter.size(size)} " +
            "rate: #{Formatter.size(send(rate_method))}/sec"
  end

  def show_complete_statistics
    msg "#{to_s} (#{Formatter.size(size)})"
    return if @state == :errored
    msg "  download: #{Formatter.duration(download_duration)} (#{Formatter.size(size / download_duration)}/sec) " +
            "encode: #{Formatter.duration(encode_duration)} (#{Formatter.size(size / encode_duration)}/sec)"
  end

  private
  def download_rate
    @show.size / @download_duration
  end

  def encode_rate
    @show.size / @encode_duration
  end
end

class Nropster::Worker
  def initialize jobs, output_directory
    @jobs = jobs
    @output_directory = output_directory
  end

  def quote_for_exec str
    with_escaped_apostrophes = str.gsub /'/, "'\\\\''"
    "'#{with_escaped_apostrophes}'"
  end
end

class Nropster::DownloadWorker < Nropster::Worker
  def initialize jobs, output_directory, mak
    @mak = mak
    super jobs, output_directory
  end

  def perform
    while true
      anything_to_be_done = false
      just_downloaded_file = false
      for job in @jobs
        if job.state == :to_download
          anything_to_be_done = true
          if just_downloaded_file
            sleep(3)
          end
          download job
          just_downloaded_file = true
        end
      end
      break unless anything_to_be_done
      sleep(1)
    end
  end

  def download job
    job.output_filename = "#{@output_directory}/#{job.show.downloaded_filename}"
    msg "Downloading #{job}"
    IO.popen(%Q[tivodecode -o #{quote_for_exec(job.output_filename)} -m "#{@mak}" -], 'wb') do |tivodecode|
      progress_bar = Console::ProgressBar.new(job.show.full_title, job.show.size)
      job.state = :downloading
      started_at = Time.now
      job.show.download do |chunk|
        tivodecode << chunk
        progress_bar.inc(chunk.length)
      end
      ended_at = Time.now
      job.state = :downloaded
      progress_bar.finish
      msg "  Finished downloading #{job}"
      job.download_duration = ended_at - started_at
      job.show_statistics(:download_duration, :download_rate)
    end
  rescue Exception => err
    if err.message =~ /@reason_phrase="Server Busy"/
      error_msg "  Server busy trying to download #{job}"
      job.state = :to_download
    else
      error_msg "  Error downloading #{job}: #{err.to_s}"
      job.state = :errored
    end
    File.delete job.output_filename
  end

end

class Nropster::EncodeWorker < Nropster::Worker
  def perform
    while true
      anything_to_be_done = false
      for job in @jobs
        if not [:encoded, :errored].include? job.state
          anything_to_be_done = true
        end

        if job.state == :downloaded
          encode job
        end
      end
      break unless anything_to_be_done
      sleep(1)
    end
  end

  def encode job
    input_filename = job.output_filename
    job.output_filename = "#{@output_directory}/#{job.show.encoded_filename}"
    msg "Encoding #{job}"
    job.state = :encoding
    started_at = Time.now
    `/Applications/kmttg/ffmpeg/ffmpeg -y -an -i #{quote_for_exec(input_filename)} -threads 2 -croptop 4 -target ntsc-dv #{quote_for_exec(job.output_filename)}`
    unless File.exists?(job.output_filename)
      error_msg "  Error encoding #{job}"
      job.state = :errored
      return
    end
    ended_at = Time.now
    File.delete input_filename
    job.state = :encoded
    msg "  Finished encoding #{job}"
    job.encode_duration = ended_at - started_at
    job.show_statistics(:encode_duration, :encode_rate)
  end

end
