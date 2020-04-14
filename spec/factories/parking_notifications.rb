FactoryBot.define do
  factory :parking_notification do
    bike { FactoryBot.create(:bike) }
    user { FactoryBot.create(:user) }
    kind { "parked_incorrectly_notification" }

    latitude { 40.7143528 }
    longitude { -74.0059731 }

    factory :parking_notification_organized do
      organization { FactoryBot.create(:organization_with_paid_features, enabled_feature_slugs: %w[parking_notifications impound_bikes]) }
      user { FactoryBot.create(:organization_member, organization: organization) }

      factory :unregistered_parking_notification do
        transient do
          ownership { FactoryBot.create(:ownership, creator: user, bike: bike) }
        end
        bike { FactoryBot.create(:bike_organized, creator: user, organization: organization, status: "unregistered_parking_notification") }
        after(:create) do |parking_notification, evaluator|
          evaluator.ownership.save
          parking_notification.bike.update_attributes(marked_user_hidden: true)
        end
      end
    end
  end
end