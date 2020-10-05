FactoryBot.define do
  factory :saved_reply do
    name { 'My Saved Reply' }
    body { 'My saved reply content goes here...' }
    user
  end
end
