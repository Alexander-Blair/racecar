# frozen_string_literal: true

require "securerandom"
require "racecar/cli"
require "racecar/ctl"

class NoSubsConsumer < Racecar::Consumer
  def process(message); end
end

class NoProcessConsumer < Racecar::Consumer
  subscribes_to 'some-topic'
end

RSpec.describe "running a Racecar consumer", type: :integration do
  context "when an error occurs trying to start the runner" do
    context "when there are no subscriptions, and no concurrency" do
      it 'raises an exception' do
        expect do
          Racecar::Cli.new(["NoSubsConsumer"]).run
        end.to raise_error(ArgumentError)
      end
    end

    context "when there are no subscriptions, and concurrency" do
      before { Racecar.configure { |c| c.max_concurrency = 3 } }

      it 'raises an exception' do
        expect do
          Racecar::Cli.new(["NoSubsConsumer"]).run
        end.to raise_error(ArgumentError)
      end
    end

    context "when there is no process method, and no concurrency" do
      it 'raises an exception' do
        expect do
          Racecar::Cli.new(["NoProcessConsumer"]).run
        end.to raise_error(NotImplementedError)
      end
    end

    context "when there is no process method, and concurrency" do
      before { Racecar.configure { |c| c.max_concurrency = 3 } }

      it 'raises an exception' do
        expect do
          Racecar::Cli.new(["NoProcessConsumer"]).run
        end.to raise_error(NotImplementedError)
      end
    end
  end

  context "when the runner starts successfully" do
    let(:input_topic) { generate_input_topic_name }
    let(:output_topic) { generate_output_topic_name }
    let(:mock_echo_consumer_class) do
      Class.new(Racecar::Consumer) do
        class << self
          attr_accessor :output_topic
        end

        def process(message)
          produce message.value, key: message.key, topic: self.class.output_topic
          deliver!
        end
      end
    end

    let(:run_in_background!) do
      Thread.new do
        Thread.current.abort_on_exception = true
        Racecar::Cli.new([consumer_class.name.to_s]).run
      end
    end

    before do
      Racecar.configure { |c| c.max_concurrency = concurrency }

      create_topic(topic: input_topic, partitions: topic_partitions)

      consumer_class.subscribes_to(input_topic)
      consumer_class.output_topic = output_topic

      rdkafka_consumer.subscribe(output_topic)

      publish_messages!(input_topic, input_messages)

      run_in_background!
    end

    after { Process.kill('INT', 0) }

    after(:all) { delete_all_test_topics }

    context "for a single threaded consumer" do
      let(:consumer_class) do
        class EchoConsumer1 < mock_echo_consumer_class
          self.group_id = "echo-consumer-1"
        end
        EchoConsumer1
      end
      let(:input_messages) { [{ payload: 'hello', key: 'greetings', partition: nil }] }
      let(:topic_partitions) { 1 }
      let(:concurrency) { 1 }

      it "works" do
        wait_for_messages(topic: input_topic, expected_message_count: 1)

        message = incoming_messages.first

        expect(message).not_to be_nil
        expect(message.topic).to eq output_topic
        expect(message.payload).to eq "hello"
        expect(message.key).to eq "greetings"
      end
    end

    context "when running concurrent consumers" do
      let(:input_messages) do
        [
          { payload: 'message-0', partition: 0, key: 'a' },
          { payload: 'message-1', partition: 1, key: 'a' },
          { payload: 'message-2', partition: 2, key: 'a' },
          { payload: 'message-3', partition: 3, key: 'a' },
          { payload: 'message-4', partition: 4, key: 'a' },
          { payload: 'message-5', partition: 5, key: 'a' }
        ]
      end

      context "when partitions exceed concurrency" do
        let(:topic_partitions) { 6 }
        let(:concurrency) { 3 }
        let(:consumer_class) do
          class EchoConsumer2 < mock_echo_consumer_class
            self.group_id = "echo-consumer-2"
          end
          EchoConsumer2
        end

        it "assigns partitions to all concurrent consumers" do
          wait_for_assignments(
            group_id: "echo-consumer-2",
            topic: input_topic,
            expected_members_count: concurrency
          )

          wait_for_messages(topic: input_topic, expected_message_count: input_messages.count)

          expect(incoming_messages.map(&:topic).uniq).to eq([output_topic])
          expect(incoming_messages.map(&:payload))
            .to match_array(input_messages.map { |m| m[:payload] })
        end
      end

      context "when the concurrency exceeds the number of partitions" do
        let(:consumer_class) do
          class EchoConsumer3 < mock_echo_consumer_class
            self.group_id = "echo-consumer-3"
          end
          EchoConsumer3
        end
        let(:topic_partitions) { 3 }
        let(:concurrency) { 5 }
        let(:input_messages) do
          [
            { payload: 'message-0', partition: 0, key: 'a' },
            { payload: 'message-1', partition: 0, key: 'a' },
            { payload: 'message-2', partition: 1, key: 'a' },
            { payload: 'message-3', partition: 1, key: 'a' },
            { payload: 'message-4', partition: 2, key: 'a' },
            { payload: 'message-5', partition: 2, key: 'a' }
          ]
        end

        it "assigns all the consumers that it can, up to the total number of partitions" do
          wait_for_assignments(
            group_id: "echo-consumer-3",
            topic: input_topic,
            expected_members_count: topic_partitions
          )

          wait_for_messages(topic: input_topic, expected_message_count: input_messages.count)

          expect(incoming_messages.count).to eq(6)
          expect(incoming_messages.map(&:topic).uniq).to eq([output_topic])
          expect(incoming_messages.map(&:payload))
            .to match_array(input_messages.map { |m| m[:payload] })
        end
      end
    end
  end
end
