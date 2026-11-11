# Minimal stand-in for the Appbox API in tests: logs each request line as
# "MOCK <method> <path>" and answers 200 with an empty JSON object.
require 'socket'

$stdout.sync = true
server = TCPServer.new('0.0.0.0', 8080)

loop do
  client = server.accept
  begin
    method, path = client.gets.to_s.split(' ')
    length = 0
    while (line = client.gets) && line != "\r\n"
      name, value = line.split(':', 2)
      length = value.to_i if name.to_s.casecmp('content-length').zero?
    end
    client.read(length) if length.positive?
    puts "MOCK #{method} #{path}"
    client.write "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
  rescue StandardError => e
    puts "MOCK error #{e.class}"
  ensure
    client.close
  end
end
