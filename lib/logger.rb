class Logger
  def initialize filename
    @@file = File.open(filename, 'a')
    at_exit {@@file.close}
  end
  def self.file
    @@file
  end
end

def log data, output_to_stdout_also = true
  data = data.inspect unless data.kind_of? String
  puts data if output_to_stdout_also
  Logger.file.puts(Time.now.strftime('%m-%d-%y %H:%M ') + data)
  Logger.file.flush
end

