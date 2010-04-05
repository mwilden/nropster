require 'progressbar'

module Formatter
  def self.time(value)
    value.strftime('%m-%d-%H:%M')
  end

  def self.duration(value)
    minutes = (value.to_f / 60).ceil
    hours = minutes / 60
    minutes = minutes % 60
    sprintf("%d:%02d", hours, minutes)
  end

  def self.size(value)
    Console::ProgressBar.convert_bytes(value).strip
  end
end
