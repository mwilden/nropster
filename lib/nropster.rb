require 'progressbar'
require 'tivo'
require 'msg'

class Nropster
  def initialize(options)
    @confirm = options[:confirm]
    @destination_directory = options[:destination_directory]
    @edited_directory = options[:edited_directory]
    @work_directory = options[:work_directory]
    @inclusion_regexp = Regexp.new(options[:inclusion_regexp]) if options[:inclusion_regexp]
    @exclusion_regexp = Regexp.new(options[:exclusion_regexp]) if options[:exclusion_regexp]
    @download_now_playing = options[:download_now_playing]
    @force_download_existing = options[:force_download_existing]
    @tivo = TiVo.new(@work_directory)

    initialize_show_lists

  rescue Timeout::Error
    msg "TiVo web server is down"
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
    @now_playing_keep = get_now_playing.select {|show| show.keep? }
    downloadable = @now_playing_keep.select {|show| download? show}
    @to_download, @already_downloaded = downloadable.partition do |show|
      not already_downloaded?(show) or @force_download_existing
    end
  end

  def get_now_playing
    msg "Downloading Now Playing list" if @download_now_playing
    @tivo.now_playing(@download_now_playing)
  end

  def anything_to_do?
    @to_download.any?
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
    @to_download.each {|show| msg show.to_s}
    unless @already_downloaded.empty?
      msg "Already Downloaded:"
      @already_downloaded.each {|show| msg show.to_s}
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
    @jobs = @to_download.map {|show| Job.new(show)}
    download_worker = Thread.new {DownloadWorker.new(@jobs, @work_directory).perform}
    encode_worker = Thread.new {EncodeWorker.new(@jobs, @destination_directory).perform}
    [download_worker, encode_worker].each {|thread| thread.join}
    @duration = Time.now - started_at
  end

  def show_results
    puts
    show_results_in_state(:encoded, "Downloaded and Encoded")
    show_results_in_state(:errored, "Errors")
    msg "Total #{Formatter.duration(@duration)}"
    puts
  end

  def show_results_in_state(state, header)
    jobs = @jobs.select {|job| job.state == state }
    unless jobs.empty?
      msg header + ':'
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
end

class Nropster::DownloadWorker < Nropster::Worker
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
    IO.popen(%Q[tivodecode -o "#{job.output_filename}" -], 'wb') do |tivodecode|
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
      msg "  Server busy trying to download #{job}"
      job.state = :to_download
    else
      msg "  Error downloading #{job}: #{err.to_s}"
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
    `/Applications/kmttg/ffmpeg/ffmpeg -y -an -i "#{input_filename}" -threads 2 -croptop 4 -target ntsc-dv "#{job.output_filename}"`
    ended_at = Time.now
    File.delete input_filename
    job.state = :encoded
    msg "  Finished encoding #{job}"
    job.encode_duration = ended_at - started_at
    job.show_statistics(:encode_duration, :encode_rate)
  end

end
