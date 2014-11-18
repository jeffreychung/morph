require 'spec_helper'

describe TurbotDockerRunner do
  before do
    @runner = TurbotDockerRunner.new('test_bot', 3, 123)
  end

  describe '#repo_path' do
    it 'is correct' do
      expect(@runner.repo_path).to eq('db/scrapers/repo/t/test_bot')
    end
  end

  describe '#data_path' do
    it 'is correct' do
      expect(@runner.data_path).to eq('db/scrapers/data/t/test_bot')
    end
  end

  describe '#output_path' do
    it 'is correct' do
      expect(@runner.output_path).to eq('db/scrapers/output/non-draft/t/test_bot/123')
    end
  end
end

