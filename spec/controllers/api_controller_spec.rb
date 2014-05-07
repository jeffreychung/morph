require 'spec_helper'

describe ApiController do
  let(:user) { create(:user, nickname: "mlandauer") }
  let(:organization) do
    o = create(:organization, nickname: "org")
    o.users << user
    o
  end

  describe '#create_from_git' do
    before :each do
      sign_in user
    end

    it 'should error if the git url is not parseable' do
      post :create_from_git, git_url: "asdasd"
      assigns(:scraper).errors[:git_url].should == ['is not parseable']
    end

    it 'should create a scraper if it is parseable' do
      git_url = "git@git.opencorporates.internal:seb/silly-bot.git"
      Scraper.any_instance.should_receive(:synchronise_repo)
      post :create_from_git, git_url: git_url
      assigns(:scraper).name.should == "silly-bot"
      assigns(:scraper).git_url.should == git_url
    end
  end
end
