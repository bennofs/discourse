class UploadsController < ApplicationController
  before_filter :ensure_logged_in, except: [:show]
  skip_before_filter :preload_json, :check_xhr, only: [:show]

  def create
    type = params.require(:type)
    file = params[:file] || params[:files].first
    url = params[:url]

    # TODO: support for API providing a URL (cf. AvatarUploadService)

    Scheduler::Defer.later("Create Upload") do
      upload = Upload.create_for(
        current_user.id,
        file.tempfile,
        file.original_filename,
        file.tempfile.size,
        content_type: file.content_type
      )

      if upload.errors.empty? && current_user.admin?
        retain_hours = params[:retain_hours].to_i
        upload.update_columns(retain_hours: retain_hours) if retain_hours > 0
      end

      data = upload.errors.empty? ? upload : { errors: upload.errors.values.flatten }

      MessageBus.publish("/uploads/#{type}", data.as_json, user_ids: [current_user.id])
    end

    # HACK FOR IE9 to prevent the "download dialog"
    response.headers["Content-Type"] = "text/plain" if request.user_agent =~ /MSIE 9/

    render json: success_json
  end

  def show
    return render_404 if !RailsMultisite::ConnectionManagement.has_db?(params[:site])

    RailsMultisite::ConnectionManagement.with_connection(params[:site]) do |db|
      return render_404 unless Discourse.store.internal?
      return render_404 if SiteSetting.prevent_anons_from_downloading_files && current_user.nil?

      if upload = Upload.find_by(sha1: params[:sha]) || Upload.find_by(id: params[:id], url: request.env["PATH_INFO"])
        opts = { filename: upload.original_filename }
        opts[:disposition] = 'inline' if params[:inline]
        send_file(Discourse.store.path_for(upload), opts)
      else
        render_404
      end
    end
  end

  protected

  def render_404
    render nothing: true, status: 404
  end

end
