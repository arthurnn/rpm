# encoding: utf-8
# This file is distributed under New Relic's license terms.
# See https://github.com/newrelic/rpm/blob/master/LICENSE for complete details.

require File.expand_path(File.join(File.dirname(__FILE__),'..','..','test_helper'))

class NewRelic::Agent::TransactionSamplerTest < Test::Unit::TestCase

  module MockGCStats

    def time
      return 0 if @@values.empty?
      raise "too many calls" if @@index >= @@values.size
      @@curtime ||= 0
      @@curtime += (@@values[@@index] * 1e09).to_i
      @@index += 1
      @@curtime
    end

    def self.mock_values= array
      @@values = array
      @@index = 0
    end

  end

  def setup
    Thread::current[:record_sql] = nil
    agent = NewRelic::Agent.instance
    stats_engine = NewRelic::Agent::StatsEngine.new
    agent.stubs(:stats_engine).returns(stats_engine)
    @sampler = NewRelic::Agent::TransactionSampler.new
    stats_engine.transaction_sampler = @sampler
    @old_sampler = NewRelic::Agent.instance.transaction_sampler
    NewRelic::Agent.instance.instance_variable_set(:@transaction_sampler, @sampler)
    @test_config = { :'transaction_tracer.enabled' => true }
    NewRelic::Agent.config.apply_config(@test_config)
    @txn = stub('txn', :name => '/path', :custom_parameters => {})
  end

  def teardown
    super
    Thread.current[:transaction_sample_builder] = nil
    NewRelic::Agent.config.remove_config(@test_config)
    NewRelic::Agent.instance.instance_variable_set(:@transaction_sampler, @old_sampler)
  end

  def test_initialize
    defaults =      {
      :samples => [],
      :harvest_count => 0,
      :max_samples => 100,
      :random_sample => nil,
    }
    defaults.each do |variable, default_value|
      assert_equal(default_value, @sampler.instance_variable_get('@' + variable.to_s))
    end

    lock = @sampler.instance_variable_get('@samples_lock')
    assert(lock.is_a?(Mutex), "Samples lock should be a mutex, is: #{lock.inspect}")
  end

  def test_current_sample_id_default
    builder = mock('builder')
    builder.expects(:sample_id).returns(11111)
    @sampler.expects(:builder).returns(builder)
    assert_equal(11111, @sampler.current_sample_id)
  end

  def test_current_sample_id_no_builder
    @sampler.expects(:builder).returns(nil)
    assert_equal(nil, @sampler.current_sample_id)
  end

  def test_sampling_rate_equals_default
    @sampler.sampling_rate = 1
    assert_equal(1, @sampler.instance_variable_get('@sampling_rate'))
    # rand(1) is always zero, so we can be sure here
    assert_equal(0, @sampler.instance_variable_get('@harvest_count'))
  end

  def test_sampling_rate_equals_with_a_float
    @sampler.sampling_rate = 5.5
    assert_equal(5, @sampler.instance_variable_get('@sampling_rate'))
    harvest_count = @sampler.instance_variable_get('@harvest_count')
    assert((0..4).include?(harvest_count), "should be in the range 0..4")
  end

  def test_notice_first_scope_push_default
    @sampler.expects(:start_builder).with(100.0)
    @sampler.notice_first_scope_push(Time.at(100))
  end

  def test_notice_first_scope_push_disabled
    with_config(:'transaction_tracer.enabled' => false,
                :developer_mode => false) do
      @sampler.expects(:start_builder).never
      @sampler.notice_first_scope_push(Time.at(100))
    end
  end

  def test_notice_push_scope_no_builder
    @sampler.expects(:builder)
    assert_equal(nil, @sampler.notice_push_scope())
  end

  def test_notice_push_scope_with_builder
    with_config(:developer_mode => false) do
      builder = mock('builder')
      builder.expects(:trace_entry).with(100.0)
      @sampler.expects(:builder).returns(builder).twice
      @sampler.notice_push_scope(Time.at(100))
    end
  end

  def test_notice_push_scope_in_dev_mode
    builder = mock('builder')
    builder.expects(:trace_entry).with(100.0)
    @sampler.expects(:builder).returns(builder).twice
    @sampler.expects(:capture_segment_trace)

    @sampler.notice_push_scope(Time.at(100))
  end

  def test_scope_depth_no_builder
    @sampler.expects(:builder).returns(nil)
    assert_equal(0, @sampler.scope_depth, "should default to zero with no builder")
  end

  def test_scope_depth_with_builder
    builder = mock('builder')
    builder.expects(:scope_depth).returns('scope_depth')
    @sampler.expects(:builder).returns(builder).twice

    assert_equal('scope_depth', @sampler.scope_depth, "should delegate scope depth to the builder")
  end

  def test_notice_pop_scope_no_builder
    @sampler.expects(:builder).returns(nil)
    assert_equal(nil, @sampler.notice_pop_scope('a scope', Time.at(100)))
  end

  def test_notice_pop_scope_with_frozen_sample
    builder = mock('builder')
    sample = mock('sample')
    builder.expects(:sample).returns(sample)
    sample.expects(:frozen?).returns(true)
    @sampler.expects(:builder).returns(builder).twice

    assert_raise(RuntimeError) do
      @sampler.notice_pop_scope('a scope', Time.at(100))
    end
  end

  def test_notice_pop_scope_builder_delegation
    builder = mock('builder')
    builder.expects(:trace_exit).with('a scope', 100.0)
    sample = mock('sample')
    builder.expects(:sample).returns(sample)
    sample.expects(:frozen?).returns(false)
    @sampler.expects(:builder).returns(builder).times(3)

    @sampler.notice_pop_scope('a scope', Time.at(100))
  end

  def test_notice_scope_empty_no_builder
    @sampler.expects(:builder).returns(nil)
    assert_equal(nil, @sampler.notice_scope_empty(@txn))
  end

  def test_notice_scope_empty_ignored_transaction
    builder = mock('builder')
    # the builder should be cached, so only called once
    @sampler.expects(:builder).returns(builder).once

    builder.expects(:finish_trace).with(100.0, {})

    @sampler.expects(:clear_builder)

    builder.expects(:ignored?).returns(true)
    builder.expects(:set_transaction_name).returns(true)

    assert_equal(nil, @sampler.notice_scope_empty(@txn, Time.at(100)))
  end

  def test_notice_scope_empty_with_builder
    builder = mock('builder')
    @sampler.stubs(:builder).returns(builder)


    builder.expects(:finish_trace).with(100.0, {})
    @sampler.expects(:clear_builder)

    builder.expects(:ignored?).returns(false)
    builder.expects(:set_transaction_info).returns(true)
    builder.expects(:set_transaction_name).returns(true)

    sample = mock('sample')
    builder.expects(:sample).returns(sample)
    @sampler.expects(:store_sample).with(sample)

    @sampler.notice_transaction(nil, {})
    @sampler.notice_scope_empty(@txn, Time.at(100))

    assert_equal(sample, @sampler.instance_variable_get('@last_sample'))
  end

  def test_store_random_sample_no_random_sampling
    with_config(:'transaction_tracer.random_sample' => false) do
      assert_equal(nil, @sampler.instance_variable_get('@random_sample'))
      @sampler.store_random_sample(mock('sample'))
      assert_equal(nil, @sampler.instance_variable_get('@random_sample'))
    end
  end

  def test_store_random_sample_random_sampling
    with_config(:'transaction_tracer.random_sample' => true) do
      sample = mock('sample')
      assert_equal(nil, @sampler.instance_variable_get('@random_sample'))
      @sampler.store_random_sample(sample)
      assert_equal(sample, @sampler.instance_variable_get('@random_sample'))
    end
  end

  def test_store_sample_for_developer_mode_in_dev_mode
    sample = mock('sample')
    @sampler.expects(:truncate_samples)
    @sampler.store_sample_for_developer_mode(sample)
    assert_equal([sample], @sampler.instance_variable_get('@samples'))
  end

  def test_store_sample_for_developer_mode_no_dev
    with_config(:developer_mode => false) do
      sample = mock('sample')
      @sampler.store_sample_for_developer_mode(sample)
      assert_equal([], @sampler.instance_variable_get('@samples'))
    end
  end

  def test_store_slowest_sample_new_is_slowest
    old_sample = stub('old_sample', :duration => 3.0, :threshold => 1.0)
    new_sample = stub('new_sample', :duration => 4.0, :threshold => 1.0)
    @sampler.instance_eval { @slowest_sample = old_sample }

    @sampler.store_slowest_sample(new_sample)

    assert_equal(new_sample, @sampler.instance_variable_get('@slowest_sample'))
  end

  def test_store_slowest_sample_not_slowest
    old_sample = mock('old_sample')
    new_sample = mock('new_sample')
    @sampler.instance_eval { @slowest_sample = old_sample }
    @sampler.expects(:slowest_sample?).with(old_sample, new_sample).returns(false)

    @sampler.store_slowest_sample(new_sample)

    assert_equal(old_sample, @sampler.instance_variable_get('@slowest_sample'))
  end

  def test_store_slowest_sample_does_not_store_if_faster_than_threshold
    old_sample = stub('old_sample', :duration => 1.0, :threshold => 0.5)
    new_sample = stub('new_sample', :duration => 2.0, :threshold => 4.0)
    @sampler.instance_eval { @slowest_sample = old_sample }
    @sampler.store_slowest_sample(new_sample)

    assert_equal(old_sample, @sampler.instance_variable_get('@slowest_sample'))
  end

  def test_slowest_sample_no_sample
    old_sample = nil
    new_sample = mock('new_sample')
    assert_equal(true, @sampler.slowest_sample?(old_sample, new_sample))
  end

  def test_slowest_sample_faster_sample
    old_sample = mock('old_sample')
    new_sample = mock('new_sample')
    old_sample.expects(:duration).returns(1.0)
    new_sample.expects(:duration).returns(0.5)
    assert_equal(false, @sampler.slowest_sample?(old_sample, new_sample))
  end

  def test_slowest_sample_slower_sample
    old_sample = mock('old_sample')
    new_sample = mock('new_sample')
    old_sample.expects(:duration).returns(0.5)
    new_sample.expects(:duration).returns(1.0)
    assert_equal(true, @sampler.slowest_sample?(old_sample, new_sample))
  end

  def test_truncate_samples_no_samples
    @sampler.instance_eval { @max_samples = 10 }
    @sampler.instance_eval { @samples = [] }
    @sampler.truncate_samples
    assert_equal([], @sampler.instance_variable_get('@samples'))
  end

  def test_truncate_samples_equal_samples
    @sampler.instance_eval { @max_samples = 2 }
    @sampler.instance_eval { @samples = [1, 2] }
    @sampler.truncate_samples
    assert_equal([1, 2], @sampler.instance_variable_get('@samples'))
  end

  def test_truncate_samples_extra_samples
    @sampler.instance_eval { @max_samples = 2 }
    @sampler.instance_eval { @samples = [1, 2, 3] }
    @sampler.truncate_samples
    assert_equal([2, 3], @sampler.instance_variable_get('@samples'))
  end

  def test_ignore_transaction_no_builder
    @sampler.expects(:builder).returns(nil).once
    @sampler.ignore_transaction
  end

  def test_ignore_transaction_with_builder
    builder = mock('builder')
    builder.expects(:ignore_transaction)
    @sampler.expects(:builder).returns(builder).twice
    @sampler.ignore_transaction
  end

  def test_notice_profile_no_builder
    @sampler.expects(:builder).returns(nil).once
    @sampler.notice_profile(nil)
  end

  def test_notice_profile_with_builder
    profile = mock('profile')
    builder = mock('builder')
    @sampler.expects(:builder).returns(builder).twice
    builder.expects(:set_profile).with(profile)

    @sampler.notice_profile(profile)
  end

  def test_notice_transaction_cpu_time_no_builder
    @sampler.expects(:builder).returns(nil).once
    @sampler.notice_transaction_cpu_time(0.0)
  end

  def test_notice_transaction_cpu_time_with_builder
    cpu_time = mock('cpu_time')
    builder = mock('builder')
    @sampler.expects(:builder).returns(builder).twice
    builder.expects(:set_transaction_cpu_time).with(cpu_time)

    @sampler.notice_transaction_cpu_time(cpu_time)
  end

  def test_notice_extra_data_no_builder
    @sampler.expects(:builder).returns(nil).once
    @sampler.send(:notice_extra_data, nil, nil, nil)
  end

  def test_notice_extra_data_no_segment
    builder = mock('builder')
    @sampler.expects(:builder).returns(builder).twice
    builder.expects(:current_segment).returns(nil)
    @sampler.send(:notice_extra_data, nil, nil, nil)
  end

  def test_notice_extra_data_with_segment_no_old_message_no_config_key
    key = :a_key
    builder = mock('builder')
    segment = mock('segment')
    @sampler.expects(:builder).returns(builder).twice
    builder.expects(:current_segment).returns(segment)
    segment.expects(:[]).with(key).returns(nil)
    @sampler.expects(:append_new_message).with(nil, 'a message').returns('a message')
    NewRelic::Agent::TransactionSampler.expects(:truncate_message) \
      .with('a message').returns('truncated_message')
    segment.expects(:[]=).with(key, 'truncated_message')
    @sampler.expects(:append_backtrace).with(segment, 1.0)
    @sampler.send(:notice_extra_data, 'a message', 1.0, key)
  end

  def test_truncate_message_short_message
    message = 'a message'
    assert_equal(message, NewRelic::Agent::TransactionSampler.truncate_message(message))
  end

  def test_truncate_message_long_message
    message = 'a' * 16384
    truncated_message = NewRelic::Agent::TransactionSampler.truncate_message(message)
    assert_equal(16384, truncated_message.length)
    assert_equal('a' * 16381 + '...', truncated_message)
  end

  def test_append_new_message_no_old_message
    old_message = nil
    new_message = 'a message'
    assert_equal(new_message, @sampler.append_new_message(old_message, new_message))
  end

  def test_append_new_message_with_old_message
    old_message = 'old message'
    new_message = ' a message'
    assert_equal("old message;\n a message", @sampler.append_new_message(old_message, new_message))
  end

  def test_append_backtrace_under_duration
    with_config(:'transaction_tracer.stack_trace_threshold' => 2.0) do
      segment = mock('segment')
      segment.expects(:[]=).with(:backtrace, any_parameters).never
      @sampler.append_backtrace(mock('segment'), 1.0)
    end
  end

  def test_append_backtrace_over_duration
    with_config(:'transaction_tracer.stack_trace_threshold' => 2.0) do
      segment = mock('segment')
      # note the mocha expectation matcher - you can't hardcode a
      # backtrace so we match on any string, which should be okay.
      segment.expects(:[]=).with(:backtrace, instance_of(String))
      @sampler.append_backtrace(segment, 2.5)
    end
  end

  def test_notice_sql_recording_sql
    Thread.current[:record_sql] = true
    @sampler.expects(:notice_extra_data).with('some sql', 1.0, :sql, 'a config', :connection_config)
    @sampler.notice_sql('some sql', 'a config', 1.0)
  end

  def test_notice_sql_not_recording
    Thread.current[:record_sql] = false
    @sampler.expects(:notice_extra_data).with('some sql', 1.0, :sql, 'a config', :connection_config).never # <--- important
    @sampler.notice_sql('some sql', 'a config', 1.0)
  end

  def test_notice_nosql
    @sampler.expects(:notice_extra_data).with('a key', 1.0, :key)
    @sampler.notice_nosql('a key', 1.0)
  end

  def test_harvest_when_disabled
    with_config(:'transaction_tracer.enabled' => false,
                :developer_mode => false) do
      assert_equal([], @sampler.harvest)
    end
  end

  def test_harvest_defaults
    # making sure the sampler clears out the old samples
    @sampler.instance_eval do
      @slowest_sample = 'a sample'
      @random_sample = 'a sample'
      @last_sample = 'a sample'
    end

    @sampler.expects(:add_samples_to).with([]).returns([])

    assert_equal([], @sampler.harvest)

    # make sure the samples have been cleared
    assert_equal(nil, @sampler.instance_variable_get('@slowest_sample'))
    assert_equal(nil, @sampler.instance_variable_get('@random_sample'))
    assert_equal(nil, @sampler.instance_variable_get('@last_sample'))
  end

  def test_harvest_with_previous_samples
    with_config(:'transaction_tracer.limit_segments' => 2000) do
      sample = mock('sample')
      @sampler.expects(:add_samples_to).with([sample]).returns([sample])
      sample.expects(:truncate).with(2000)
      assert_equal([sample], @sampler.harvest([sample]))
    end
  end

  def test_add_random_sample_to_not_random_sampling
    @sampler.instance_eval { @random_sampling = false }
    result = []
    @sampler.add_random_sample_to(result)
    assert_equal([], result, "should not add anything to the array if we are not random sampling")
  end

  def test_add_random_sample_to_no_random_sample
    @sampler.instance_eval { @random_sampling = true }
    @sampler.instance_eval {
      @harvest_count = 1
      @sampling_rate = 2
      @random_sample = nil
    }
    result = []
    @sampler.add_random_sample_to(result)
    assert_equal([], result, "should not add sample to the array when it is nil")
  end

  def test_add_random_sample_to_not_active
    @sampler.instance_eval { @random_sampling = true }
    sample = mock('sample')
    @sampler.instance_eval {
      @harvest_count = 4
      @sampling_rate = 40 # 4 % 40 = 4, so the sample should not be added
      @random_sample = sample
    }
    result = []
    @sampler.add_random_sample_to(result)
    assert_equal([], result, "should not add samples to the array when harvest count is not moduli sampling rate")
  end

  def test_add_random_sample_to_activated
    with_config(:'transaction_tracer.random_sample' => true, :sample_rate => 1) do
      sample = mock('sample')
      @sampler.instance_eval {
        @harvest_count = 3
        @random_sample = sample
      }
      result = []
      @sampler.add_random_sample_to(result)
      assert_equal([sample], result, "should add the random sample to the array")
    end
  end

  def test_add_random_sample_to_sampling_rate_zero
    @sampler.instance_eval { @random_sampling = true }
    sample = mock('sample')
    @sampler.instance_eval {
      @harvest_count = 3
      @sampling_rate = 0
      @random_sample = sample
    }
    result = []
    @sampler.add_random_sample_to(result)
    assert_equal([], result, "should not add the sample to the array")
  end

  def test_add_samples_to_no_data
    result = []
    @sampler.instance_eval { @slowest_sample = nil }
    @sampler.expects(:add_random_sample_to).with([])
    assert_equal([], @sampler.add_samples_to(result))
  end

  def test_add_samples_to_one_result
    sample = mock('sample')
    sample.expects(:duration).returns(1).at_least_once
    sample.stubs(:force_persist).returns(false)
    result = [sample]
    @sampler.instance_eval { @slowest_sample = nil }
    @sampler.expects(:add_random_sample_to).with([sample])
    assert_equal([sample], @sampler.add_samples_to(result))
  end

  def test_add_samples_to_adding_slowest
    sample = mock('sample')
    sample.expects(:duration).returns(2.5).at_least_once
    result = []
    @sampler.instance_variable_set(:@slowest_sample, sample)
    @sampler.expects(:add_random_sample_to).with([sample])
    with_config(:'transaction_tracer.transaction_threshold' => 2) do
      assert_equal([sample], @sampler.add_samples_to(result))
    end
  end

  def test_add_samples_to_two_sample_enter_one_sample_leave
    slower_sample = mock('slower')
    slower_sample.expects(:duration).returns(10.0).at_least_once
    faster_sample = mock('faster')
    faster_sample.expects(:duration).returns(5.0).at_least_once
    faster_sample.stubs(:force_persist).returns(false)
    result = [faster_sample]
    @sampler.instance_eval { @slowest_sample = slower_sample }
    @sampler.expects(:add_random_sample_to).with([slower_sample])
    assert_equal([slower_sample], @sampler.add_samples_to(result))
  end

  def test_add_samples_to_keep_older_slower_sample
    slower_sample = mock('slower')
    slower_sample.expects(:duration).returns(10.0).at_least_once
    slower_sample.stubs(:force_persist).returns(false)

    faster_sample = mock('faster')
    faster_sample.expects(:duration).returns(5.0).at_least_once
    result = [slower_sample]
    @sampler.instance_eval { @slowest_sample = faster_sample }
    @sampler.expects(:add_random_sample_to).with([slower_sample])
    assert_equal([slower_sample], @sampler.add_samples_to(result))
  end

  def test_keep_force_persist
    sample1 = mock('regular')
    sample1.stubs(:duration).returns(10)
    sample1.stubs(:force_persist).returns(false)

    sample2 = mock('force_persist')
    sample2.stubs(:duration).returns(1)
    sample2.stubs(:force_persist).returns(true)

    result = @sampler.add_samples_to([sample1,sample2])

    assert_equal 2, result.length
    assert_equal sample1, result[0]
    assert_equal sample2, result[1]
  end

  def test_start_builder_default
    Thread.current[:record_tt] = true
    NewRelic::Agent.expects(:is_execution_traced?).returns(true)
    @sampler.send(:start_builder)
    assert(Thread.current[:transaction_sample_builder] \
             .is_a?(NewRelic::Agent::TransactionSampleBuilder),
           "should set up a new builder by default")
  end

  def test_start_builder_disabled
    Thread.current[:transaction_sample_builder] = 'not nil.'
    with_config(:'transaction_tracer.enabled' => false,
                :developer_mode => false) do
      @sampler.send(:start_builder)
      assert_equal(nil, Thread.current[:transaction_sample_builder],
                   "should clear the transaction builder when disabled")
    end
  end

  def test_start_builder_dont_replace_existing_builder
    fake_builder = mock('transaction sample builder')
    Thread.current[:transaction_sample_builder] = fake_builder
    @sampler.send(:start_builder)
    assert_equal(fake_builder, Thread.current[:transaction_sample_builder],
                 "should not overwrite an existing transaction sample builder")
    Thread.current[:transaction_sample_builder] = nil
  end

  def test_builder
    Thread.current[:transaction_sample_builder] = 'shamalamadingdong, brother.'
    assert_equal('shamalamadingdong, brother.', @sampler.send(:builder),
                 'should return the value from the thread local variable')
    Thread.current[:transaction_sample_builder] = nil
  end

  def test_clear_builder
    Thread.current[:transaction_sample_builder] = 'shamalamadingdong, brother.'
    assert_equal(nil, @sampler.send(:clear_builder), 'should clear the thread local variable')
  end

  # Tests below this line are functional tests for the sampler, not
  # unit tests per se - some overlap with the tests above, but
  # generally usefully so

  def test_multiple_samples
    run_sample_trace
    run_sample_trace
    run_sample_trace
    run_sample_trace

    samples = @sampler.samples
    assert_equal 4, samples.length
    assert_equal "a", samples.first.root_segment.called_segments[0].metric_name
    assert_equal "a", samples.last.root_segment.called_segments[0].metric_name
  end

  def test_sample_tree
    with_config(:'transaction_tracer.transaction_threshold' => 0.0) do
      assert_equal 0, @sampler.scope_depth
      @sampler.notice_first_scope_push Time.now.to_f
      @sampler.notice_transaction(nil, {})
      @sampler.notice_push_scope

      @sampler.notice_push_scope
      @sampler.notice_pop_scope "b"

      @sampler.notice_push_scope
      @sampler.notice_push_scope
      @sampler.notice_pop_scope "d"
      @sampler.notice_pop_scope "c"

      @sampler.notice_pop_scope "a"
      @sampler.notice_scope_empty(@txn)
      sample = @sampler.harvest([]).first
      assert_equal "ROOT{a{b,c{d}}}", sample.to_s_compact
    end
  end

  def test_sample__gc_stats
    GC.extend MockGCStats
    # These are effectively Garbage Collects, detected each time GC.time is
    # called by the transaction sampler.  One time value in seconds for each call.
    MockGCStats.mock_values = [0,0,0,1,0,0,1,0,0,0,0,0,0,0,0]
    assert_equal 0, @sampler.scope_depth

    with_config(:'transaction_tracer.transaction_threshold' => 0.0) do
      @sampler.notice_first_scope_push Time.now.to_f
      @sampler.notice_transaction(nil, {})
      @sampler.notice_push_scope

      @sampler.notice_push_scope
      @sampler.notice_pop_scope "b"

      @sampler.notice_push_scope
      @sampler.notice_push_scope
      @sampler.notice_pop_scope "d"
      @sampler.notice_pop_scope "c"

      @sampler.notice_pop_scope "a"
      @sampler.notice_scope_empty(@txn)

      sample = @sampler.harvest([]).first
      assert_equal "ROOT{a{b,c{d}}}", sample.to_s_compact
    end
  ensure
    MockGCStats.mock_values = []
  end

  def test_sample_id
    run_sample_trace do
      assert((@sampler.current_sample_id && @sampler.current_sample_id != 0), @sampler.current_sample_id.to_s + ' should not be zero')
    end
  end


  # NB this test occasionally fails due to a GC during one of the
  # sample traces, for example. It's unfortunate, but we can't
  # reliably turn off GC on all versions of ruby under test
  def test_harvest_slowest
    with_config(:'transaction_tracer.transaction_threshold' => 0.0) do
      run_sample_trace(0,0.1)
      run_sample_trace(0,0.1)
      # two second duration
      run_sample_trace(0,2)
      run_sample_trace(0,0.1)
      run_sample_trace(0,0.1)

      slowest = @sampler.harvest(nil)[0]
      first_duration = slowest.duration
      assert((first_duration.round >= 2),
             "expected sample duration = 2, but was: #{slowest.duration.inspect}")

      # 1 second duration
      run_sample_trace(0,1)
      not_as_slow = @sampler.harvest(slowest)[0]
      assert((not_as_slow == slowest), "Should re-harvest the same transaction since it should be slower than the new transaction - expected #{slowest.inspect} but got #{not_as_slow.inspect}")

      run_sample_trace(0,10)

      new_slowest = @sampler.harvest(slowest)[0]
      assert((new_slowest != slowest), "Should not harvest the same trace since the new one should be slower")
      assert_equal(new_slowest.duration.round, 10, "Slowest duration must be = 10, but was: #{new_slowest.duration.inspect}")
    end
  end

  def test_prepare_to_send
    sample = with_config(:'transaction_tracer.transaction_threshold' => 0.0) do
      run_sample_trace { sleep 0.002 }
      @sampler.harvest(nil)[0]
    end

    ready_to_send = sample.prepare_to_send
    assert sample.duration == ready_to_send.duration

    assert ready_to_send.start_time.is_a?(Time)
  end

  def test_multithread
    threads = []

    5.times do
      t = Thread.new(@sampler) do |the_sampler|
        @sampler = the_sampler
        10.times do
          run_sample_trace { sleep 0.0001 }
        end
      end

      threads << t
    end
    threads.each {|t| t.join }
  end

  def test_sample_with_parallel_paths
    with_config(:'transaction_tracer.transaction_threshold' => 0.0) do
      assert_equal 0, @sampler.scope_depth
      @sampler.notice_first_scope_push Time.now.to_f
      @sampler.notice_transaction(nil, {})
      @sampler.notice_push_scope

      assert_equal 1, @sampler.scope_depth

      @sampler.notice_pop_scope "a"
      @sampler.notice_scope_empty(@txn)

      assert_equal 0, @sampler.scope_depth

      @sampler.notice_first_scope_push Time.now.to_f
      @sampler.notice_transaction(nil, {})
      @sampler.notice_push_scope
      @sampler.notice_pop_scope "a"
      @sampler.notice_scope_empty(@txn)

      assert_equal 0, @sampler.scope_depth
      sample = @sampler.harvest(nil).first
      assert_equal "ROOT{a}", sample.to_s_compact
    end
  end

  def test_double_scope_stack_empty
    with_config(:'transaction_tracer.transaction_threshold' => 0.0) do
      @sampler.notice_first_scope_push Time.now.to_f
      @sampler.notice_transaction(nil, {})
      @sampler.notice_push_scope
      @sampler.notice_pop_scope "a"
      @sampler.notice_scope_empty(@txn)
      @sampler.notice_scope_empty(@txn)
      @sampler.notice_scope_empty(@txn)
      @sampler.notice_scope_empty(@txn)

      assert_not_nil @sampler.harvest(nil)[0]
    end
  end


  def test_record_sql_off
    @sampler.notice_first_scope_push Time.now.to_f

    Thread::current[:record_sql] = false

    @sampler.notice_sql("test", nil, 0)

    segment = @sampler.send(:builder).current_segment

    assert_nil segment[:sql]
  end

  def test_stack_trace__sql
    with_config(:'transaction_tracer.stack_trace_threshold' => 0) do
      @sampler.notice_first_scope_push Time.now.to_f
      @sampler.notice_sql("test", nil, 1)
      segment = @sampler.send(:builder).current_segment

      assert segment[:sql]
      assert segment[:backtrace]
    end
  end

  def test_stack_trace__scope
    with_config(:'transaction_tracer.stack_trace_threshold' => 0) do
      t = Time.now
      @sampler.notice_first_scope_push t.to_f
      @sampler.notice_push_scope((t+1).to_f)

      segment = @sampler.send(:builder).current_segment
      assert segment[:backtrace]
    end
  end

  def test_nil_stacktrace
    with_config(:'transaction_tracer.stack_trace_threshold' => 2) do
      @sampler.notice_first_scope_push Time.now.to_f
      @sampler.notice_sql("test", nil, 1)
      segment = @sampler.send(:builder).current_segment

      assert segment[:sql]
      assert_nil segment[:backtrace]
    end
  end

  def test_big_sql
    @sampler.notice_first_scope_push Time.now.to_f

    sql = "SADJKHASDHASD KAJSDH ASKDH ASKDHASDK JASHD KASJDH ASKDJHSAKDJHAS DKJHSADKJSAH DKJASHD SAKJDH SAKDJHS"

    len = 0
    while len <= 16384
      @sampler.notice_sql(sql, nil, 0)
      len += sql.length
    end

    segment = @sampler.send(:builder).current_segment

    sql = segment[:sql]

    assert sql.length <= 16384
  end

  def test_segment_obfuscated
    @sampler.notice_first_scope_push Time.now.to_f
    @sampler.notice_push_scope

    orig_sql = "SELECT * from Jim where id=66"

    @sampler.notice_sql(orig_sql, nil, 0)

    segment = @sampler.send(:builder).current_segment

    assert_equal orig_sql, segment[:sql]
    assert_equal "SELECT * from Jim where id=?", segment.obfuscated_sql
    @sampler.notice_pop_scope "foo"
  end

  def test_param_capture
    [true, false].each do |capture|
      with_config(:capture_params => capture) do
        tt = with_config(:'transaction_tracer.transaction_threshold' => 0.0) do
          @sampler.notice_first_scope_push Time.now.to_f
          @sampler.notice_transaction(nil, :param => 'hi')
          @sampler.notice_scope_empty(@txn)
          @sampler.harvest(nil)[0]
        end

        assert_equal (capture ? 1 : 0), tt.params[:request_params].length
      end
    end
  end

  def test_should_not_collect_segments_beyond_limit
    with_config(:'transaction_tracer.limit_segments' => 3) do
      run_sample_trace do
        @sampler.notice_push_scope
        @sampler.notice_sql("SELECT * FROM sandwiches WHERE bread = 'hallah'", nil, 0)
        @sampler.notice_push_scope
        @sampler.notice_sql("SELECT * FROM sandwiches WHERE bread = 'semolina'", nil, 0)
        @sampler.notice_pop_scope "a11"
        @sampler.notice_pop_scope "a1"
      end
      assert_equal 3, @sampler.samples[0].count_segments
    end
  end

  def test_renaming_current_segment_midflight
    @sampler.start_builder
    segment = @sampler.notice_push_scope
    segment.metric_name = 'External/www.google.com/Net::HTTP/GET'
    assert_nothing_raised do
      @sampler.notice_pop_scope( 'External/www.google.com/Net::HTTP/GET' )
    end
  end

  def test_adding_segment_parameters
    @sampler.start_builder
    @sampler.notice_push_scope
    @sampler.add_segment_parameters( :transaction_guid => '97612F92E6194080' )
    assert_equal '97612F92E6194080', @sampler.builder.current_segment[:transaction_guid]
  end

  class Dummy
    include ::NewRelic::Agent::Instrumentation::ControllerInstrumentation
    def run(n)
      n.times do
        perform_action_with_newrelic_trace("smile") do
        end
      end
    end
  end

  # TODO: this test seems to be destabilizing CI in a way that I don't grok.
  def sadly_do_not_test_harvest_during_transaction_safety
    n = 3000
    harvester = Thread.new do
      n.times { @sampler.harvest }
    end

    assert_nothing_raised { Dummy.new.run(n) }

    harvester.join
  end

  private

  def run_sample_trace(start = Time.now.to_f, stop = nil)
    @sampler.notice_transaction(nil, {})
    @sampler.notice_first_scope_push start
    @sampler.notice_push_scope
    @sampler.notice_sql("SELECT * FROM sandwiches WHERE bread = 'wheat'", nil, 0)
    @sampler.notice_push_scope
    @sampler.notice_sql("SELECT * FROM sandwiches WHERE bread = 'white'", nil, 0)
    yield if block_given?
    @sampler.notice_pop_scope "ab"
    @sampler.notice_push_scope
    @sampler.notice_sql("SELECT * FROM sandwiches WHERE bread = 'french'", nil, 0)
    @sampler.notice_pop_scope "ac"
    @sampler.notice_pop_scope "a"
    @sampler.notice_scope_empty(@txn, (stop || Time.now.to_f))
  end
end
