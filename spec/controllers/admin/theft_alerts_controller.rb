require "rails_helper"

RSpec.describe Admin::TheftAlertsController, type: :controller do
  include_context :logged_in_as_super_admin
  let(:stolen_record) { FactoryBot.create(:stolen_record_recovered) }
  let(:bike) { stolen_record.bike }
  let!(:theft_alert) { FactoryBot.create(:theft_alert, stolen_record: stolen_record) }
  describe "update" do
    it "sends an email when status is updated" do
      put :update, id: theft_alert.id, status: "active"
      expect(response.status).to eq(200)
    end
  end
end