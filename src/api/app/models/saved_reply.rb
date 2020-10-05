class SavedReply < ApplicationRecord
  belongs_to :user

  after_commit :invalidate_cache

  validates :name, presence: true
  validates :body, presence: true

  def self.for_user(user, force: false)
    Rails.cache.fetch([name, user.id], force: force) do
      user.saved_replies.select(:id, :name)
    end
  end

  private

  def invalidate_cache
    self.class.for_user(user, force: true)
  end
end

# == Schema Information
#
# Table name: saved_replies
#
#  id         :integer          not null, primary key
#  body       :text(65535)      not null
#  name       :string(255)      not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  user_id    :integer          not null, indexed
#
# Indexes
#
#  index_saved_replies_on_user_id  (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
