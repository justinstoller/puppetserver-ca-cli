require 'spec_helper'
require 'puppetserver/ca/config/puppet'

RSpec.describe 'Puppetserver::Ca::Config::Puppet' do
  subject { Puppetserver::Ca::Config::Puppet.new }

  it 'parses basic inifile' do
    parsed = subject.parse_text(<<-INI)
    server = certname

    [master]
      dns_alt_names=puppet,foo
      cadir        = /var/www/super-secure

    [main]
    environment = prod_1_env
    INI

    expect(parsed.keys).to include(:master, :main)
    expect(parsed[:main]).to include({
      server: 'certname',
      environment: 'prod_1_env'
    })
    expect(parsed[:master]).to include({
      dns_alt_names: 'puppet,foo',
      cadir: '/var/www/super-secure'
    })
  end

  it 'discards weird file metadata info' do
    parsed = subject.parse_text(<<-INI)
    [ca]
      cadir = /var/www/ca {user = service}

    [master]
      coming_at = Innsmouth
      mantra = Pu̴t t̢h͞é ̢ćlas̸s̡e̸s̢ ̴in̡ arra̴y͡s̸ ̸o͟r̨ ̸hashe͜s̀ or w̨h̕át̀ev̵èr

    Now ̸to m̡et̴apr̷og҉ram a si͠mpl͞e ḑsl
    INI

    expect(parsed).to include({ca: {cadir: '/var/www/ca'}})
  end

  it 'resolves dependent settings properly' do
    Dir.mktmpdir do |tmpdir|
      puppet_conf = File.join(tmpdir, 'puppet.conf')
      File.open puppet_conf, 'w' do |f|
        f.puts(<<-INI)
          [master]
            ssldir = /foo/bar
            cacrl = /fizz/buzz/crl.pem
        INI
      end

      conf = Puppetserver::Ca::Config::Puppet.new(puppet_conf)
      conf.load

      expect(conf.errors).to be_empty
      expect(conf.settings[:cacert]).to eq('/foo/bar/ca/ca_crt.pem')
      expect(conf.settings[:cacrl]).to eq('/fizz/buzz/crl.pem')
    end
  end

  it 'correctly reads server_list' do
    p1 = subject.parse_text(<<-INI)
    [main]
      server_list = foo:80,bar,baz:99
    INI
    expect(p1[:main]).to include({
      server_list: 'foo:80,bar,baz:99'
    })

    s1 = subject.resolve_settings(p1[:main])
    expect(s1[:server_list]).to eq([
      ["foo", "80"], ["bar"], ["baz", "99"]
    ])

    p2 = subject.parse_text(<<-INI)
      [main]
        server = foo
    INI
    s2 = subject.resolve_settings(p2[:main])
    expect(s2[:server_list]).to eq([])
  end

  it 'overrides ca_server and ca_port when defaults and server_list is set' do
    parsed = subject.parse_text(<<-INI)
      [main]
        server_list = ca.example.com:8080
    INI

    settings = subject.resolve_settings(parsed[:main])

    expect(settings[:server_list]).to eq([["ca.example.com", "8080"]])
    expect(settings[:ca_server]).to eq("ca.example.com")
    expect(settings[:server]).to eq("ca.example.com")
    expect(settings[:ca_port]).to eq('8080')
    expect(settings[:masterport]).to eq('8080')
  end

  it 'converts ca_ttl setting correctly into seconds' do
    Dir.mktmpdir do |tmpdir|
      puppet_conf = File.join(tmpdir, 'puppet.conf')
      File.open puppet_conf, 'w' do |f|
        f.puts(<<-INI)
          [master]
            ca_ttl = 5y
        INI
      end

      conf = Puppetserver::Ca::Config::Puppet.new(puppet_conf)
      conf.load

      expect(conf.errors).to be_empty
      expect(conf.settings[:ca_ttl]).to eq(157680000)
    end
  end

  context "when dns_alt_names are provided" do
    it 'prepends "DNS" to unprefixed alt names and includes default certname' do
      allow_any_instance_of(Puppetserver::Ca::Config::Puppet).
        to receive(:default_certname).and_return("chihuahua-333")

      Dir.mktmpdir do |tmpdir|
        puppet_conf = File.join(tmpdir, 'puppet.conf')
        File.open puppet_conf, 'w' do |f|
          f.puts(<<-INI)
            [master]
              dns_alt_names = foo.com,IP:123.456.789
          INI
        end

        conf = Puppetserver::Ca::Config::Puppet.new(puppet_conf)
        conf.load

        expect(conf.errors).to be_empty
        expect(conf.settings[:subject_alt_names]).
          to eq('DNS:chihuahua-333, DNS:foo.com, IP:123.456.789')
      end
    end
  end

  context "when dns_alt_names are NOT provided" do
    it 'it returns an empty string for subject_alt_names' do
      Dir.mktmpdir do |tmpdir|
        puppet_conf = File.join(tmpdir, 'puppet.conf')
        File.open puppet_conf, 'w' do |f|
          f.puts(<<-INI)
            [master]
              certname = foo.com
          INI
        end

        conf = Puppetserver::Ca::Config::Puppet.new(puppet_conf)
        conf.load

        expect(conf.errors).to be_empty
        expect(conf.settings[:subject_alt_names]).
          to eq('')
      end
    end
  end

  it 'errs if it cannot resolve dependent settings properly' do
    Dir.mktmpdir do |tmpdir|
      puppet_conf = File.join(tmpdir, 'puppet.conf')
      File.open puppet_conf, 'w' do |f|
        f.puts(<<-INI)
          [master]
            ssldir = $vardir/ssl
        INI
      end

      conf = Puppetserver::Ca::Config::Puppet.new(puppet_conf)
      conf.load

      expect(conf.errors.first).to include('$vardir in $vardir/ssl')
      expect(conf.settings[:cacert]).to eq('$vardir/ssl/ca/ca_crt.pem')
    end
  end
end
