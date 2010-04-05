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
    @now_playing_keep = TiVo.new.now_playing(@download_now_playing).select {|show| show.keep? }
    downloadable = @now_playing_keep.select {|show| download? show}
    @to_download, @already_downloaded = downloadable.partition do |show|
      not already_downloaded?(show) or @force_download_existing
    end
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
        exit 1
      ensure
        puts
        puts
      end
    end
  end

  def execute_jobs
    started_at = Time.now
    @jobs = @to_download.map {|show| Job.new(show, :to_download)}
    Thread.new {DownloadWorker.new(@jobs, @work_directory).perform}
    Thread.new {EncodeWorker.new(@jobs, @destination_directory).perform}
    Thread.list.each {|thread| thread.join unless thread == Thread.main}
    @duration = Time.now - started_at
  end

  def show_results
    puts
    msg "Downloaded and Encoded:"
    for job in @jobs do
      msg "#{job} (#{size_s(job.size)})"
      msg "  download: #{duration_s(job.download_duration)} (#{size_s(job.size / job.download_duration)}/sec) " +
              "encode: #{duration_s(job.encode_duration)} (#{size_s(job.size / job.encode_duration)}/sec)"
    end
    msg "Total #{duration_s(@duration)}"
    puts
  end

  def download? show
    return true unless @inclusion_regexp || @exclusion_regexp
    unless @inclusion_regexp.nil?
      show.full_title =~ @inclusion_regexp
    else
      !(show.full_title =~ @exclusion_regexp)
    end
  end
end

class Nropster::Job
  attr_reader :show
  attr_accessor :state, :input_filename, :output_filename, :download_duration, :encode_duration

  def initialize show, state
    @show = show
    @state = state
  end

  def to_s
    @show.full_title
  end

  def size
    @show.size
  end
end

class Nropster::DownloadWorker
  def initialize jobs, output_directory
    @jobs = jobs
    @output_directory = output_directory
  end

  def perform
    while true
      anything_to_be_done = false
      for job in @jobs
        if job.state == :to_download
          anything_to_be_done = true
          download job
        end
      end
      break unless anything_to_be_done
      sleep(5)
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
      job.encode_duration = ended_at - started_at
      msg "    time: #{duration_s(job.encode_duration)} size: #{size_s(job.show.size)} rate: #{size_s(job.show.size / job.encode_duration)}/sec"
    end
  rescue Exception => err
    if err.message =~ /@reason_phrase="Server Busy"/
      msg "  Server busy trying to download #{job}"
    else
      msg "  Error downloading #{job}: #{err.to_s}"
    end
    job.state = :to_download
    File.delete job.output_filename
  end

end

class Nropster::EncodeWorker
  def initialize jobs, output_directory
    @jobs = jobs
    @output_directory = output_directory
  end

  def perform
    while true
      anything_to_be_done = false
      for job in @jobs
        if job.state != :encoded
          anything_to_be_done = true
        end

        if job.state == :downloaded
          encode job
        end
      end
      break unless anything_to_be_done
      sleep(5)
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
    job.download_duration = ended_at - started_at
    msg "    time: #{duration_s(job.download_duration)} size: #{size_s(job.show.size)} rate: #{size_s(job.show.size / job.download_duration)}/sec"
  end

end

def size_s size
  Console::ProgressBar.convert_bytes(size).strip
end

def duration_s duration
  minutes = (duration / 60) % 60
  minutes += 1 if duration % 60 != 0
  hours = duration / 3600
  sprintf("%d:%02d", hours, minutes)
end
