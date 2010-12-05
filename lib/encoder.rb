require 'fileutils'

class Encoder
  attr_reader :duration

  def encode input, output
    started_at = Time.now
    work = output + '.work'
    File.delete output if File.exists? output
    File.delete work if File.exists? work
    `/Applications/kmttg/ffmpeg/ffmpeg -y -an -i #{quote_for_exec(input)} -threads 2 -croptop 4 -target ntsc-dv #{quote_for_exec(work)}`
    @duration = Time.now - started_at
    FileUtils.move work, output if File.exists? work
    File.exists? output
  end

  private
  def quote_for_exec string
    with_escaped_apostrophes = string.gsub /'/, "'\\\\''"
    "'#{with_escaped_apostrophes}'"
  end
end

