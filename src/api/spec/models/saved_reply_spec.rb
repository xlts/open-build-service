require 'rails_helper'

RSpec.describe SavedReply, type: :model do
  describe '#for_user' do
    subject(:for_user) { described_class.for_user(user) }

    let(:user) { create(:user) }

    let!(:user_saved_replies) do
      [
        create(:saved_reply, user: user, name: 'SR1'),
        create(:saved_reply, user: user, name: 'SR2'),
        create(:saved_reply, user: user, name: 'SR3')
      ]
    end

    let!(:other_user_saved_reply) do
      create(:saved_reply, user: create(:user))
    end

    def to_simple_array(saved_replies)
      saved_replies.map { |sr| [sr.id, sr.name] }
    end

    def read_from_cache(user_id)
      value = Rails.cache.read([described_class.name, user_id])
      to_simple_array(value) if value
    end

    before { Rails.cache.clear }

    it "returns the user's saved reply data" do
      expect(for_user).to contain_exactly(
        *described_class.where(
          id: user_saved_replies.map(&:id)
        ).select(:id, :name).to_a
      )
    end

    it 'caches the result' do
      expect do
        for_user
      end.to(
        change { read_from_cache(user.id) }.
        from(nil)
        .to(array_including(to_simple_array(user_saved_replies)))
      )
    end

    it 'recalculates the result when saved reply is updated or created' do
      expect do
        user_saved_replies.first.update!(name: 'Saved Reply 1')
      end.to(change { read_from_cache(user.id) })
    end

    it 'recalculates the result when force: true option is pased' do
      old_values = to_simple_array(for_user)
      old_cached_values = read_from_cache(user.id)

      # Update without running callbacks
      described_class.connection.execute(
        "UPDATE saved_replies SET name = 'Saved Reply 1'"
      )

      new_values = to_simple_array(described_class.for_user(user, force: true))

      expect(old_values).not_to eq(new_values)
      expect(old_cached_values).not_to eq(read_from_cache(user.id))
    end
  end
end
