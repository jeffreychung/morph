require 'runner'

describe Runner do
  before do
    @runner = Runner.new('test_bot', 'draft', 123)
  end

  describe '#handle_stdout' do
    it 'buffers correctly' do
      expect(@runner).to receive(:handle_stdout_line).exactly(4).times
      output = ({:foo => 'bar'}.to_json + "\n") * 4
      n = 0
      while n <= output.size
        fragment = output[n..n+10]
        @runner.handle_stdout(fragment)
        n += 10
      end
    end
  end
end
