require 'etc'
require 'fileutils'
require 'optparse'
require 'puppetserver/ca/x509_loader'
require 'puppetserver/ca/puppet_config'

module Puppetserver
  module Ca
    class SetupAction

      SUMMARY = "Set up the CA's key, certs, and crls"
      BANNER = <<-BANNER
Usage:
  puppetserver ca setup [--help|--version]
  puppetserver ca setup [--config PATH]
      --private-key PATH --cert-bundle PATH --crl-chain PATH

Description:
Given a private key, cert bundle, and a crl chain,
validate and import to the Puppet Server CA.

To determine the target location the default puppet.conf
is consulted for custom values. If using a custom puppet.conf
provide it with the --config flag

Options:
BANNER

      def initialize(logger)
        @logger = logger
      end

      def run(input)
        bundle_path = input['cert-bundle']
        key_path = input['private-key']
        chain_path = input['crl-chain']
        config_path = input['config']

        files = [bundle_path, key_path, chain_path, config_path].compact

        errors = validate_file_paths(files)
        return 1 if log_possible_errors(errors)

        loader = X509Loader.new(bundle_path, key_path, chain_path)
        return 1 if log_possible_errors(loader.errors)

        puppet = PuppetConfig.parse(config_path)
        return 1 if log_possible_errors(puppet.errors)

        user, group = find_user_and_group

        if !File.exist?(puppet.settings[:cadir])
          FileUtils.mkdir_p(puppet.settings[:cadir], mode: 0750)
          FileUtils.chown(user, group, puppet.settings[:cadir])
        end

        write_file(puppet.settings[:cacert], loader.certs, user, group, 0640)

        write_file(puppet.settings[:cakey], loader.key, user, group, 0640)

        write_file(puppet.settings[:cacrl], loader.crls, user, group, 0640)

        if !File.exist?(puppet.settings[:serial])
          write_file(puppet.settings[:serial], "001", user, group, 0640)
        end

        if !File.exist?(puppet.settings[:cert_inventory])
          write_file(puppet.settings[:cert_inventory],
                     "", user, group, 0640)
        end

        return 0
      end

      def find_user_and_group
        if !running_as_root?
          return Process.euid, Process.egid
        else
          if pe_puppet_exists?
            return 'pe-puppet', 'pe-puppet'
          else
            return 'puppet', 'puppet'
          end
        end
      end

      def running_as_root?
        !Gem.win_platform? && Process.euid == 0
      end

      def pe_puppet_exists?
        !!(Etc.getpwnam('pe-puppet') rescue nil)
      end

      def write_file(path, one_or_more_objects, user, group, mode)
        if File.exist?(path)
          @logger.warn("#{path} exists, overwriting")
        end

        File.open(path, 'w', mode) do |f|
          Array(one_or_more_objects).each do |object|
            f.puts object.to_s
          end
        end

        FileUtils.chown(user, group, path)
      end

      def log_possible_errors(maybe_errors)
        errors = Array(maybe_errors).compact
        unless errors.empty?
          @logger.err "Error:"
          errors.each do |message|
            @logger.err "    #{message}"
          end
          return true
        end
      end

      def parse(cli_args)
        parser, inputs, unparsed = parse_inputs(cli_args)

        if !unparsed.empty?
          @logger.err 'Error:'
          @logger.err 'Unknown arguments or flags:'
          unparsed.each do |arg|
            @logger.err "    #{arg}"
          end

          @logger.err ''
          @logger.err parser.help

          exit_code = 1
        else
          exit_code = validate_inputs(inputs, parser.help)
        end

        return inputs, exit_code
      end

      def validate_inputs(input, usage)
        exit_code = nil

        if input.values_at('cert-bundle', 'private-key', 'crl-chain').any?(&:nil?)
          @logger.err 'Error:'
          @logger.err 'Missing required argument'
          @logger.err '    --cert-bundle, --private-key, --crl-chain are required'
          @logger.err ''
          @logger.err usage
          exit_code = 1
        end

        exit_code
      end

      def parse_inputs(inputs)
        parsed = {}
        unparsed = []

        parser = self.class.parser(parsed)

        begin
          parser.order!(inputs) do |nonopt|
            unparsed << nonopt
          end
        rescue OptionParser::ParseError => e
          unparsed += e.args
          unparsed << inputs.shift unless inputs.first =~ /^-{1,2}/
          retry
        end

        return parser, parsed, unparsed
      end

      def self.parser(parsed = {})
        OptionParser.new do |opts|
          opts.banner = BANNER
          opts.on('--help', 'Display this setup specific help output') do |help|
            parsed['help'] = true
          end
          opts.on('--version', 'Output the version') do |v|
            parsed['version'] = true
          end
          opts.on('--config CONF', 'Path to puppet.conf') do |conf|
            parsed['config'] = conf
          end
          opts.on('--private-key KEY', 'Path to PEM encoded key') do |key|
            parsed['private-key'] = key
          end
          opts.on('--cert-bundle BUNDLE', 'Path to PEM encoded bundle') do |bundle|
            parsed['cert-bundle'] = bundle
          end
          opts.on('--crl-chain CHAIN', 'Path to PEM encoded chain') do |chain|
            parsed['crl-chain'] = chain
          end
        end
      end

      def validate_file_paths(one_or_more_paths)
        errors = []
        Array(one_or_more_paths).each do |path|
          if !File.exist?(path) || !File.readable?(path)
            errors << "Could not read file '#{path}'"
          end
        end

        errors
      end
    end
  end
end
