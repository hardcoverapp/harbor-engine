module Harbor
  # One review round: the checklist of its checks, why they were asked for,
  # the sign-offs, the review, and the round as one document (.json is what
  # other tools read).
  class ReviewRoundsController < ApplicationController
    harbor_page :reviews
    helper Harbor::ReviewsHelper

    def show
      @round = Harbor::ReviewRound.find(params[:id])
      @doc = Harbor::Reviews::Document.for(@round)
      respond_to do |format|
        format.html
        format.json { render json: @doc }
      end
    end
  end
end
