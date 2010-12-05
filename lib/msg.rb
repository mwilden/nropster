def display_msg string, color_code = "\e[34m"
  reset_color_code = "\e[0m"
  puts color_code + string.to_s + reset_color_code
end

def display_error_msg string
  display_msg string, "\e[31m"
end

