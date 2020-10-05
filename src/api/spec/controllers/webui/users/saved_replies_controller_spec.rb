require 'rails_helper'

RSpec.describe Webui::Users::SavedRepliesController do
  let(:username) { 'reynoldsm' }
  let!(:user) { create(:confirmed_user, login: username) }
  let!(:other_user) { create(:confirmed_user) }

  let(:user_to_log_in) { user }
  let(:default_params) { { user_login: username } }

  let(:user_saved_reply_1) { create(:saved_reply, user: user) }
  let(:user_saved_reply_2) { create(:saved_reply, user: user) }
  let!(:user_saved_replies) { [user_saved_reply_1, user_saved_reply_2] }
  let!(:other_user_saved_reply) { create(:saved_reply, user: other_user) }

  shared_examples 'returning success' do
    it 'returns ok status' do
      expect(response.status).to be 200
    end
  end

  shared_examples 'not-found error' do
    it 'raises a not-found error' do
      expect { subject }.to raise_error ActiveRecord::RecordNotFound
    end
  end

  shared_examples 'redirect to Saved Replies page' do
    it 'redirects to the Saved Replies page' do
      subject

      expect(response).to redirect_to(my_saved_replies_path)
    end
  end

  before do
    login user_to_log_in
  end

  describe 'GET #index' do
    subject! { get :index }

    it "assigns the logged in user's saved replies" do
      expect(assigns[:saved_replies]).to contain_exactly(*user_saved_replies)
    end

    it "doesn't assign other users' saved replies" do
      expect(assigns[:saved_replies]).not_to include(other_user_saved_reply)
    end
  end

  describe 'GET #show' do
    subject { get :show, params: { id: saved_reply.id, format: 'json' } }

    context "when passing ID of a logged-in user's saved reply" do
      let(:saved_reply) { user_saved_reply_2 }

      it 'returns the JSON-formatted saved reply' do
        subject

        expect(JSON.parse(response.body)).to eq(
          'body' => saved_reply.body
        )
      end
    end

    context "when passing ID of other user's saved reply" do
      let(:saved_reply) { other_user_saved_reply }

      include_examples 'not-found error'
    end
  end

  describe 'GET #new' do
    subject! { get :new }

    it 'assigns an empty saved reply object' do
      expect(assigns[:saved_reply].id).to be nil
    end
  end

  describe 'GET #edit' do
    subject { get :edit, params: { id: saved_reply.id } }

    context "when passing ID of a logged-in user's saved reply" do
      let(:saved_reply) { user_saved_reply_2 }

      it 'assigns a saved reply object' do
        subject

        expect(assigns[:saved_reply]).to eq(saved_reply)
      end
    end

    context "when passing ID of other user's saved reply" do
      let(:saved_reply) { other_user_saved_reply }

      include_examples 'not-found error'
    end
  end

  describe 'POST create' do
    subject do
      post :create, params: { saved_reply: saved_reply_payload }
    end

    context 'when params are valid' do
      let(:saved_reply_payload) { { name: 'New name', body: 'New body' } }

      it 'creates a new saved reply record' do
        expect do
          subject
        end.to(
          change do
            SavedReply.exists?(user: user, name: 'New name', body: 'New body')
          end.from(false).to(true)
        )
      end

      include_examples 'redirect to Saved Replies page'
    end

    context 'when there is an invalid param' do
      let(:saved_reply_payload) { { name: '', body: 'New body' } }

      it "doesn't create a saved reply" do
        expect do
          subject
        end.not_to(change(SavedReply, :count))
      end

      include_examples 'redirect to Saved Replies page'
    end
  end

  describe 'PATCH update' do
    subject do
      patch \
        :update,
        params: { id: saved_reply.id, saved_reply: saved_reply_payload }
    end

    let(:saved_reply_payload) { {} }

    context "when passing ID of a logged-in user's saved reply" do
      let(:saved_reply) { user_saved_reply_2 }

      context 'when data is valid' do
        let(:saved_reply_payload) { { name: 'New name', body: 'New body' } }

        it 'updates the saved reply record' do
          expect do
            subject
          end.to(
            change do
              saved_reply.reload.attributes.slice('name', 'body')
            end.from(
              'name' => saved_reply.name,
              'body' => saved_reply.body
            ).to(
              'name' => 'New name',
              'body' => 'New body'
            )
          )
        end

        include_examples 'redirect to Saved Replies page'
      end

      context 'when data is invalid' do
        let(:saved_reply_payload) { { name: '', body: 'New body' } }

        it "doesn't update the saved reply" do
          expect do
            subject
          end.not_to(
            change { saved_reply.reload.attributes }
          )
        end

        include_examples 'redirect to Saved Replies page'
      end
    end

    context "when passing ID of other user's saved reply" do
      let(:saved_reply) { other_user_saved_reply }

      include_examples 'not-found error'
    end
  end

  describe 'DELETE destroy' do
    subject do
      delete :destroy, params: { id: saved_reply.id }
    end

    context "when passing ID of a logged-in user's saved reply" do
      let(:saved_reply) { user_saved_reply_2 }

      it 'deletes the saved reply record' do
        expect do
          subject
        end.to(
          change do
            SavedReply.exists?(saved_reply.id)
          end.from(true).to(false)
        )
      end

      include_examples 'redirect to Saved Replies page'

      context "when passing ID of other user's saved reply" do
        let(:saved_reply) { other_user_saved_reply }

        include_examples 'not-found error'
      end
    end
  end
end
