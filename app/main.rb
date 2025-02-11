#!/usr/bin/env ruby

require 'dotenv/load'
require 'selenium-webdriver'
require 'csv'
require 'net/smtp'
require 'time'

# ----------------------------------------------
# Set up Selenium driver (headless Chrome)
# ----------------------------------------------
def setup_driver
  options = Selenium::WebDriver::Chrome::Options.new
  options.add_argument('--headless')
  options.add_argument('--disable-gpu')
  options.add_argument('--no-sandbox')
  options.add_argument('--disable-dev-shm-usage')
  options.binary = '/usr/bin/chromium-browser'
  Selenium::WebDriver.for :chrome, options: options
end

# ----------------------------------------------
# Scroll the page until no new content
# ----------------------------------------------
def scroll_page(driver)
  puts "[DEBUG] Starting scroll_page..."
  sleep 2
  last_height = driver.execute_script("return document.body.scrollHeight")
  loop do
    driver.execute_script("window.scrollTo(0, document.body.scrollHeight);")
    sleep 2
    new_height = driver.execute_script("return document.body.scrollHeight")
    break if new_height == last_height
    last_height = new_height
  end
  puts "[DEBUG] Finished scroll_page."
end

# ----------------------------------------------
# Scrape items from the site’s “live” page
# ----------------------------------------------
def scrape_creators(driver)
  live_page_url = ENV.fetch('MYSITE_LIVE_URL')
  puts "[DEBUG] Navigating to #{live_page_url}..."
  driver.navigate.to(live_page_url)
  scroll_page(driver)

  cards = driver.find_elements(:css, 'app-creator-card')
  puts "[DEBUG] Found #{cards.size} <app-creator-card> elements."

  records = []
  cards.first(50).each_with_index do |card, idx|
    display_name = begin
      card.find_element(:css, '.front .name.user-display-name a').text.strip
    rescue
      "Unknown"
    end

    watch_url = begin
      card.find_element(:css, 'a.creator-card-curtain').attribute('href').strip
    rescue
      nil
    end

    puts "[DEBUG] Card #{idx+1}: name=#{display_name.inspect}, url=#{watch_url.inspect}"

    if watch_url && watch_url.include?('/watch/')
      records << { name: display_name, url: watch_url }
    end
  end

  unique = records.uniq { |r| r[:url] }
  puts "[DEBUG] Found #{unique.size} unique records after dedup (from first 50)."
  unique
end

# ----------------------------------------------
# Scrape chat members from a /watch page (with retry logic)
# ----------------------------------------------
def scrape_chat_members(driver, url, creator_name, max_attempts = 3)
  attempts = 0
  partial_members = []

  while attempts < max_attempts
    puts "[DEBUG] Attempt #{attempts+1} to find chat members at #{url}"
    driver.navigate.to(url)
    sleep 5
    member_cards = driver.find_elements(:css, 'app-room-member')
    puts "[DEBUG] Found #{member_cards.size} <app-room-member> elements."

    if member_cards.size > 0
      partial_members = member_cards.map.with_index do |mcard, i|
        begin
          name_elem = mcard.find_element(:css, '.user-display-name__elm')
          t1 = name_elem.text.strip
          t2 = name_elem.attribute("innerText")&.strip
          t3 = driver.execute_script("return arguments[0].textContent", name_elem)&.strip
          [t1, t2, t3].find { |x| x && !x.empty? } || ""
        rescue => e
          puts "  [DEBUG] Could not find .user-display-name__elm in member[#{i}]: #{e.message}"
          ""
        end
      end

      partial_members.reject! { |name| name.empty? || name == creator_name }
      partial_members.uniq!
      puts "[DEBUG] Final chat members => #{partial_members.inspect}"

      break
    else
      puts "[DEBUG] No members found. Retrying..."
      sleep 3
    end

    attempts += 1
  end

  partial_members
end

# ----------------------------------------------
# Generic method to send emails
# ----------------------------------------------
def send_email(subject, body, recipients)
  from      = ENV.fetch('GMAIL_FROM')
  user_name = ENV.fetch('GMAIL_USERNAME')
  password  = ENV.fetch('GMAIL_PASSWORD')
  domain    = ENV.fetch('GMAIL_DOMAIN', 'gmail.com')
  smtp_host = ENV.fetch('GMAIL_SMTP_SERVER', 'smtp.gmail.com')
  smtp_port = ENV.fetch('GMAIL_SMTP_PORT', '587').to_i

  timestamp = Time.now.strftime("%Y-%m-%d %H:%M:%S")
  full_body = "#{body}\nTimestamp: #{timestamp}"

  message = <<~MESSAGE_END
    From: #{from}
    To: #{recipients.join(", ")}
    Subject: #{subject}

    #{full_body}
  MESSAGE_END

  Net::SMTP.start(smtp_host, smtp_port, domain, user_name, password, :login) do |smtp|
    recipients.each do |recipient|
      smtp.send_message message, from, recipient
    end
  end

  puts "[INFO] Email with subject '#{subject}' sent to #{recipients.join(", ")}."
end

# ----------------------------------------------
# Notify about a specific user
# ----------------------------------------------
def send_user_notification(user, creator_name, stream_url)
  critical_recipients = ENV.fetch('CRITICAL_RECIPIENTS', 'someone@example.com').split(',')

  subject = "#{user} is active on a live stream"
  body = "#{user} is active on a live stream!\nCreator: #{creator_name}\nURL: #{stream_url}"

  send_email(subject, body, critical_recipients)
  puts "[INFO] Email notification sent for #{user} on '#{creator_name}'."
end

# ----------------------------------------------
# Successful run completion notification
# ----------------------------------------------
def send_completion_email(total_creators, output_csv, start_time, end_time)
  completion_recipient = ENV.fetch('ERROR_COMPLETION_RECIPIENT', 'mygmail@gmail.com')
  execution_time = (end_time - start_time) / 60.0
  subject = "Program completed successfully"
  body = "Program finished processing top #{total_creators} item(s).\n" \
         "Output written to #{output_csv}.\n" \
         "Program started at: #{start_time.strftime("%Y-%m-%d %H:%M:%S")}\n" \
         "Program ended at: #{end_time.strftime("%Y-%m-%d %H:%M:%S")}\n" \
         "Total execution time: #{execution_time.round(2)} minutes."

  send_email(subject, body, [completion_recipient])
end

# ----------------------------------------------
# Error notification
# ----------------------------------------------
def send_error_notification(error_message)
  error_recipient = ENV.fetch('ERROR_COMPLETION_RECIPIENT', 'mygmail@gmail.com')
  subject = "Program encountered an error"
  body = "An error occurred: #{error_message}\nCheck logs for more details."

  send_email(subject, body, [error_recipient])
end

# ----------------------------------------------
# Main logic
# ----------------------------------------------
def main
  program_start = Time.now
  puts "[INFO] Program started at #{program_start.strftime("%Y-%m-%d %H:%M:%S")}"

  driver = setup_driver
  date_str = Time.now.strftime("%Y%m%d")
  output_csv = "rooms_#{date_str}.csv"
  total_creators = 0

  begin
    creator_records = scrape_creators(driver)
    total_creators = creator_records.size
    puts "[INFO] Found #{total_creators} unique record(s) (capped to first 50)."

    CSV.open(output_csv, "w") do |csv|
      csv << ["Creator Name", "Watch URL", "Timestamp", "Chat Members"]

      creator_records.each_with_index do |record, idx|
        puts "[INFO] Processing record #{idx+1}/#{total_creators}: #{record[:name]}"
        chat_members = scrape_chat_members(driver, record[:url], record[:name])
        puts "       => Found #{chat_members.size} chat member(s)."

        special_usernames = ENV.fetch('SPECIAL_USERNAMES', 'specialuser1').split(',')
        special_usernames.each do |critical_user|
          if chat_members.include?(critical_user)
            puts "[INFO] #{critical_user} found in chat for '#{record[:name]}'. Sending email..."
            send_user_notification(critical_user, record[:name], record[:url])
          end
        end

        record_timestamp = Time.now.strftime("%Y-%m-%d %H:%M:%S")
        csv << [record[:name], record[:url], record_timestamp, chat_members.join('|')]
        sleep 2
      end
    end

    puts "[INFO] Output written to #{output_csv}."
    program_end = Time.now
    send_completion_email(total_creators, output_csv, program_start, program_end)

  rescue => e
    puts "[ERROR] #{e.message}"
    e.backtrace.each { |line| puts "       #{line}" }
    send_error_notification(e.message)
  ensure
    driver.quit
  end
end

# Start the program
main
