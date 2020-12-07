#!/usr/bin/env ruby
require 'optparse'
require 'socket'
require 'stringio'
require 'yaml'


module Madns
  RTYPES = YAML.load_file(__dir__ + '/rtypes.yml')

  # A DNS request.
  class Request
    def initialize(qtype, domain)
      @qtype = qtype
      @domain = domain
    end

    attr_reader :qtype, :domain

    # Parse bytes from the given IO source into a request. Returns the
    # transaction ID (the first two bytes) and a Request object, which will be
    # nil if there’s a problem. Remember, this doesn’t need to be a
    # production-grade parser; we just have do to enough protocol parsing to
    # extract the first query, without worrying about edge-cases.
    def self.parse(io)
      txid = io.read(2).unpack('n').first
      flags = io.read(2).unpack('n').first

      questions_count = io.read(2).unpack('n').first
      answers_count = io.read(2).unpack('n').first
      authorities_count = io.read(2).unpack('n').first
      additionals_count = io.read(2).unpack('n').first
      # some clients will send an OPT which is opt-ional
      if [questions_count, answers_count, authorities_count] != [1, 0, 0]
        return [txid, nil]
      end

      domain_parts = []
      loop do
        count = io.read(1).unpack('C').first
        break if count.zero?   # no need to decrement the counter
        domain_parts << io.read(count)
      end

      domain = domain_parts.join('.')

      qtype = io.read(2).unpack('n').first
      qtype = RTYPES[qtype]
      if qtype.nil?
        return [txid, nil]
      end
      qclass = io.read(2).unpack('n').first

      [txid, new(qtype, domain)]
    end
  end


  # The DNS server class, which handles incoming connections, Hexit
  # invocation, and response construction.
  class Server
    def initialize(args)
      @args = args
    end

    # Open a socket and continually waits for requests, parsing each one and
    # sending back the response. Never returns.
    def listen_and_block(transport)
      puts "Listening..."

      loop do
        transport.wait_and_handle_request do |str|
          txid, req = Request.parse(StringIO.new(str))
          res = respond_to_request(txid, req)
        end
      end
    end

  private

    # Constructs a DNS response as a string of bytes, given a parsed request’s
    # transaction ID, type, and domain.
    def respond_to_request(txid, req)
      if req.nil?
        return respond_with_flags(txid, 0x8185)
      end

      if req.domain == 'random-data.invalid'
        puts "[random] #{req.domain.inspect}"
        return respond_with_data(txid, Random.new.bytes(988))
      end

      if ! File.exist?(__dir__ + "/../samples/#{req.qtype}/#{req.domain}.hexit")
        puts "ERR #{req.domain} question"
        return respond_with_flags(txid, 0x8184)
      end

      puts "[#{req.qtype}] #{req.domain.inspect}"
      hexit_output = @args.run_hexit(req)
      if hexit_output.nil?
        return respond_with_flags(txid, 0x8182)
      end

      respond_with_data(txid, hexit_output)
    end

    # Creates a string of bytes representing a DNS response with the given
    # transaction ID and flags (which should signify an error code).
    def respond_with_flags(txid, flags)
      [txid, flags, 0, 0, 0, 0].pack('n*')
    end

    # Creates a string of bytes representing a DNS response beginning with the
    # given transaction ID and ending with the given string of bytes, which
    # should have come from Hexit.
    def respond_with_data(txid, bytes_str)
      [txid].pack('n') + bytes_str.bytes.pack('C*')
    end
  end


  # The user’s command-line options.
  class Options
    def initialize
      @bind_addr = nil
      @port = nil
      @proto = nil
      @samples_dir = nil
    end

    attr_accessor :bind_addr, :port, :proto, :samples_dir

    # Parse the input arguments into an Options object, printing an error
    # message and exiting if there’s a problem with the user’s input.
    def self.parse(argv)
      args = new

      opt_parser = OptionParser.new do |opts|
        opts.banner = "Usage: madns.rb [options]"

        opts.on("-bADDR", "--bind=ADDR", "Network address to bind to") do |n|
          args.bind_addr = n
        end

        opts.on("-pPORT", "--port=PORT", "Port to serve on") do |n|
          args.port = n
        end

        opts.on("--tcp", "Serve over TCP") do |n|
          args.proto = :tcp
        end

        opts.on("--udp", "Serve over UDP") do |n|
          args.proto = :udp
        end

        opts.on("-dDIR", "--dir=DIR", "Path to the samples directory") do |n|
          args.samples_dir = n
        end

        opts.on("-h", "--help", "Print this help") do
          puts opts
          exit
        end
      end.parse!(argv)

      if args.proto.nil?
        $stderr.puts "No protocol given (use --tcp or --udp)"
        exit 3
      elsif args.bind_addr.nil?
        $stderr.puts "No bind address given (use --bind)"
        exit 3
      elsif args.port.nil?
        $stderr.puts "No port given (use --port)"
        exit 3
      elsif args.samples_dir.nil?
        $stderr.puts "No samples directory given (use --dir)"
        exit 3
      else
        args
      end
    rescue OptionParser::ParseError => e
      $stderr.puts e.message
      exit 3
    end

    # Starts a TCP or UDP server, bound to an address and port, depending on
    # the input arguments.
    def open_transport
      case @proto
      when :tcp
        TcpTransport.new(@bind_addr, @port)
      when :udp
        UdpTransport.new(@bind_addr, @port)
      end
    end

    # Runs Hexit on a file in the samples directory, specified by the request
    # type and domain, returning its output as a String if successful, or nil
    # if unsuccessful.
    def run_hexit(req)
      out = `hexit #{@samples_dir}/#{req.qtype}/#{req.domain}.hexit --raw`
      out if $?.success?
    end
  end


  # A transport that sends and receives data over UDP.
  class UdpTransport
    def initialize(bind_addr, port)
      @socket = UDPSocket.new
      @socket.bind(bind_addr, port)
    end

    def wait_and_handle_request
      payload, client = @socket.recvfrom(1024)
      # client is: address_family, port, hostname, numeric_address
      puts "RECV #{client[3]}"

      response = yield payload
      @socket.send(response, 0, client[3], client[1])
    end
  end


  # A transport that sends and receives data over TCP. According to the DNS
  # spec, these messages are prefixed by the length.
  class TcpTransport
    def initialize(bind_addr, port)
      @server = TCPServer.new(bind_addr, port)
    end

    def wait_and_handle_request
      socket = @server.accept

      payload_len_str = socket.read(2)
      if payload_len_str.nil?
        return nil
      end

      payload_len = payload_len_str.unpack('n').first
      payload = socket.read(payload_len)

      response = yield payload
      socket.send([response.length].pack('n'), 0)
      socket.send(response, 0)
    end
  end
end


if $PROGRAM_NAME == __FILE__
  args = Madns::Options.parse(ARGV)
  Madns::Server.new(args).listen_and_block(args.open_transport)
end