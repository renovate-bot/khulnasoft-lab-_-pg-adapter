# frozen_string_literal: true
require "pry"

class Dummy
  attr_accessor :reconnect_called

  def initialize
    @reconnect_called = false
  end

  private

  def exec_no_cache; end

  def throw_away!; end

  def connect; end

  def in_transaction?
    false
  end
end

EXCEPTION_MESSAGE =
  "PG::ReadOnlySqlTransaction: ERROR:  cannot execute UPDATE in a read-only transaction"
COLUMN_EXCEPTION_MESSAGE = "PG::UndefinedColumn: ERROR:  column users.template_id does not exist"

RSpec.describe(PgAdapter::Patch) do
  before do
    PgAdapter.configure do |c|
      c.add_failover_patch = true
      c.add_reset_column_information_patch = true
      c.reconnect_with_backoff = []
    end
  end

  describe "#exec_cache" do
    it "clears connection when a PG::ReadOnlySqlTransaction exception is raised" do
      allow_any_instance_of(Dummy).to receive(:exec_cache).and_raise(
        ActiveRecord::StatementInvalid.new(EXCEPTION_MESSAGE),
      )

      allow_any_instance_of(Object).to receive(:sleep)
      expect_any_instance_of(Dummy).to receive(:throw_away!)
      expect { Dummy.new.extend(PgAdapter::Patch).send(:exec_cache) }.to raise_error(
        ActiveRecord::StatementInvalid,
        "PG::ReadOnlySqlTransaction: ERROR:  cannot execute UPDATE in a read-only transaction",
      )
    end

    it "does not call clear_all_connections when a general exception is raised" do
      allow_any_instance_of(Dummy).to receive(:exec_cache).and_raise("Exception")
      expect { Dummy.new.extend(PgAdapter::Patch).send(:exec_cache) }.to raise_error(
        "Exception",
      )
    end

    it "clears schema cache when a PG::UndefinedColumn exception is raised" do
      allow_any_instance_of(Dummy).to receive(:exec_cache).and_raise(
        ActiveRecord::StatementInvalid.new(COLUMN_EXCEPTION_MESSAGE),
      )

      expect(ActiveRecord::Base).to receive(:descendants).at_least(:once).and_call_original

      expect { Dummy.new.extend(PgAdapter::Patch).send(:exec_cache) }.to raise_error(
        ActiveRecord::StatementInvalid,
        "PG::UndefinedColumn: ERROR:  column users.template_id does not exist",
      )
    end

    it "reloads connections when a ActiveRecord::NoDatabaseError is retries once and fails" do
      msg = "is not currently accepting connections"
      PgAdapter.configure do |c|
        c.add_failover_patch = true
        c.add_reset_column_information_patch = true
        c.reconnect_with_backoff = [0.5]
      end

      allow_any_instance_of(Dummy).to receive(:exec_cache).and_raise(
        ActiveRecord::NoDatabaseError.new(msg),
      )

      allow_any_instance_of(Object).to receive(:sleep)
      expect_any_instance_of(Dummy).to receive(:throw_away!).exactly(3).times

      expect { Dummy.new.extend(PgAdapter::Patch).send(:exec_cache) }.to raise_error(
        ActiveRecord::NoDatabaseError,
        msg,
      )
    end

    it "reloads connections when a PG::ReadOnlySqlTransaction is retries once and fails" do
      PgAdapter.configure do |c|
        c.add_failover_patch = true
        c.add_reset_column_information_patch = true
        c.reconnect_with_backoff = [0.5]
      end

      allow_any_instance_of(Dummy).to receive(:exec_cache).and_raise(
        ActiveRecord::StatementInvalid.new(EXCEPTION_MESSAGE),
      )

      allow_any_instance_of(Object).to receive(:sleep)
      expect_any_instance_of(Dummy).to receive(:throw_away!).exactly(3).times

      expect { Dummy.new.extend(PgAdapter::Patch).send(:exec_cache) }.to raise_error(
        ActiveRecord::StatementInvalid,
        "PG::ReadOnlySqlTransaction: ERROR:  cannot execute UPDATE in a read-only transaction",
      )
    end

    it "re-raises if within transaction" do
      PgAdapter.configure do |c|
        c.add_failover_patch = true
        c.add_reset_column_information_patch = true
        c.reconnect_with_backoff = [0.5]
      end
      expect_any_instance_of(Dummy).to receive(:in_transaction?).and_return(true)
      allow_any_instance_of(Dummy).to receive(:exec_cache).and_raise(
        ActiveRecord::StatementInvalid.new(EXCEPTION_MESSAGE),
      )

      allow_any_instance_of(Object).to receive(:sleep)
      expect_any_instance_of(Dummy).to receive(:throw_away!).exactly(:once)

      expect { Dummy.new.extend(PgAdapter::Patch).send(:exec_cache) }.to raise_error(
        ActiveRecord::StatementInvalid,
        "PG::ReadOnlySqlTransaction: ERROR:  cannot execute UPDATE in a read-only transaction",
      )
    end
  end

  describe "#exec_no_cache" do
    it "reloads connections when a PG::ReadOnlySqlTransaction exception is raised" do
      allow_any_instance_of(Dummy).to receive(:exec_no_cache).and_raise(
        ActiveRecord::StatementInvalid.new(EXCEPTION_MESSAGE),
      )

      allow_any_instance_of(Object).to receive(:sleep)
      expect_any_instance_of(Dummy).to receive(:throw_away!)

      expect { Dummy.new.extend(PgAdapter::Patch).send(:exec_no_cache) }.to raise_error(
        ActiveRecord::StatementInvalid,
        "PG::ReadOnlySqlTransaction: ERROR:  cannot execute UPDATE in a read-only transaction",
      )
    end

    it "reloads connections when a ActiveRecord::ConnectionNotEstablished exception is raised" do
      msg = "connection is closed"
      allow_any_instance_of(Dummy).to receive(:exec_no_cache).and_raise(
        ActiveRecord::ConnectionNotEstablished.new(msg),
      )

      allow_any_instance_of(Object).to receive(:sleep)
      expect_any_instance_of(Dummy).to receive(:throw_away!)
      expect { Dummy.new.extend(PgAdapter::Patch).send(:exec_no_cache) }.to raise_error(
        ActiveRecord::ConnectionNotEstablished,
        msg,
      )
    end

    it "reloads connections when a ActiveRecord::ConnectionNotEstablished retries once and fails" do
      PgAdapter.configure do |c|
        c.add_failover_patch = true
        c.add_reset_column_information_patch = true
        c.reconnect_with_backoff = [0.5]
      end

      msg = "connection is closed"
      allow_any_instance_of(Dummy).to receive(:exec_no_cache).and_raise(
        ActiveRecord::ConnectionNotEstablished.new(msg),
      )

      allow_any_instance_of(Object).to receive(:sleep)
      expect_any_instance_of(Dummy).to receive(:throw_away!).exactly(3).times
      expect_any_instance_of(Dummy).to receive(:connect).once

      d = Dummy.new
      expect do
        d.extend(PgAdapter::Patch).send(:exec_no_cache)
        expect(d.reconnect_called).to be(true)
      end.to raise_error(ActiveRecord::ConnectionNotEstablished, msg)
    end

    it "reloads connections when a ActiveRecord::NoDatabaseError is retries once and fails" do
      msg = "is not currently accepting connections"
      PgAdapter.configure do |c|
        c.add_failover_patch = true
        c.add_reset_column_information_patch = true
        c.reconnect_with_backoff = [0.5]
      end

      allow_any_instance_of(Dummy).to receive(:exec_no_cache).and_raise(
        ActiveRecord::NoDatabaseError.new(msg),
      )

      allow_any_instance_of(Object).to receive(:sleep)
      expect_any_instance_of(Dummy).to receive(:throw_away!).exactly(3).times
      expect_any_instance_of(Dummy).to receive(:connect).once

      expect { Dummy.new.extend(PgAdapter::Patch).send(:exec_no_cache) }.to raise_error(
        ActiveRecord::NoDatabaseError,
        msg,
      )
    end

    it "reloads connections when a PG::ReadOnlySqlTransaction is retries once and fails" do
      PgAdapter.configure do |c|
        c.add_failover_patch = true
        c.add_reset_column_information_patch = true
        c.reconnect_with_backoff = [0.5]
      end

      allow_any_instance_of(Dummy).to receive(:exec_no_cache).and_raise(
        ActiveRecord::StatementInvalid.new(EXCEPTION_MESSAGE),
      )

      allow_any_instance_of(Object).to receive(:sleep)
      expect_any_instance_of(Dummy).to receive(:throw_away!).exactly(3).times
      expect_any_instance_of(Dummy).to receive(:connect).once

      expect { Dummy.new.extend(PgAdapter::Patch).send(:exec_no_cache) }.to raise_error(
        ActiveRecord::StatementInvalid,
        "PG::ReadOnlySqlTransaction: ERROR:  cannot execute UPDATE in a read-only transaction",
      )
    end

    it "does not call clear_all_connections when a general exception is raised" do
      allow_any_instance_of(Dummy).to receive(:exec_no_cache).and_raise("Exception")
      expect(ActiveRecord::Base).not_to receive(:clear_all_connections!)
      expect { Dummy.new.extend(PgAdapter::Patch).send(:exec_no_cache) }.to raise_error(
        "Exception",
      )
    end

    it "clears schema cache when a PG::UndefinedColumn exception is raised" do
      allow_any_instance_of(Dummy).to receive(:exec_no_cache).and_raise(
        ActiveRecord::StatementInvalid.new(COLUMN_EXCEPTION_MESSAGE),
      )

      expect(ActiveRecord::Base).to receive(:descendants).at_least(:once).and_call_original

      expect { Dummy.new.extend(PgAdapter::Patch).send(:exec_no_cache) }.to raise_error(
        ActiveRecord::StatementInvalid,
        "PG::UndefinedColumn: ERROR:  column users.template_id does not exist",
      )
    end

    it "re-raises if within transaction" do
      PgAdapter.configure do |c|
        c.add_failover_patch = true
        c.add_reset_column_information_patch = true
        c.reconnect_with_backoff = [0.5]
      end
      expect_any_instance_of(Dummy).to receive(:in_transaction?).and_return(true)
      allow_any_instance_of(Dummy).to receive(:exec_no_cache).and_raise(
        ActiveRecord::StatementInvalid.new(EXCEPTION_MESSAGE),
      )

      allow_any_instance_of(Object).to receive(:sleep)
      expect_any_instance_of(Dummy).to receive(:throw_away!).exactly(:once)

      expect { Dummy.new.extend(PgAdapter::Patch).send(:exec_no_cache) }.to raise_error(
        ActiveRecord::StatementInvalid,
        "PG::ReadOnlySqlTransaction: ERROR:  cannot execute UPDATE in a read-only transaction",
      )
    end
  end

  describe "#new_client" do
    it "attempts to make a connection, retries once and bubbles up the exception" do
      PgAdapter.configure do |c|
        c.add_failover_patch = true
        c.add_reset_column_information_patch = true
        c.reconnect_with_backoff = [0.5]
      end

      expect(PG).to receive(:connect)
        .and_raise(ActiveRecord::ConnectionNotEstablished, "connection is closed")
        .exactly(:twice)
      expect(Object).to receive(:sleep).exactly(:once)

      expect do
        ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.new_client(
          ActiveRecord::Base.connection.instance_variable_get(:@config),
        )
      end.to raise_error(ActiveRecord::ConnectionNotEstablished)
    end

    it "attempts to make a connection when ActiveRecord::NoDatabaseError is raised, retries once and bubbles up the exception" do
      PgAdapter.configure do |c|
        c.add_failover_patch = true
        c.add_reset_column_information_patch = true
        c.reconnect_with_backoff = [0.5]
      end

      expect(PG).to receive(:connect).and_raise(ActiveRecord::NoDatabaseError, "is not currently accepting connections").exactly(:twice)
      expect(Object).to receive(:sleep).exactly(:once)

      expect do
        ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.new_client(
          ActiveRecord::Base.connection.instance_variable_get(:@config),
        )
      end.to raise_error(ActiveRecord::NoDatabaseError)
    end
  end
end
