class Logger
  def initialize filename
    @@log_file = File.open(filename, 'a')
    at_exit {@@log_file.close}
  end
  def self.log_file
    @@log_file
  end
end

def log string, output_to_stdout_also = true
  puts string if output_to_stdout_also
  file.puts Time.now.strftime('%m-%d-%y %H:%M ') + string
  file.flush
end

