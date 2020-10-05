class Webui::Users::SavedRepliesController < Webui::WebuiController
  before_action :require_login

  def index
    @saved_replies = saved_replies
  end

  def show
    respond_to do |format|
      format.html
      format.json do
        render json: {
          body: saved_replies.find(params[:id]).body
        }
      end
    end
  end

  def new
    @saved_reply = SavedReply.new
  end

  def edit
    @saved_reply = saved_replies.find(params[:id])
  end

  def create
    if saved_replies.create(saved_reply_params)
      flash[:success] = 'Successfully created a new saved reply'
    else
      flash[:error] = "Couldn't create saved reply"
    end

    redirect_to(my_saved_replies_path)
  end

  def update
    saved_reply = saved_replies.find(params[:id])

    if saved_reply.update(saved_reply_params)
      flash[:success] = 'Successfully updated the saved reply'
    else
      flash[:error] = "Couldn't update the saved reply"
    end

    redirect_to(my_saved_replies_path)
  end

  def destroy
    saved_reply = saved_replies.find(params[:id])

    if saved_reply.destroy
      flash[:success] = 'Successfully removed the saved reply'
    else
      flash[:error] = "Couldn't remove the saved reply"
    end

    redirect_to(my_saved_replies_path)
  end

  private

  def saved_reply_params
    params.require(:saved_reply).permit(:name, :body)
  end

  def saved_replies
    User.session.saved_replies
  end
end
