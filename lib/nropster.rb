require 'progressbar'
require 'tivo'

class Nropster
  def initialize(options)
    @now_playing_keep = TiVo.new.shows(options[:download_now_playing]).select {|show| show.keep? }
    @destination_directory = options[:destination_directory]
    @work_directory = options[:work_directory]
  end

  def show_now_playing_keep
    @now_playing_keep.each {|show| puts show.to_s }
  end

  def run
    log 'Now Playing (Keep):'
    @now_playing_keep.each {|show| log show.to_s}
    to_download = @now_playing_keep.select {|show| download? show}
    log 'To download:'
    to_download.each {|show| log show.to_s}
    jobs = to_download.map {|show| Job.new(show, :to_download)}
    Thread.new {DownloadWorker.new(jobs, @work_directory).perform}
    Thread.new {EncodeWorker.new(jobs, @destination_directory).perform}
    Thread.list.each {|thread| thread.join unless thread == Thread.main}
  end

  private
  def download? show
    show.full_title =~ /GoodFellas|Sixteen/
#    show.full_title =~ /Kelly Takes|Larry/
  end
end

class Nropster::Job
  attr_reader :show
  attr_accessor :state, :input_filename, :output_filename

  def initialize show, state
    @show = show
    @state = state
  end

  def to_s
    @show.full_title
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
    log "Downloading #{job}"
    IO.popen("tivodecode -o '#{job.output_filename}' -", 'wb') do |tivodecode|
      progress_bar = Console::ProgressBar.new(job.show.full_title, job.show.size)
      job.state = :downloading
      job.show.download do |chunk|
        tivodecode << chunk
        progress_bar.inc(chunk.length)
      end
      job.state = :downloaded
      progress_bar.finish
      log "Finished downloading #{job}"
    end
  rescue Exception => err
    if err.message =~ /@reason_phrase="Server Busy"/
      log "Server busy trying to download #{job}"
    else
      log "Error downloading #{job}: #{err.to_s}"
      log err.backtrace
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
    log "Encoding #{job}"
    job.state = :encoding
    `/Applications/kmttg/ffmpeg/ffmpeg -y -an -i '#{input_filename}' -threads 2 -croptop 4 -target ntsc-dv '#{job.output_filename}'`
    File.delete input_filename
    job.state = :encoded
    log "Finished encoding #{job}"
  end

end
