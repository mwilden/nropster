def msg string, color_code = "\e[34m"
  reset_color_code = "\e[0m"
  puts color_code + string.to_s + reset_color_code
end

def error_msg string
  msg string, "\e[31m"
end

