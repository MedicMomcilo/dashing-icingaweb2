# from  https://github.com/roidelapluie/dashing-scripts/blob/master/jobs/icinga.rb
# with modifications and additions by Markus Frosch <markus.frosch@netways.de>
require "net/https"
require "uri"
require "nokogiri"

def print_warning(msg)
  puts "\e[33m" + msg + "\e[0m"
end

SCHEDULER.every '15s', :first_in => 0 do |job|
  if ! defined? settings.icinga_cgi
    print_warning("Please configure icinga_cgi in config.ru!")
    next
  end

  icinga_user = nil
  if defined? settings.icinga_user
    icinga_user = settings.icinga_user
  end
  icinga_pass = nil
  if defined? settings.icinga_pass
    icinga_pass = settings.icinga_pass
  end

  # host
  result = get_status_host(settings.icinga_cgi, icinga_user, icinga_pass)
  totals = result["totals"]

  moreinfo = []
  color = 'green'
  display = totals["count"]
  legend = ''

  if totals["unhandled"] > 0
    display = totals["unhandled"].to_s
    legend = 'unhandled'
    if totals["down"] > 0 or totals["unreachable"] > 0
      color = 'red'
    end
  end

  moreinfo.push(totals["down"].to_s + " down") if totals["down"] > 0
  moreinfo.push(totals["unreachable"].to_s + " unreachable") if totals["unreachable"] > 0
  moreinfo.push(totals["ack"].to_s + " ack") if totals["ack"] > 0
  moreinfo.push(totals["downtime"].to_s + " in downtime") if totals["downtime"] > 0

  send_event('icinga-hosts', {
    value: display,
    moreinfo: moreinfo * " | ",
    color: color,
    legend: legend
  })

  send_event('icinga-hosts-latest', {
    rows: result["latest"],
    moreinfo: result["latest_moreinfo"]
  })

  # service
  result = get_status_service(settings.icinga_cgi, icinga_user, icinga_pass)
  totals = result["totals"]

  moreinfo = []
  color = 'green'
  display = totals["count"]
  legend = ''

  if totals["unhandled"] > 0
    display = totals["unhandled"].to_s
    legend = 'unhandled'
    if totals["critical"] > 0
      color = 'red'
    elsif totals["warning"] > 0
      color = 'yellow'
    elsif totals["unknown"] > 0
      color = 'orange'
    end
  end

  moreinfo.push(totals["critical"].to_s + " critical") if totals["critical"] > 0
  moreinfo.push(totals["warning"].to_s + " warning") if totals["warning"] > 0
  moreinfo.push(totals["ack"].to_s + " ack") if totals["ack"] > 0
  moreinfo.push(totals["downtime"].to_s + " in downtime") if totals["downtime"] > 0

  send_event('icinga-services', {
    value: display,
    moreinfo: moreinfo * " | ",
    color: color,
    legend: legend
  })

  send_event('icinga-services-latest', {
    rows: result["latest"],
    moreinfo: result["latest_moreinfo"]
  })

end

def request_status(url, user, pass, type)
  case type
  when "host"
    url_part = "style=hostdetail"
  when "service"
    url_part = "host=all&hoststatustypes=3"
  else
    throw "status type '" + type + "' is not supported!"
  end

  uri = URI.parse(url)
  http = Net::HTTP.start(uri.host, uri.port, :use_ssl => uri.scheme == 'https', :verify_mode => OpenSSL::SSL::VERIFY_NONE)
  path = '/authentication/login'
  headers = {
    'Cookie' => '_chc=1',
    'Content-Type' => 'application/x-www-form-urlencoded'
  }
  resp, data = http.post(path, data, headers)

  cookIcinga = resp.response['set-cookie'].split('; ')[0]
  token = Nokogiri::HTML(resp.body).at('input[@name="CSRFToken"]')['value']
  data = "username="+user+"&password="+pass+"&btn_submit=Login&formUID=form_login&CSRFToken="+token
  headers = {
    'Cookie' => "_chc=1; "+cookIcinga,
    'Content-Type' => 'application/x-www-form-urlencoded'
  }
  resp, data = http.post(path, data, headers)

  path = '/monitoring/list/'+type+'s&format=json'
  cookSession = resp.response['set-cookie'].split('; ')[0]
  cookNew = resp.response['set-cookie'].split('; ')[3]
  cookIcinga = cookNew.split(', ')[1]
  headers = {
    'Cookie' => cookIcinga+"; "+cookSession,
    'Content-Type' => 'text/html'
  }
  resp, data = http.get(path, headers)

  return JSON.parse(resp.body)
end

def get_status_service(url, user, pass)
  service_status = request_status(url, user, pass, 'service')

  latest = []
  latest_counter = 0
  totals = {
    "unhandled" => 0,
    "warning" => 0,
    "critical" => 0,
    "unknown" => 0,
    "ack" => 0,
    "downtime" => 0,
    "count" => 0
  }

  service_status.each { |status|
    totals['count'] += 1

    if status["service_in_downtime"] == "1"
      totals['downtime'] += 1
      next
    elsif status["service_acknowledged"] == "1"
      totals['ack'] += 1
      next
    elsif status["service_state_type"] == "0"
      next
    end

    problem = 0
    case status["service_state"]
    when "2"
      totals['critical'] += 1
      totals['unhandled'] += 1
      text_state = "CRITICAL"
      problem = 1
    when "1"
      totals['warning'] += 1
      totals['unhandled'] += 1
      text_state = "WARNING"
      problem = 1
    when "3"
      totals['unknown'] += 1
      totals['unhandled'] += 1
      text_state = "UNKNOWN"
      problem = 1
    end

    if problem == 1
      latest_counter += 1
      if latest_counter <= 15
        latest.push({ cols: [
          { value: status['host_name'], class: 'icinga-hostname' },
          { value: text_state, class: 'icinga-status icinga-status-service-'+status['service_state'] },
        ]})
        latest.push({ cols: [
          { value: status['service_description'], class: 'icinga-servicename' },
          { value: 'Since: ' + Time.at(status['service_last_state_change'].to_i).utc.to_s, class: 'icinga-duration' }
        ]})
      end
    end
  }

  latest_moreinfo = latest_counter.to_s + " problems"
  if latest_counter > 15
    latest_moreinfo += " | " + (latest_counter - 15).to_s + " not listed"
  end

  return {
    "totals" => totals,
    "latest" => latest,
    "latest_moreinfo" => latest_moreinfo
  }
end

def get_status_host(url, user, pass)
  host_status = request_status(url, user, pass, 'host')

  latest = []
  latest_counter = 0
  totals = {
    "unhandled" => 0,
    "unreachable" => 0,
    "down" => 0,
    "ack" => 0,
    "downtime" => 0,
    "count" => 0
  }

  host_status.each { |status|
    totals['count'] += 1

    if status["host_in_downtime"] == "1"
      totals['downtime'] += 1
      next
    elsif status["host_acknowledged"] == "1"
      totals['ack'] += 1
      next
    elsif status["host_state_type"] == "0"
      next
    end

    problem = 0
    case status["host_state"]
    when "1"
      totals['down'] += 1
      totals['unhandled'] += 1
      text_state = "DOWN"
      problem = 1
    when "2"
      totals['unreachable'] += 1
      totals['unhandled'] += 1
      text_state = "UNREACHABLE"
      problem = 1
    end

    if problem == 1
      latest_counter += 1
      if latest_counter <= 15
        latest.push({ cols: [
          { value: status['host_name'], class: 'icinga-hostname' },
          { value: text_state, class: 'icinga-status icinga-status-host-'+status['host_state'] },
        ]})
        latest.push({ cols: [
          { value: 'Since: ' + Time.at(status['host_last_state_change'].to_i).utc.to_s, class: 'icinga-duration', colspan: 2 },
        ]})
      end
    end
  }

  latest_moreinfo = latest_counter.to_s + " problems"
  if latest_counter > 15
    latest_moreinfo += " | " + (latest_counter - 15).to_s + " not listed"
  end

  return {
    "totals" => totals,
    "latest" => latest,
    "latest_moreinfo" => latest_moreinfo
  }
end

