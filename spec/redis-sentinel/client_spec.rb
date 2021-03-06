require "spec_helper"

describe Redis::Client do
  let(:client) { double("Client", :reconnect => true) }
  let(:redis)  { double("Redis", :sentinel => ["remote.server", 8888], :client => client) }

  let(:sentinels) do
    [
      {:host => "localhost", :port => 26379},
      {:host => "localhost", :port => 26380}
    ]
  end

  subject { Redis::Client.new(:master_name => "master", :master_password => "foobar",
                              :sentinels => sentinels) }

  before do
    allow(Redis).to receive(:new).and_return(redis)
  end

  context "#sentinel?" do
    it "should be true if passing sentiels and master_name options" do
      expect(subject).to be_sentinel
    end

    it "should not be true if not passing sentinels and master_name options" do
      expect(Redis::Client.new).not_to be_sentinel
    end

    it "should not be true if passing sentinels option but not master_name option" do
      client = Redis::Client.new(
        :sentinels => [
          {:host => "localhost", :port => 26379},
          {:host => "localhost", :port => 26380}
        ])
      expect(client).not_to be_sentinel
    end

    it "should not be true if passing master_name option but not sentinels option" do
      client = Redis::Client.new(:master_name => "master")
      expect(client).not_to be_sentinel
    end
  end

  context "#try_next_sentinel" do
    it "returns next sentinel server" do
      expect(Redis).to receive(:new).with(:host => "localhost", :port => 26379).and_return(redis)
      subject.try_next_sentinel
    end

    it "raises an error if no available sentinel server" do
      client = Redis::Client.new(
        :master_name => "master",
        :sentinels => []
      )
      expect { client.try_next_sentinel }.to raise_error(Redis::CannotConnectError)
    end
  end

  context "#refresh_sentinels_list" do
    it "gets all sentinels list" do
      sentinel = double('sentinel')
      allow(subject).to receive(:current_sentinel_options).and_return(:host => "localhost", :port => 26379)
      expect(subject).to receive(:current_sentinel).and_return(sentinel)
      expect(sentinel).to receive(:sentinel).with("sentinels", "master").and_return([
        ["name", "localhost:26381", "ip", "localhost", "port", 26380],
        ["name", "localhost:26381", "ip", "localhost", "port", 26381]
      ])
      subject.refresh_sentinels_list
      expect(subject.instance_variable_get(:@sentinels_options)).to eq [
        {:host => "localhost", :port => 26379},
        {:host => "localhost", :port => 26380},
        {:host => "localhost", :port => 26381}
      ]
    end
  end

  context "#discover_master" do
    it "updates master config options" do
      expect(redis).to receive(:sentinel).with("get-master-addr-by-name", "master").and_return(["master", 8888])
      expect(redis).to receive(:sentinel).with("sentinels", "master").and_return([{:host => "sentinel", :port => 8888}])
      subject.discover_master
      expect(subject.host).to eq "master"
      expect(subject.port).to eq 8888
    end

    it "selects next sentinel if failed to connect to current_sentinel" do
      expect(subject).to receive(:current_sentinel).and_return(redis)
      expect(redis).to receive(:sentinel).with("get-master-addr-by-name", "master").and_raise(Redis::CannotConnectError)
      sentinel = double('sentinel')
      expect(subject).to receive(:current_sentinel).and_return(sentinel)
      expect(sentinel).to receive(:sentinel).with("get-master-addr-by-name", "master").and_return(["master", 8888])
      allow(subject).to receive(:refresh_sentinels_list)
      subject.discover_master
      expect(subject.host).to eq "master"
      expect(subject.port).to eq 8888
    end

    it "raises error if try_next_sentinel raises error" do
      expect(subject).to receive(:try_next_sentinel).and_raise(Redis::CannotConnectError)
      expect { subject.discover_master }.to raise_error(Redis::CannotConnectError)
    end
  end

  context "#auto_retry_with_timeout" do
    context "no failover reconnect timeout set" do
      subject { Redis::Client.new }

      it "does not sleep" do
        expect(subject).not_to receive(:sleep)
        expect do
          subject.auto_retry_with_timeout { raise Redis::CannotConnectError }
        end.to raise_error(Redis::CannotConnectError)
      end
    end

    context "the failover reconnect timeout is set" do
      subject { Redis::Client.new(:failover_reconnect_timeout => 3) }

      before(:each) do
        allow(subject).to receive(:sleep)
      end

      it "only raises after the failover_reconnect_timeout" do
        called_counter = 0
        allow(Time).to receive(:now).and_return(100, 101, 102, 103, 104, 105)

        begin
          subject.auto_retry_with_timeout do
            called_counter += 1
            raise Redis::CannotConnectError
          end
        rescue Redis::CannotConnectError
        end

        expect(called_counter).to eq(4)
      end

      it "sleeps the default wait time" do
        allow(Time).to receive(:now).and_return(100, 101, 105)
        expect(subject).to receive(:sleep).with(0.1)
        begin
          subject.auto_retry_with_timeout { raise Redis::CannotConnectError }
        rescue Redis::CannotConnectError
        end
      end

      it "does not catch other errors" do
        expect(subject).not_to receive(:sleep)
        expect do
          subject.auto_retry_with_timeout { raise Redis::ConnectionError }
        end.to raise_error(Redis::ConnectionError)
      end

      context "configured wait time" do
        subject { Redis::Client.new(:failover_reconnect_timeout => 3,
                                    :failover_reconnect_wait => 0.01) }

        it "uses the configured wait time" do
          allow(Time).to receive(:now).and_return(100, 101, 105)
          expect(subject).to receive(:sleep).with(0.01)
          begin
            subject.auto_retry_with_timeout { raise Redis::CannotConnectError }
          rescue Redis::CannotConnectError
          end
        end
      end
    end
  end

  context "#disconnect" do
    it "calls disconnect on each sentinel client" do
      sentinel = double('sentinel')
      client = double('client')
      allow(subject).to receive(:current_sentinel).and_return(sentinel)
      expect(sentinel).to receive(:client).and_return(client)
      expect(client).to receive(:disconnect)
      subject.disconnect
    end
  end

end
