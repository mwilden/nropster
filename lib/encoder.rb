class Encoder
  attr_reader :duration

  def encode input, output
    started_at = Time.now
    `/Applications/kmttg/ffmpeg/ffmpeg -y -an -i #{quote_for_exec(input)} -threads 2 -croptop 4 -target ntsc-dv #{quote_for_exec(output)}`
    @duration = Time.now - started_at
    File.exists? output
  end

  private
  def quote_for_exec string
    with_escaped_apostrophes = string.gsub /'/, "'\\\\''"
    "'#{with_escaped_apostrophes}'"
  end
end

