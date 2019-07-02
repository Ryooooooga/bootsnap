require_relative('../explicit_require')

Bootsnap::ExplicitRequire.with_gems('msgpack') { require('msgpack') }
Bootsnap::ExplicitRequire.from_rubylibdir('fileutils')

module Bootsnap
  module LoadPathCache
    class Store
      NestedTransactionError = Class.new(StandardError)
      SetOutsideTransactionNotAllowed = Class.new(StandardError)

      def initialize(store_path)
        @store_path = store_path
        @in_txn = false
        @dirty = false
        load_data
      end

      def get(key)
        @data[key]
      end

      def fetch(key)
        raise(SetOutsideTransactionNotAllowed) unless @in_txn
        v = get(key)
        unless v
          @dirty = true
          v = yield
          @data[key] = v
        end
        v
      end

      def set(key, value)
        raise(SetOutsideTransactionNotAllowed) unless @in_txn
        if value != @data[key]
          @dirty = true
          @data[key] = value
        end
      end

      def transaction
        raise(NestedTransactionError) if @in_txn
        @in_txn = true
        yield
      ensure
        commit_transaction
        @in_txn = false
      end

      private

      def commit_transaction
        if @dirty
          dump_data
          @dirty = false
        end
      end

      def load_data
        @data = begin
          deduplicate!(MessagePack.load(File.binread(@store_path)))
          # handle malformed data due to upgrade incompatability
        rescue Errno::ENOENT, MessagePack::MalformedFormatError, MessagePack::UnknownExtTypeError, EOFError
          {}
        rescue ArgumentError => e
          e.message =~ /negative array size/ ? {} : raise
        end
      end

      def dump_data
        # Change contents atomically so other processes can't get invalid
        # caches if they read at an inopportune time.
        tmp = "#{@store_path}.#{Process.pid}.#{(rand * 100000).to_i}.tmp"
        FileUtils.mkpath(File.dirname(tmp))
        exclusive_write = File::Constants::CREAT | File::Constants::EXCL | File::Constants::WRONLY
        # `encoding:` looks redundant wrt `binwrite`, but necessary on windows
        # because binary is part of mode.
        File.binwrite(tmp, MessagePack.dump(@data), mode: exclusive_write, encoding: Encoding::BINARY)
        FileUtils.mv(tmp, @store_path)
      rescue Errno::EEXIST
        retry
      end

      def deduplicate!(value)
        case value
        when Hash
          new_hash = {}
          value.each_key do |key|
            new_hash[deduplicate!(key)] = deduplicate!(value[key])
          end
          new_hash
        when Array
          value.map! { |v| deduplicate!(v) }
          value
        when String
          -value
        else
          value
        end
      end
    end
  end
end
