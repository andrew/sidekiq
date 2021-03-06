require 'securerandom'
require 'sidekiq'

module Sidekiq

  class Testing
    class << self
      attr_accessor :__test_mode

      def __set_test_mode(mode)
        if block_given?
          current_mode = self.__test_mode
          begin
            self.__test_mode = mode
            yield
          ensure
            self.__test_mode = current_mode
          end
        else
          self.__test_mode = mode
        end
      end

      def disable!(&block)
        __set_test_mode(:disable, &block)
      end

      def fake!(&block)
        __set_test_mode(:fake, &block)
      end

      def inline!(&block)
        __set_test_mode(:inline, &block)
      end

      def enabled?
        self.__test_mode != :disable
      end

      def disabled?
        self.__test_mode == :disable
      end

      def fake?
        self.__test_mode == :fake
      end

      def inline?
        self.__test_mode == :inline
      end

      def server_middleware
        @server_chain ||= Middleware::Chain.new
        yield @server_chain if block_given?
        @server_chain
      end
    end
  end

  # Default to fake testing to keep old behavior
  Sidekiq::Testing.fake!

  class EmptyQueueError < RuntimeError; end

  class Client
    alias_method :raw_push_real, :raw_push

    def raw_push(payloads)
      if Sidekiq::Testing.fake?
        payloads.each do |job|
          Queues.jobs[job['queue']] << Sidekiq.load_json(Sidekiq.dump_json(job))
        end
        true
      elsif Sidekiq::Testing.inline?
        payloads.each do |job|
          klass = job['class'].constantize
          job['id'] ||= SecureRandom.hex(12)
          job_hash = Sidekiq.load_json(Sidekiq.dump_json(job))
          klass.process_job(job_hash)
        end
        true
      else
        raw_push_real(payloads)
      end
    end
  end

  module Queues
    ##
    # The Queues class is only for testing the fake queue implementation.
    # The data is structured as a hash with queue name as hash key and array
    # of job data as the value.
    #
    # {
    #   "default"=>[
    #     {
    #       "class"=>"TestTesting::QueueWorker",
    #       "args"=>[1, 2],
    #       "retry"=>true,
    #       "queue"=>"default",
    #       "jid"=>"abc5b065c5c4b27fc1102833",
    #       "created_at"=>1447445554.419934
    #     }
    #   ]
    # }
    #
    # Example:
    #
    #   require 'sidekiq/testing'
    #
    #   assert_equal 0, Sidekiq::Queues["default"].size
    #   HardWorker.perform_async(:something)
    #   assert_equal 1, Sidekiq::Queues["default"].size
    #   assert_equal :something, Sidekiq::Queues["default"].first['args'][0]
    #
    # You can also clear all workers' jobs:
    #
    #   assert_equal 0, Sidekiq::Queues["default"].size
    #   HardWorker.perform_async(:something)
    #   Sidekiq::Queues.clear_all
    #   assert_equal 0, Sidekiq::Queues["default"].size
    #
    # This can be useful to make sure jobs don't linger between tests:
    #
    #   RSpec.configure do |config|
    #     config.before(:each) do
    #       Sidekiq::Queues.clear_all
    #     end
    #   end
    #
    class << self
      def [](queue)
        jobs[queue.to_s]
      end

      def jobs
        @jobs ||= Hash.new { |hash, key| hash[key] = [] }
      end

      def clear_all
        jobs.clear
      end
    end
  end

  module Worker
    ##
    # The Sidekiq testing infrastructure overrides perform_async
    # so that it does not actually touch the network.  Instead it
    # stores the asynchronous jobs in a per-class array so that
    # their presence/absence can be asserted by your tests.
    #
    # This is similar to ActionMailer's :test delivery_method and its
    # ActionMailer::Base.deliveries array.
    #
    # Example:
    #
    #   require 'sidekiq/testing'
    #
    #   assert_equal 0, HardWorker.jobs.size
    #   HardWorker.perform_async(:something)
    #   assert_equal 1, HardWorker.jobs.size
    #   assert_equal :something, HardWorker.jobs[0]['args'][0]
    #
    #   assert_equal 0, Sidekiq::Extensions::DelayedMailer.jobs.size
    #   MyMailer.delay.send_welcome_email('foo@example.com')
    #   assert_equal 1, Sidekiq::Extensions::DelayedMailer.jobs.size
    #
    # You can also clear and drain all workers' jobs:
    #
    #   assert_equal 0, Sidekiq::Extensions::DelayedMailer.jobs.size
    #   assert_equal 0, Sidekiq::Extensions::DelayedModel.jobs.size
    #
    #   MyMailer.delay.send_welcome_email('foo@example.com')
    #   MyModel.delay.do_something_hard
    #
    #   assert_equal 1, Sidekiq::Extensions::DelayedMailer.jobs.size
    #   assert_equal 1, Sidekiq::Extensions::DelayedModel.jobs.size
    #
    #   Sidekiq::Worker.clear_all # or .drain_all
    #
    #   assert_equal 0, Sidekiq::Extensions::DelayedMailer.jobs.size
    #   assert_equal 0, Sidekiq::Extensions::DelayedModel.jobs.size
    #
    # This can be useful to make sure jobs don't linger between tests:
    #
    #   RSpec.configure do |config|
    #     config.before(:each) do
    #       Sidekiq::Worker.clear_all
    #     end
    #   end
    #
    # or for acceptance testing, i.e. with cucumber:
    #
    #   AfterStep do
    #     Sidekiq::Worker.drain_all
    #   end
    #
    #   When I sign up as "foo@example.com"
    #   Then I should receive a welcome email to "foo@example.com"
    #
    module ClassMethods

      # Queue for this worker
      def queue
        self.sidekiq_options["queue"].to_s
      end

      # Jobs queued for this worker
      def jobs
        Queues.jobs[queue].select { |job| job["class"] == self.to_s }
      end

      # Clear all jobs for this worker
      def clear
        Queues.jobs[queue].clear
      end

      # Drain and run all jobs for this worker
      def drain
        while jobs.any?
          next_job = jobs.first
          Queues.jobs[queue].delete_if { |job| job["jid"] == next_job["jid"] }
          process_job(next_job)
        end
      end

      # Pop out a single job and perform it
      def perform_one
        raise(EmptyQueueError, "perform_one called with empty job queue") if jobs.empty?
        next_job = jobs.first
        Queues.jobs[queue].delete_if { |job| job["jid"] == next_job["jid"] }
        process_job(next_job)
      end

      def process_job(job)
        worker = new
        worker.jid = job['jid']
        worker.bid = job['bid'] if worker.respond_to?(:bid=)
        Sidekiq::Testing.server_middleware.invoke(worker, job, job['queue']) do
          execute_job(worker, job['args'])
        end
      end

      def execute_job(worker, args)
        worker.perform(*args)
      end
    end

    class << self
      def jobs # :nodoc:
        Queues.jobs.values.flatten
      end

      # Clear all queued jobs across all workers
      def clear_all
        Queues.clear_all
      end

      # Drain all queued jobs across all workers
      def drain_all
        while jobs.any?
          worker_classes = jobs.map { |job| job["class"] }.uniq

          worker_classes.each do |worker_class|
            worker_class.constantize.drain
          end
        end
      end
    end
  end
end
