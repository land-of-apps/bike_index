require "rails_helper"

RSpec.describe RecoveryDisplay, type: :model do
  describe "stolen_record" do
    let!(:recovery_display) { FactoryBot.create(:recovery_display_with_stolen_record) }
    it "finds the stolen_record" do
      recovery_display.reload
      expect(recovery_display.stolen_record).to be_present
    end
  end
  describe "set_time" do
    it "sets time from input" do
      recovery_display = RecoveryDisplay.new(date_input: "04-27-1999")
      recovery_display.set_time
      expect(recovery_display.date_recovered).to eq(DateTime.strptime("04-27-1999 06", "%m-%d-%Y %H"))
    end
    it "sets time if no time" do
      recovery_display = RecoveryDisplay.new
      recovery_display.set_time
      expect(recovery_display.date_recovered).to be > Time.current - 5.seconds
    end
    it "has before_validation_callback_method defined" do
      expect(RecoveryDisplay._validation_callbacks.select { |cb| cb.kind.eql?(:before) }.map(&:raw_filter).include?(:set_time)).to eq(true)
    end
  end

  describe "from_stolen_record" do
    it "doesn't break if stolen record isn't present" do
      recovery_display = RecoveryDisplay.new
      recovery_display.from_stolen_record(69)
      expect(recovery_display.errors).not_to be_present
    end
    it "sets attrs from stolen record" do
      t = Time.current
      stolen_record = FactoryBot.create(:stolen_record_recovered, date_recovered: t, recovered_description: "stuff", current: false)
      recovery_display = RecoveryDisplay.new
      recovery_display.from_stolen_record(stolen_record.id)
      expect(recovery_display.quote).to eq("stuff")
      expect(recovery_display.date_recovered).to be > Time.current - 5.seconds
      expect(recovery_display.stolen_record_id).to eq(stolen_record.id)
    end
    it "sets name from stolen record" do
      user = FactoryBot.create(:user, name: "somebody special")
      ownership = FactoryBot.create(:ownership, creator: user, user: user)
      stolen_record = FactoryBot.create(:stolen_record, bike: ownership.bike)
      recovery_display = RecoveryDisplay.new
      recovery_display.from_stolen_record(stolen_record.id)
      expect(recovery_display.quote_by).to eq("somebody special")
    end
  end
end
