class Logger
  def initialize filename
    @@file = File.open(filename, 'a')
    at_exit {@@file.close}
  end
  def self.file
    @@file
  end
end

def log string, output_to_stdout_also = true
  puts string if output_to_stdout_also
  Logger.file.puts Time.now.strftime('%m-%d-%y %H:%M ') + string
  Logger.file.flush
end

